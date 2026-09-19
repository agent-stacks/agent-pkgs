# buildAgentPlugin — build one Agent Plugin into the canonical layout:
#
#   $out/share/agent-plugins/<name>/
#   ├── plugin.json
#   ├── skills/
#   └── mcp.json        # optional
#
# Skill selection, in precedence order:
#
# 1. Explicit `skills` argument (skill name -> path inside src) — what
#    `agent-stacks import` generates; see docs/reference/import-contract.md.
# 2. A `skills-lock.json` at the src root (the project lock written by
#    the upstream skills CLI): entries are read at build time and each
#    skill is copied from its in-tree skillPath. Entries whose files
#    are not inside src (external sources) fail the build — a pure
#    build cannot fetch them; resolve those with `agent-stacks import`.
# 3. Passthrough: src is already a conformant plugin tree (plugin.json
#    + skills/) and is copied as-is.
#
# plugin.json rule (ADR 0009): an assembled package, one whose
# skills are selected here from the `skills` argument or the lock,
# takes its manifest and servers from the `manifest` and `mcpServers`
# arguments. Without an argument, a plugin.json or mcp.json in the
# src root stands in only when it is an Agent Plugins file, one
# declaring an agent-plugins.org $schema; any other is not read, and
# a skipped mcp.json is reported. A passed-through tree keeps its own
# files, and an argument, if given, replaces its file. An importer
# carrying agent-stacks's "Import hands the builder the manifest and
# servers it checked" always passes `manifest`, and `mcpServers`
# whenever the plugin declares servers; for such a package the
# stand-in is never consulted.
{ lib
, stdenvNoCC
, pkgs
  # The agent-stacks package that assembles the plugin tree and provides
  # `check-plugin`. agent-pkgs binds pkgs/agent-stacks here; a consumer
  # using lib/ without the package must pass `agentStacks` per call,
  # because assembly cannot be skipped.
, defaultAgentStacks ? null
}:

{ name
, version ? "0"
  # Either a derivation or path to use as-is, or a fetchFromGitHub
  # argument set — { owner, repo, rev, hash } — which a generated
  # source.json records as data because JSON cannot hold a derivation.
, src
  # provenance: upstream URL recorded in passthru
, sourceUrl ? null
  # The import that produced this package, when it was generated:
  # { input, flags, warnings }. Nothing in the build reads it; it is
  # declared so a generated source.json can be passed whole, and it
  # reaches passthru so a reader can see what produced the package.
  #
  # The name shadows Nix's own `import` for this whole function,
  # including the other formals' defaults — every call inside must be
  # builtins.import.
, import ? null
  # manifest attrset, serialized to plugin.json; without it, only an
  # Agent Plugins plugin.json in src stands in
, manifest ? null
  # assemble mode: skill name -> path inside src
, skills ? null
  # plugin-root entries the skills reach through ${PLUGIN_ROOT}:
  # destination inside the plugin tree -> path inside src. A plugin
  # keeping its executable code beside skills/ rather than inside a
  # skill ships it this way; a plugin referencing nothing outside its
  # skills records none, and its package is what it always was
  # (ADR 0014 in this repository, AI-759).
, pluginRootPaths ? null
  # mcp server configs, serialized to mcp.json; attrset of server
  # name -> config (type/command/...)
, mcpServers ? null
  # agent-stacks package providing `agent-stacks assemble-plugin` and
  # `agent-stacks check-plugin`; required, because the build phase is a
  # call to it
, agentStacks ? defaultAgentStacks
  # treat check-plugin warnings as errors. Off by default: skills in
  # the wild carry harness frontmatter fields the Agent Skills spec
  # does not list (argument-hint, disable-model-invocation), and those
  # are warnings a correct plugin can legitimately have.
, strict ? false
  # per-plugin runtime pins: interpreter name -> package, overriding
  # mappings/runtimes.nix (e.g. { python3 = python312; })
, runtimes ? { }
  # Interpreter tokens the package's files name, as recorded by
  # `agent-stacks import`. The builder resolves exactly these, so a
  # plugin naming none pulls no interpreter into its closure. A
  # hand-written call omits it and gets the whole table.
, requiredRuntimes ? null
  # bare mcp.json commands that intentionally resolve from the
  # consumer environment's PATH at launch instead of the closure
, allowPathCommands ? [ ]
  # escape hatch for interpreter calls inside script bodies or
  # SKILL.md text: list of { file; replace; with; } applied after the
  # automatic pass (the fuzzy cases a generic rewrite cannot guess)
, extraSubstitutions ? [ ]
, meta ? { }
}:

