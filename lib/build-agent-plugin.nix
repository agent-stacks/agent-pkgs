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
#    `flox-agent import` generates; see docs/reference/import-contract.md.
# 2. A `skills-lock.json` at the src root (the project lock written by
#    the upstream skills CLI): entries are read at build time and each
#    skill is copied from its in-tree skillPath. Entries whose files
#    are not inside src (external sources) fail the build — a pure
#    build cannot fetch them; resolve those with `flox-agent import`.
# 3. Passthrough: src is already a conformant plugin tree (plugin.json
#    + skills/) and is copied as-is.
#
# plugin.json rule (ADR 0008): a package is built from one source.
# When skills are selected here (the `skills` argument, or the lock),
# the manifest and the servers are the `manifest` and `mcpServers`
# arguments alone; a plugin.json or mcp.json in the src root is not
# read, and `manifest` is required. In passthrough the tree's own
# files are the source, and an argument, if given, replaces its file.
# What `flox-agent import` generates always carries `manifest`, and
# `mcpServers` whenever the plugin has servers.
{ lib
, stdenvNoCC
, jq
, pkgs
  # The flox-agent package providing `check-plugin`. agent-pkgs binds
  # pkgs/flox-agent here; null skips validation, which is what a
  # consumer using lib/ without the package gets.
, defaultFloxAgent ? null
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
  # manifest attrset, serialized to plugin.json; required unless src
  # is passed through as a plugin tree
, manifest ? null
  # assemble mode: skill name -> path inside src
, skills ? null
  # mcp server configs, serialized to mcp.json; attrset of server
  # name -> config (type/command/...)
, mcpServers ? null
  # flox-agent package providing `flox-agent check-plugin`; when null
  # the check phase is skipped
, floxAgent ? defaultFloxAgent
  # treat check-plugin warnings as errors. Off by default: skills in
  # the wild carry harness frontmatter fields the Agent Skills spec
  # does not list (argument-hint, disable-model-invocation), and those
  # are warnings a correct plugin can legitimately have.
, strict ? false
  # per-plugin runtime pins: interpreter name -> package, overriding
  # mappings/runtimes.nix (e.g. { python3 = python312; })
, runtimes ? { }
  # bare mcp.json commands that intentionally resolve from the
  # consumer environment's PATH at launch instead of the closure
, allowPathCommands ? [ ]
  # escape hatch for interpreter calls inside script bodies or
  # SKILL.md text: list of { file; replace; with; } applied after the
  # automatic pass (the fuzzy cases a generic rewrite cannot guess)
, extraSubstitutions ? [ ]
  # executables allowed to keep a /usr/bin/env shebang (relative to
  # the plugin root)
, allowEnvShebangs ? [ ]
, meta ? { }
}:

let
  out = "share/agent-plugins/${name}";

  # Test for the shape we mean, not its complement: a pin is an
  # attrset carrying owner and repo (what a generated source.json
  # writes). Everything else — a derivation, a path, lib.cleanSource,
  # lib.sourceByRegex, a flake's self — already is a source tree and
  # passes through untouched.
  resolvedSrc =
    if builtins.isAttrs src && src ? owner && src ? repo
    then pkgs.fetchFromGitHub src
    else src;

  manifestFile =
    if manifest == null then null
    else builtins.toFile "plugin.json" (builtins.toJSON manifest);

  # An mcp.json targeting a different spec version than plugin.json
  # makes a client disable MCP for the plugin (spec §7.2.2), so the
  # generated one follows the manifest's version when there is one.
  specVersionOf = m:
    if m != null && m ? "$schema"
    then lib.head (lib.splitString "/" (lib.last (lib.splitString "/schemas/" m."$schema")))
    else "1.0.0";

  mcpFile =
    if mcpServers == null then null
    else builtins.toFile "mcp.json" (builtins.toJSON {
      "$schema" = "https://agent-plugins.org/schemas/${specVersionOf manifest}/mcp.schema.json";
      inherit mcpServers;
    });

  # Runtime resolution: the table maps interpreter names to
  # nixpkgs attributes; the plugin's `runtimes` argument overrides it
  # with concrete packages. The resolved map is handed to the build
  # as JSON — outPath plus the package's main program name, so the
  # build can locate the right binary (`sh` lives in bash's bin/sh,
  # `python` may only exist as bin/python3).
  runtimeTable = builtins.import ../mappings/runtimes.nix;
  resolvedRuntimes =
    lib.mapAttrs
      (tok: attrName: pkgs.${attrName} or (throw
        "mappings/runtimes.nix maps '${tok}' to unknown nixpkgs attribute '${attrName}'"))
      runtimeTable
    // runtimes;
  runtimeMapFile = pkgs.writeText "runtime-map.json" (builtins.toJSON
    (lib.mapAttrs
      (tok: p: {
        root = "${p}";
        main = p.meta.mainProgram or (lib.getName p);
      })
      resolvedRuntimes));

  substituteOne = s: ''
    substituteInPlace "$dest"/${lib.escapeShellArg s.file} \
      --replace-fail ${lib.escapeShellArg s.replace} ${lib.escapeShellArg s."with"}
  '';

  copySkill = skillName: path: ''
    if [ ! -f ${lib.escapeShellArg path}/SKILL.md ]; then
      echo "buildAgentPlugin: skill '${skillName}': no SKILL.md at '${path}' in src" >&2
      exit 1
    fi
    mkdir -p "$dest/skills"
    cp -R ${lib.escapeShellArg path} "$dest/skills/${skillName}"
  '';