let
  out = "share/agent-plugins/${name}";

  # Test for the shape we mean, not its complement: a pin is an
  # attrset carrying owner and repo (what a generated source.json
  # writes). Everything else — a derivation, a path, lib.cleanSource,
  # lib.sourceByRegex, a flake's self — already is a source tree and
  # passes through untouched.
  isPin = builtins.isAttrs src && src ? owner && src ? repo;

  resolvedSrc = if isPin then pkgs.fetchFromGitHub src else src;

  # A manifest field, when the manifest declares it as a string.
  # Anything else — absent, null, a number, an object — is no value.
  manifestString = key:
    if manifest != null && manifest ? ${key} && builtins.isString manifest.${key}
    then manifest.${key}
    else null;

  # lib.licenses keyed by SPDX identifier. Built by folding over sorted
  # attribute names with first-wins, rather than with mapAttrs', so two
  # licence attributes sharing an spdxId resolve to the same one on
  # every evaluation instead of to whichever mapAttrs' happened to
  # visit last.
  licensesBySpdx = lib.foldl'
    (acc: attr:
      let l = lib.licenses.${attr}; in
      if l ? spdxId && builtins.isString l.spdxId && !(acc ? ${l.spdxId})
      then acc // { ${l.spdxId} = l; }
      else acc)
    { }
    (builtins.attrNames lib.licenses);

  declaredLicense = manifestString "license";
  manifestDescription = manifestString "description";

  # meta the builder derives from arguments it already has. A caller's
  # own meta overrides these key by key (see the merge at the bottom of
  # this file), so a generated package's recorded description wins over
  # the manifest's.
  #
  # license is present only for a manifest licence that is a known SPDX
  # identifier. A plugin whose upstream declares nothing, or declares
  # something unparseable like "SEE LICENSE IN LICENSE", gets no
  # assertion rather than a guess — ADR 0014.
  defaultMeta = {
    category = "agent-plugin";
    platforms = lib.platforms.all;
  }
  // lib.optionalAttrs (manifestDescription != null) {
    description = manifestDescription;
  }
  // lib.optionalAttrs (sourceUrl != null || manifestString "homepage" != null) {
    homepage = if sourceUrl != null then sourceUrl else manifestString "homepage";
  }
  // lib.optionalAttrs (declaredLicense != null && licensesBySpdx ? ${declaredLicense}) {
    license = licensesBySpdx.${declaredLicense};
  };

  # The description that actually applies, once the caller's meta has
  # had its say. Needed to decide whether the manifest's full text is
  # worth keeping as longDescription.
  effectiveDescription = (defaultMeta // meta).description or null;

  # An importer records a one-line summary in meta.description and
  # leaves the full text in the manifest. Keep that text rather than
  # discard it, but only when it says more than the summary does.
  longDescription = lib.optionalAttrs
    (manifestDescription != null
      && effectiveDescription != null
      && manifestDescription != effectiveDescription)
    { longDescription = manifestDescription; };

  finalMeta = defaultMeta // longDescription // meta;

  # Runtime resolution: the table maps interpreter names to
  # nixpkgs attributes; the plugin's `runtimes` argument overrides it
  # with concrete packages. The resolved map is handed to
  # assemble-plugin as JSON — outPath plus the package's main program
  # name, so it can locate the right binary (`sh` lives in bash's
  # bin/sh, `python` may only exist as bin/python3).
  runtimeTable = builtins.import ../mappings/runtimes.nix;

  # Which tokens to resolve. A generated package always records them;
  # a package generated before requiredRuntimes existed is regenerated
  # rather than tolerated, because a silent fallback would leave the
  # 1.6 GiB closure in place indefinitely. A hand-written call — the
  # flake checks, a consumer of lib/ — has no import record and gets
  # the whole table, which is what it got before.
  requiredList =
    if requiredRuntimes != null then requiredRuntimes
    else if import != null then throw
      ("buildAgentPlugin: ${name}: source.json records no requiredRuntimes. "
        + "Regenerate this package with `agent-stacks import`, using a "
        + "an agent-stacks at or after rev 8be3bce — the first to emit "
        + "requiredRuntimes. An older agent-stacks reproduces this error "
        + "instead of fixing it.")
    else builtins.attrNames runtimeTable;

  # A recorded token that is neither pinned nor in the table is left
  # out of the map rather than thrown here, so the error a reader sees
  # is the one assemble-plugin prints, naming the file that wanted it.
  # One error text for an unmapped runtime, not two.
  mappedTokens = builtins.filter
    (tok: runtimes ? ${tok} || runtimeTable ? ${tok})
    requiredList;

  resolveToken = tok:
    if runtimes ? ${tok} then runtimes.${tok}
    else pkgs.${runtimeTable.${tok}} or (throw
      "mappings/runtimes.nix maps '${tok}' to unknown nixpkgs attribute '${runtimeTable.${tok}}'");

  resolvedRuntimes = lib.genAttrs mappedTokens resolveToken;

  runtimeMapFile = pkgs.writeText "runtime-map.json" (builtins.toJSON
    (lib.mapAttrs
      (tok: p: {
        root = "${p}";
        main = p.meta.mainProgram or (lib.getName p);
      })
      resolvedRuntimes));

  # The builder call, handed to assemble-plugin as data. A generated
  # package's source.json is already exactly this; reconstructing it
  # here means a hand-written call gets the same treatment without
  # needing a file on disk.
  callFile = pkgs.writeText "source.json" (builtins.toJSON
    (lib.filterAttrs (_: v: v != null) {
      inherit name skills manifest mcpServers pluginRootPaths;
      inherit allowPathCommands extraSubstitutions;
    }));
in
assert agentStacks != null || throw
  ("buildAgentPlugin: ${name}: an agent-stacks package is required — it "
    + "assembles the plugin tree. Pass agentStacks, or bind defaultAgentStacks "
    + "when calling lib/build-agent-plugin.nix.");
stdenvNoCC.mkDerivation {
  pname = "agent-plugin-${name}";
  inherit version;
  src = resolvedSrc;

  dontConfigure = true;

  # assemble-plugin's substitution pass is the only thing entitled to
  # rewrite a shebang in this tree. stdenv's fixup would otherwise run
  # patchShebangs over $out and disagree with it twice: it rewrites
  # files under assets/, which the pass and the guard both leave alone
  # because those are static templates that may be copied out of the
  # plugin, and it rewrites them to a bare store path rather than to
  # <plugin>/bin/<tok> — a dangling absolute path on any machine
  # without that path, which is worse than the /usr/bin/env it
  # replaced. The pass already writes absolute, non-env shebangs for
  # every file it does own, so patchShebangs has nothing to add.
  dontPatchShebangs = true;

  buildPhase = ''
    runHook preBuild

    dest="$NIX_BUILD_TOP/plugin/${name}"

    ${lib.getExe' agentStacks "agent-stacks"} assemble-plugin \
      --source-json ${callFile} \
      --src . \
      --out "$dest" \
      --runtime-map ${runtimeMapFile} \
      --plugin-out "$out/${out}"

    # Hook point for extensions: runs on the fully assembled tree,
    # before install and the checks. It used to run between the
    # substitution pass and the guard; both are now inside one
    # process, so this is the nearest equivalent point.
    runHook postAssemble

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/agent-plugins"
    cp -R "$NIX_BUILD_TOP/plugin/${name}" "$out/${out}"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    ${lib.getExe' agentStacks "agent-stacks"} check-plugin${
      lib.optionalString strict " --strict"
    } "$out/${out}"
    runHook postInstallCheck
  '';

  passthru.agentPlugin = {
    inherit name sourceUrl import;
    path = out;
    # Provenance for the audit story: what was fetched, and what it
    # hashed to. Null when src is a path or a derivation rather than a
    # recorded pin, because then there is nothing pinned to report.
    rev = if isPin then src.rev or null else null;
    hash = if isPin then src.hash or null else null;
    specVersion =
      if manifest != null && manifest ? "$schema"
      then lib.removeSuffix "/plugin.schema.json"
        (lib.last (lib.splitString "/schemas/" manifest."$schema"))
      else null;
    skills = if skills == null then null else builtins.attrNames skills;
    # What the package ships from beside its skills, so a reader can
    # see it without unpacking the output (AI-759).
    pluginRootPaths =
      if pluginRootPaths == null then null else builtins.attrNames pluginRootPaths;
  };

  # A plugin makes no licence assertion unless its manifest declares a
  # recognisable SPDX identifier: licenses.unfree would be wrong,
  # licenses.free would be a lie, and nixpkgs has no "unknown" to name.
  # maintainers is never set here; nixpkgs injects an empty list, which
  # is what unmaintained means. ADR 0014 records both.
  meta = finalMeta;
}