in
stdenvNoCC.mkDerivation {
  pname = "agent-plugin-${name}";
  inherit version;
  src = resolvedSrc;

  nativeBuildInputs = [ jq ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    dest="$NIX_BUILD_TOP/plugin/${name}"
    mkdir -p "$dest"

    ${if skills != null then ''
      # 1. explicit skill mapping from the import contract
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList copySkill skills)}
    '' else ''
      if [ -f skills-lock.json ]; then
        # 2. project lock written by the upstream skills CLI
        mkdir -p "$dest/skills"
        jq -r '.skills | to_entries[] | "\(.key)\t\(.value.skillPath // "")"' \
            skills-lock.json | while IFS=$'\t' read -r sname spath; do
          sdir=""
          if [ -n "$spath" ] && [ -f "$(dirname "$spath")/SKILL.md" ]; then
            sdir="$(dirname "$spath")"
          elif [ -f "skills/$sname/SKILL.md" ]; then
            sdir="skills/$sname"
          fi
          if [ -z "$sdir" ]; then
            echo "buildAgentPlugin: lock entry '$sname' is not inside src — a pure build cannot fetch external sources; generate this package with 'flox-agent import' instead" >&2
            exit 1
          fi
          cp -R "$sdir" "$dest/skills/$sname"
        done
      elif [ -f plugin.json ] && [ -d skills ]; then
        # 3. passthrough: src is already a conformant plugin tree
        cp -R . "$dest"
        chmod -R u+w "$dest"
        passthrough=1
      else
        echo "buildAgentPlugin: no skills argument, no skills-lock.json, and src is not a plugin tree" >&2
        exit 1
      fi
    ''}

    # plugin.json and mcp.json (ADR 0008): an assembled package is
    # built from the arguments alone, and the src root's files are
    # not read; a passed-through tree keeps its own files unless an
    # argument replaces one.
    if [ -n "${toString (manifestFile != null)}" ]; then
      cp ${toString manifestFile} "$dest/plugin.json"
    elif [ -z "''${passthrough:-}" ]; then
      echo "buildAgentPlugin: no manifest argument was given; an assembled package needs one" >&2
      exit 1
    fi
    if [ -n "${toString (mcpFile != null)}" ]; then
      cp ${toString mcpFile} "$dest/mcp.json"
    fi

    # --- runtime substitution pass ------------------------------------
    # Detect interpreter names in shebangs and bare mcp.json commands,
    # resolve them through mappings/runtimes.nix (overridden by the
    # `runtimes` argument), link them into <plugin>/bin/, and rewrite
    # the references. Symlink targets are store paths, so Nix's
    # reference scanner pulls the interpreters into the closure.
    plugin_out="$out/${out}"
    runtime_map=${runtimeMapFile}

    # resolve_runtime <token> <wanted-by>: ensures bin/<token> exists
    resolve_runtime() {
      local tok="$1" wanted_by="$2" root main exe
      [ -e "$dest/bin/$tok" ] && return 0
      root=$(jq -r --arg t "$tok" '.[$t].root // empty' "$runtime_map")
      if [ -z "$root" ]; then
        echo "buildAgentPlugin: runtime '$tok' (wanted by $wanted_by) is not mapped." >&2
        echo "  Add it to mappings/runtimes.nix, or pass runtimes.$tok = <package>;" >&2
        exit 1
      fi
      main=$(jq -r --arg t "$tok" '.[$t].main' "$runtime_map")
      if [ -x "$root/bin/$tok" ]; then
        exe="$root/bin/$tok"
      elif [ -x "$root/bin/$main" ]; then
        exe="$root/bin/$main"
      else
        echo "buildAgentPlugin: runtime '$tok' resolved to $root but neither bin/$tok nor bin/$main exists there" >&2
        exit 1
      fi
      mkdir -p "$dest/bin"
      ln -s "$exe" "$dest/bin/$tok"
    }

    # Shebangs: any regular file outside assets/ opening with
    # #!/usr/bin/env <tok> or #!/usr/bin/<tok> is repointed at the
    # plugin-local bin/ and marked executable. assets/ holds static
    # templates that may leave the plugin, so it is left alone.
    while IFS= read -r f; do
      tok=$(head -c 200 "$f" | head -1 \
        | sed -nE 's|^#!\s*(/usr/bin/env +\|/usr/bin/\|/bin/)([A-Za-z0-9._+-]+).*|\2|p')
      [ -n "$tok" ] || continue
      [ "$tok" = env ] && continue
      resolve_runtime "$tok" "$f"
      sed -i "1s|^#!.*|#!$plugin_out/bin/$tok|" "$f"
      chmod +x "$f"
    done < <(find "$dest" -type f -not -path "*/assets/*" -not -path "$dest/bin/*")

    # mcp.json commands: bare tokens (no slash) must resolve through
    # the map, except those explicitly allowed to come from the
    # consumer environment's PATH.
    if [ -f "$dest/mcp.json" ]; then
      allow=${lib.escapeShellArg (builtins.toJSON allowPathCommands)}
      while IFS= read -r cmd; do
        case "$cmd" in */*) continue ;; esac
        if jq -e --arg c "$cmd" 'index($c) != null' <<<"$allow" >/dev/null; then
          continue
        fi
        resolve_runtime "$cmd" "mcp.json"
      done < <(jq -r '.mcpServers[] | select(.command != null) | .command' "$dest/mcp.json")
      # Only stdio servers have a command; an http or sse server has
      # a url and is left alone.
      jq --arg bin "$plugin_out/bin" --argjson allow "$allow" '
        .mcpServers |= with_entries(
          if .value.command == null then . else
          .value.command |= (if (contains("/") | not) and (($allow | index(.)) == null)
                             then "\($bin)/\(.)" else . end) end)
      ' "$dest/mcp.json" > "$dest/mcp.json.tmp"
      mv "$dest/mcp.json.tmp" "$dest/mcp.json"
    fi

    # Per-package substitutions for the fuzzy cases (script bodies,
    # SKILL.md text) that the automatic pass deliberately skips.
    ${lib.concatStringsSep "\n" (map substituteOne extraSubstitutions)}

    # Hook point for extensions: runs on the fully substituted tree,
    # before the guard, install, and checks.
    runHook postAssemble

    # Guard: an executable that still resolves its interpreter from
    # the environment escaped the pass — fail loudly instead of
    # shipping a closure hole.
    allowed_shebangs=${lib.escapeShellArg (builtins.toJSON allowEnvShebangs)}
    while IFS= read -r f; do
      head -1 "$f" | grep -q '/usr/bin/env' || continue
      rel="''${f#"$dest"/}"
      if jq -e --arg p "$rel" 'index($p) != null' <<<"$allowed_shebangs" >/dev/null; then
        continue
      fi
      echo "buildAgentPlugin: executable '$rel' still has a /usr/bin/env shebang after the substitution pass; fix the mapping or list it in allowEnvShebangs" >&2
      exit 1
    done < <(find "$dest" -type f -perm -u+x -not -path "$dest/bin/*")

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/agent-plugins"
    cp -R "$NIX_BUILD_TOP/plugin/${name}" "$out/${out}"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase =
    if floxAgent != null then ''
      runHook preInstallCheck
      ${lib.getExe' floxAgent "flox-agent"} check-plugin${
        lib.optionalString strict " --strict"
      } "$out/${out}"
      runHook postInstallCheck
    '' else ''
      echo "buildAgentPlugin: flox-agent not provided — skipping check-plugin validation" >&2
    '';

  passthru.agentPlugin = {
    inherit name sourceUrl import;
    path = out;
    specVersion =
      if manifest != null && manifest ? "$schema"
      then lib.removeSuffix "/plugin.schema.json"
        (lib.last (lib.splitString "/schemas/" manifest."$schema"))
      else null;
    skills = if skills == null then null else builtins.attrNames skills;
  };

  # Plugins make no license assertion by default (the
  # attribute is simply absent); generated packages record the
  # upstream license when known.
  inherit meta;
}
