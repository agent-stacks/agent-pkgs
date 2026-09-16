{
  description = "Nix package set for Agent Plugins and Agent Stacks";

  # The cache the agent CLIs re-exported from llm-agents.nix are built
  # into upstream. Whether a path hits depends on it having been built
  # from inputs identical to ours, which the two nixpkgs revisions
  # currently agree on for a good part of the set; where they do not,
  # Nix treats the miss as a miss and builds. Offered rather than
  # imposed: an untrusted user gets a warning and no substituter, which
  # costs build time and nothing else.
  nixConfig = {
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];
  };

  inputs = {
    # The Flox nixpkgs fork, not upstream. Publishing to a Flox catalog
    # requires a nixpkgs revision the catalog server has a page for, and
    # those pages track this fork — an upstream revision is rejected
    # with "specifies a page or catalog that does not exist in this
    # instance". Building against the nixpkgs we publish against keeps
    # what we build and what the catalog serves identical.
    nixpkgs.url = "github:flox/nixpkgs/unstable";

    # The agent CLIs themselves — claude-code, codex, opencode and the
    # rest — packaged by numtide and updated daily. Its nixpkgs is
    # deliberately not followed to ours: the set pins its own bun to
    # keep the bun-built packages substitutable, and following would
    # take that pin away.
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = { self, nixpkgs, llm-agents }:
    let
      # Every system this set is built, cached and published for.
      # x86_64-darwin is absent: Intel Macs are not a target.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];

      # The predicate is scoped to the one pname rather than the whole
      # instance, so anything drifting into another package still fails
      # loudly. It governs only packages built through this flake; a
      # consumer's own nixpkgs config is untouched.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "flox-agent-bin";
      };

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (pkgsFor system));

      # llm-agents.nix built against the nixpkgs above rather than the
      # one it pins. Its own `packages.*` are built against upstream
      # nixpkgs, which the catalog has no page for; the shared-nixpkgs
      # overlay is how that flake supports being rebuilt against a
      # consumer's package set.
      #
      # allowUnfree is on for this instance and this instance only.
      # Roughly a seventh of the set is unfree, upstream adds packages
      # daily, and a name list here would be stale within the week. The
      # narrow predicate above still governs everything under pkgs/.
      llmAgentsPkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ llm-agents.overlays.shared-nixpkgs ];
      };

      # Attributes llm-agents.nix exposes that are not packages of this
      # set: the nixpkgs builders and fetchers it patches, its setup
      # hooks, the toolchains it builds its own packages with, and two
      # flake output names. Upstream publishes all of these in its own
      # packages output, so there is no upstream list to defer to —
      # this one is ours, and the re-export-is-packages check fails
      # when upstream grows another.
      #
      # bun-bin and go-bin do ship runnable binaries. They are excluded
      # by judgement rather than by rule: they are build inputs for
      # that flake, and nixpkgs already has bun and go.
      #
      # default and formatter are flake output names fixed by the flake
      # schema rather than package names upstream chose, which is why
      # excluding them by name cannot rot the way a package denylist
      # would.
      notPackages = [
        "buildNpmPackage"
        "fetchPnpmDeps"
        "flake-inputs"
        "darwinOpenptyHook"
        "unpinCargoMsrvHook"
        "unpinGoModVersionHook"
        "versionCheckHomeHook"
        "bun-bin"
        "go-bin"
        "default"
        "formatter"
        "wrapBuddy"
        "site"
      ];

      # Real packages whose packager omitted meta.mainProgram. Empty
      # today. Listing one here keeps it published and silences the
      # re-export-is-packages check for that name alone.
      notPackagesExempt = [ ];

      # Upstream's packages/ also holds builders, setup hooks and the
      # toolchains it builds with. They are derivations, not functions,
      # so no property distinguishes them from packages — they are
      # named in notPackages above and ADR 0015 records why. Broken and
      # foreign-platform packages are dropped the same way that flake
      # drops them from its own packages output: a package that cannot
      # run on aarch64-darwin has no business being an aarch64-darwin
      # job.
      llmAgentsFor = system:
        let
          pkgs = llmAgentsPkgsFor system;
          keep = name: p:
            !(builtins.elem name notPackages)
            && nixpkgs.lib.isDerivation p
            && nixpkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform p
            && !(p.meta.broken or false);

          # Exceptions only; everything else is an agent-tool. meta is
          # stripped before the derivation is built, so overrideAttrs
          # here changes no store path and rebuilds nothing.
          categories = import ./mappings/agent-categories.nix;
          withCategory = name: p:
            let category = categories.${name} or "agent-tool"; in
            if p ? overrideAttrs
            then p.overrideAttrs (old: {
              meta = (old.meta or { }) // { inherit category; };
            })
            else p;
        in
        nixpkgs.lib.mapAttrs withCategory
          (nixpkgs.lib.filterAttrs keep pkgs.llm-agents);

      # Every subdirectory of pkgs/ with a default.nix is a package.
      # `flox-agent import --out pkgs/<name>` drops packages here; no
      # central list to edit.
      pluginDirs = pkgs:
        let
          entries = builtins.readDir ./pkgs;
          hasPackage = name:
            entries.${name} == "directory"
            && builtins.pathExists (./pkgs + "/${name}/default.nix");
        in
        builtins.filter hasPackage (builtins.attrNames entries);

      mkLib = pkgs: {
        # Every plugin is validated by the flox-agent from this set. The
        # reference is lazy: pkgs/flox-agent is not built by
        # buildAgentPlugin, so naming it here does not recurse.
        buildAgentPlugin = pkgs.callPackage ./lib/build-agent-plugin.nix {
          defaultFloxAgent = (mkPackages pkgs).flox-agent;
        };
        mkAgentStack = pkgs.callPackage ./lib/mk-agent-stack.nix {
          defaultAuditTools = import ./mappings/audit-tools.nix { inherit pkgs; };
          # Every stack runs the flox-agent from this set. Taken from
          # mkPackages rather than callPackage'd a second time, so the
          # stack and `nix run .#flox-agent` are the same derivation. The
          # reference is lazy: pkgs/flox-agent does not build a stack, so
          # forcing it here does not recurse.
          defaultFloxAgent = (mkPackages pkgs).flox-agent;
        };
        runtimeMappings = import ./mappings/runtimes.nix;
      };

      mkPackages = pkgs:
        let
          lib' = mkLib pkgs;
          scope = { inherit (lib') buildAgentPlugin mkAgentStack; } // built;
          built = nixpkgs.lib.genAttrs (pluginDirs pkgs) (name:
            pkgs.newScope scope (./pkgs + "/${name}") { });
        in
        built;

      # What the catalog is fed from: the plugins built here, plus every
      # agent CLI re-exported from llm-agents.nix. Kept separate from
      # mkPackages so that forcing one plugin does not force the whole
      # re-exported set — mkLib reaches into mkPackages for flox-agent
      # on every plugin build.
      mkAllPackages = pkgs:
        let
          built = mkPackages pkgs;
          llmAgents = llmAgentsFor pkgs.stdenv.hostPlatform.system;
          # This set owns the name: a package written here is what the
          # catalog serves, and the re-export is shadowed. Warned about
          # rather than tolerated silently, because pkgs/ grows by
          # import and upstream grows daily — a collision is how a
          # plugin quietly stops matching what upstream publishes.
          clashes = builtins.attrNames (builtins.intersectAttrs built llmAgents);
        in
        nixpkgs.lib.warnIf (clashes != [ ])
          "agent-pkgs and llm-agents.nix both define ${toString clashes}; the package from pkgs/ wins"
          (llmAgents // built);

      mkChecks = pkgs:
        mkPackages pkgs // {
          # An unmapped runtime fails the build with a message pointing
          # at the table, and the guard catches executables
          # whose /usr/bin/env shebang survived.
          runtimes-failures =
            let
              lib' = mkLib pkgs;
              unmappedSrc = pkgs.writeTextDir "skills/x/SKILL.md" ''
                ---
                name: x
                description: Uses an unmapped runtime.
                ---
              '';
              unmapped = lib'.buildAgentPlugin {
                name = "unmapped";
                src = pkgs.runCommand "unmapped-src" { } ''
                  mkdir -p $out/skills/x/scripts
                  cp ${unmappedSrc}/skills/x/SKILL.md $out/skills/x/SKILL.md
                  printf '#!/usr/bin/env lua\nprint(1)\n' > $out/skills/x/scripts/r.lua
                '';
                manifest = {
                  "$schema" = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json";
                  name = "unmapped";
                };
                skills.x = "skills/x";
              };
            in
            pkgs.testers.testBuildFailure' {
              drv = unmapped;
              expectedBuilderLogEntries = [
                "runtime 'lua'"
                "mappings/runtimes.nix"
              ];
            };

          # ADR 0009, every path: an assembled package with a foreign
          # plugin.json and a Claude mcp.json at the src root is built
          # from its arguments, the http server passes the runtime
          # pass untouched while the stdio one is resolved and the
          # allowed one is not; a passed-through tree keeps its files,
          # and a manifest replacing its plugin.json brings its
          # mcp.json to the same version; a lock-mode tree with a
          # conformant root plugin.json and no manifest builds from
          # that file; a conformant root mcp.json stands in for an
          # older generated file, and a Claude one is skipped.
          arguments-alone =
            let
              lib' = mkLib pkgs;
              skillMD = ''
                printf -- '---\nname: one\ndescription: Does things.\n---\nBody.\n' > $out/skills/one/SKILL.md
              '';
              foreign = pkgs.runCommand "foreign-src" { } ''
                mkdir -p $out/skills/one
                printf '{"$schema": "https://cursor.com/x", "name": "foreign", "skills": "./skills"}\n' > $out/plugin.json
                printf '{"mcpServers": {"web": {"type": "http", "url": "https://example.com/mcp"}}}\n' > $out/mcp.json
                ${skillMD}
              '';
              conformant = pkgs.runCommand "conformant-src" { } ''
                mkdir -p $out/skills/one
                printf '{"$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json", "name": "kept"}\n' > $out/plugin.json
                printf '{"$schema": "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json", "mcpServers": {"web": {"type": "sse", "url": "https://example.com/sse"}}}\n' > $out/mcp.json
                ${skillMD}
              '';
              locked = pkgs.runCommand "locked-src" { } ''
                mkdir -p $out/skills/one
                printf '{"$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json", "name": "locked"}\n' > $out/plugin.json
                printf '{"version": 1, "skills": {"one": {"source": "local", "sourceType": "local"}}}\n' > $out/skills-lock.json
                ${skillMD}
              '';
              manifest11 = name: {
                "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
                inherit name;
              };
              assembled = lib'.buildAgentPlugin {
                name = "assembled";
                src = foreign;
                skills.one = "skills/one";
                manifest = manifest11 "assembled";
                mcpServers = {
                  web = { type = "streamable-http"; url = "https://example.com/mcp"; };
                  local = { type = "stdio"; command = "python3"; };
                  fromPath = { type = "stdio"; command = "node"; };
                };
                allowPathCommands = [ "node" ];
              };
              passthrough = lib'.buildAgentPlugin { name = "kept"; src = conformant; };
              replaced = lib'.buildAgentPlugin {
                name = "kept";
                src = conformant;
                manifest = manifest11 "kept";
              };
              lockMode = lib'.buildAgentPlugin { name = "locked"; src = locked; };
              standIn = lib'.buildAgentPlugin {
                name = "kept";
                src = conformant;
                skills.one = "skills/one";
              };
              skipped = lib'.buildAgentPlugin {
                name = "assembled";
                src = foreign;
                skills.one = "skills/one";
                manifest = manifest11 "assembled";
              };
              noManifest = lib'.buildAgentPlugin {
                name = "assembled";
                src = foreign;
                skills.one = "skills/one";
              };
            in
            pkgs.runCommand "arguments-alone" { nativeBuildInputs = [ pkgs.jq ]; } ''
              a=${assembled}/share/agent-plugins/assembled
              [ "$(jq -r .name $a/plugin.json)" = assembled ]
              [ "$(jq -r '."$schema"' $a/mcp.json)" = https://agent-plugins.org/schemas/1.1.0/mcp.schema.json ]
              [ "$(jq -r .mcpServers.web.type $a/mcp.json)" = streamable-http ]
              [ "$(jq -r .mcpServers.web.url $a/mcp.json)" = https://example.com/mcp ]
              [ "$(jq -r .mcpServers.local.command $a/mcp.json)" = "$a/bin/python3" ]
              [ "$(jq -r .mcpServers.fromPath.command $a/mcp.json)" = node ]
              p=${passthrough}/share/agent-plugins/kept
              [ "$(jq -r .name $p/plugin.json)" = kept ]
              [ "$(jq -r '."$schema"' $p/mcp.json)" = https://agent-plugins.org/schemas/1.0.0/mcp.schema.json ]
              r=${replaced}/share/agent-plugins/kept
              [ "$(jq -r '."$schema"' $r/plugin.json)" = https://agent-plugins.org/schemas/1.1.0/plugin.schema.json ]
              [ "$(jq -r '."$schema"' $r/mcp.json)" = https://agent-plugins.org/schemas/1.1.0/mcp.schema.json ]
              [ "$(jq -r .mcpServers.web.type $r/mcp.json)" = sse ]
              l=${lockMode}/share/agent-plugins/locked
              [ "$(jq -r .name $l/plugin.json)" = locked ]
              [ -d $l/skills/one ]
              s=${standIn}/share/agent-plugins/kept
              [ "$(jq -r .name $s/plugin.json)" = kept ]
              [ "$(jq -r .mcpServers.web.type $s/mcp.json)" = sse ]
              k=${skipped}/share/agent-plugins/assembled
              [ ! -e $k/mcp.json ]
              touch $out
            '';

          # An assembled package with no manifest and no Agent Plugins
          # plugin.json in src fails, naming the gap.
          arguments-alone-no-manifest =
            let
              lib' = mkLib pkgs;
              foreign = pkgs.runCommand "foreign-src" { } ''
                mkdir -p $out/skills/one
                printf '{"$schema": "https://cursor.com/x", "name": "foreign"}\n' > $out/plugin.json
                printf -- '---\nname: one\ndescription: Does things.\n---\nBody.\n' > $out/skills/one/SKILL.md
              '';
            in
            pkgs.testers.testBuildFailure' {
              drv = lib'.buildAgentPlugin {
                name = "assembled";
                src = foreign;
                skills.one = "skills/one";
              };
              expectedBuilderLogEntries = [ "no manifest argument was given" ];
            };

          # A root skill beside nested ones (flox-agent ADR 0021): the
          # root's copy leaves out every skill directory below it,
          # whether the map lists it or not, and a wrapper left empty;
          # the nested skill is packaged at its own name. A skill with
          # nothing below it is copied as before, and "./" spells the
          # root as well as ".".
          root-skill-excludes-nested =
            let
              lib' = mkLib pkgs;
              suite = pkgs.runCommand "suite-src" { } ''
                mkdir -p $out/skills/inner/scripts $out/skills/dropped $out/references
                printf -- '---\nname: parent\ndescription: Routes the suite.\n---\nBody.\n' > $out/SKILL.md
                printf -- '---\nname: inner\ndescription: One route.\n---\nBody.\n' > $out/skills/inner/SKILL.md
                printf -- '---\nname: dropped\n---\nNo description, so import skipped it.\n' > $out/skills/dropped/SKILL.md
                printf 'kept\n' > $out/references/guide.md
                printf 'echo hi\n' > $out/skills/inner/scripts/run.sh
              '';
              built = lib'.buildAgentPlugin {
                name = "suite";
                src = suite;
                manifest = {
                  "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
                  name = "suite";
                };
                skills = { parent = "./"; inner = "skills/inner"; };
              };
            in
            pkgs.runCommand "root-skill-excludes-nested" { } ''
              p=${built}/share/agent-plugins/suite
              [ -f $p/skills/parent/SKILL.md ]
              [ -f $p/skills/parent/references/guide.md ]
              [ ! -e $p/skills/parent/skills ]
              [ -f $p/skills/inner/SKILL.md ]
              [ -f $p/skills/inner/scripts/run.sh ]
              [ ! -e $p/skills/dropped ]
              touch $out
            '';

          # A plugin built the way a generated source.json calls the
          # builder: src as a pin rather than a derivation, an import
          # record that only reaches passthru, and skills as plain
          # paths. The formals carry no `...`, so this also proves
          # every key a generated file writes is declared.
          source-shape =
            let lib' = mkLib pkgs; in
            lib'.buildAgentPlugin {
              name = "caveman";
              version = "0-unstable-2026-09-07";
              src = {
                owner = "juliusbrussee";
                repo = "caveman";
                rev = "15581d14007fd01fb3f132016741962f34936ca2";
                hash = "sha256-GuCK3oy0DsMOQq7gHjIY/aeaukJcTvelfg+tp7R7Du4=";
              };
              sourceUrl = "https://github.com/juliusbrussee/caveman";
              manifest = {
                "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
                name = "caveman";
                description = "Ultra-compressed communication mode";
              };
              skills = { cavecrew = "skills/cavecrew"; };
              # The skill is Markdown only, so import records no
              # interpreters and the package pulls none into its
              # closure. Present because a generated source.json
              # always writes the key.
              requiredRuntimes = [ ];
              meta = {
                description = "Ultra-compressed communication mode";
                homepage = "https://github.com/juliusbrussee/caveman";
              };
              import = {
                input = "juliusbrussee/caveman";
                flags = [ ];
                warnings = [
                  { path = "skills/cavecrew/SKILL.md"; message = "example, not a real deviation"; }
                ];
              };
            };

          # Every convention ADR 0014 records, asserted on real builds:
          # a declared SPDX licence resolves to the lib.licenses value,
          # an unrecognised licence string yields no assertion at all,
          # maintainers stay empty, and platforms and category are
          # always present.
          meta-conventions =
            let
              lib' = mkLib pkgs;
              src = pkgs.runCommand "meta-src" { } ''
                mkdir -p $out/skills/one
                printf -- '---\nname: one\ndescription: Does things.\n---\nBody.\n' \
                  > $out/skills/one/SKILL.md
              '';
              mk = { name, license ? null, description ? "Short summary", meta ? { } }:
                lib'.buildAgentPlugin {
                  inherit name src meta;
                  sourceUrl = "https://example.test/${name}";
                  manifest = {
                    "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
                    inherit name description;
                  } // nixpkgs.lib.optionalAttrs (license != null) { inherit license; };
                  skills.one = "skills/one";
                  requiredRuntimes = [ ];
                };
              mit = mk { name = "mit-plugin"; license = "MIT"; };
              apache = mk { name = "apache-plugin"; license = "Apache-2.0"; };
              unknown = mk { name = "unknown-plugin"; license = "SEE LICENSE IN LICENSE"; };
              none = mk { name = "none-plugin"; };
              longDesc = mk {
                name = "long-plugin";
                description = "First sentence. Second sentence carries the rest.";
                meta.description = "First sentence";
              };
              yes = p: f: nixpkgs.lib.boolToString (f p.meta);
              stack = lib'.mkAgentStack {
                name = "conventions-stack";
                harness = "claude";
                plugins = [ mit ];
              };
            in
            pkgs.runCommand "meta-conventions" { } ''
              [ "${mit.meta.license.spdxId}" = MIT ]
              [ "${apache.meta.license.spdxId}" = Apache-2.0 ]
              [ "${yes unknown (m: m ? license)}" = false ]
              [ "${yes none (m: m ? license)}" = false ]
              [ "${yes mit (m: m.maintainers == [ ])}" = true ]
              [ "${yes none (m: m.maintainers == [ ])}" = true ]
              [ "${mit.meta.category}" = agent-plugin ]
              [ "${yes mit (m: m.platforms == nixpkgs.lib.platforms.all)}" = true ]
              [ "${mit.meta.homepage}" = https://example.test/mit-plugin ]
              [ "${none.meta.description}" = "Short summary" ]
              [ "${yes none (m: m ? longDescription)}" = false ]
              [ "${longDesc.meta.description}" = "First sentence" ]
              [ "${longDesc.meta.longDescription}" = \
                "First sentence. Second sentence carries the rest." ]
              [ "${stack.meta.category}" = agent-stack ]
              [ "${yes stack (m: m.platforms == nixpkgs.lib.platforms.all)}" = true ]
              [ "${yes stack (m: m.maintainers == [ ])}" = true ]
              [ "${(mkAllPackages pkgs).claude-code.meta.category}" = agent ]
              [ "${(mkAllPackages pkgs).ccusage.meta.category}" = agent-tool ]
              [ "${(mkAllPackages pkgs).flox-agent.meta.category}" = agent-tool ]
              touch $out
            '';

          # The reference tells readers to attach postAssemble with
          # overrideAttrs. This is the check that sentence promises:
          # the hook runs on the assembled tree, and passthru survives
          # the override so downstream composition still works.
          override-hook =
            let
              lib' = mkLib pkgs;
              src = pkgs.runCommand "override-src" { } ''
                mkdir -p $out/skills/one
                printf -- '---\nname: one\ndescription: Does things.\n---\nBody.\n' \
                  > $out/skills/one/SKILL.md
              '';
              base = lib'.buildAgentPlugin {
                name = "overridable";
                inherit src;
                sourceUrl = "https://example.test/overridable";
                manifest = {
                  "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
                  name = "overridable";
                };
                skills.one = "skills/one";
                requiredRuntimes = [ ];
              };
              hooked = base.overrideAttrs (old: {
                postAssemble = (old.postAssemble or "") + ''
                  printf 'hooked\n' > "$dest/MARKER"
                '';
              });
              pinned = lib'.buildAgentPlugin {
                name = "caveman";
                src = {
                  owner = "juliusbrussee";
                  repo = "caveman";
                  rev = "15581d14007fd01fb3f132016741962f34936ca2";
                  hash = "sha256-GuCK3oy0DsMOQq7gHjIY/aeaukJcTvelfg+tp7R7Du4=";
                };
                sourceUrl = "https://github.com/juliusbrussee/caveman";
                manifest = {
                  "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
                  name = "caveman";
                };
                skills.cavecrew = "skills/cavecrew";
                requiredRuntimes = [ ];
              };
              yes = b: nixpkgs.lib.boolToString b;
            in
            pkgs.runCommand "override-hook" { } ''
              p=${hooked}/share/agent-plugins/overridable
              [ "$(cat $p/MARKER)" = hooked ]
              [ -f $p/plugin.json ]
              [ "${hooked.passthru.agentPlugin.name}" = overridable ]
              [ "${yes (hooked.passthru.agentPlugin.skills == [ "one" ])}" = true ]
              [ "${hooked.meta.category}" = agent-plugin ]
              [ "${yes (base.passthru.agentPlugin.rev == null)}" = true ]
              [ "${yes (base.passthru.agentPlugin.hash == null)}" = true ]
              [ "${pinned.passthru.agentPlugin.rev}" = \
                15581d14007fd01fb3f132016741962f34936ca2 ]
              touch $out
            '';

          # notPackages is a hand-maintained judgement against a set
          # that grows daily, so it needs a tripwire rather than a
          # convention. meta.mainProgram is the signal — every package
          # worth publishing has one — but it is used to ask a question,
          # never to filter: a new attribute without one fails this
          # check by name, and a human decides. Nothing is ever dropped
          # from the catalog without someone seeing it. ADR 0015.
          re-export-is-packages =
            let
              scope = (llmAgentsPkgsFor pkgs.stdenv.hostPlatform.system).llm-agents;
              suspect = name:
                let p = scope.${name}; in
                !(builtins.elem name notPackages)
                && !(builtins.elem name notPackagesExempt)
                && nixpkgs.lib.isDerivation p
                && nixpkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform p
                && !(p.meta.broken or false)
                && !(p.meta ? mainProgram);
              unclassified = builtins.filter suspect (builtins.attrNames scope);
            in
            pkgs.runCommand "re-export-is-packages" { } (
              if unclassified == [ ] then "touch $out"
              else ''
                cat >&2 <<'MSG'
                These attributes of llm-agents.nix have no meta.mainProgram and
                are not listed in notPackages in flake.nix:

                  ${builtins.concatStringsSep "\n  " unclassified}

                A missing mainProgram usually means the attribute is a setup
                hook, a builder or a toolchain rather than a package this set
                should publish; add it to notPackages. If it is a real package
                whose packager simply omitted the field, leave it published and
                add it to notPackagesExempt instead.
                MSG
                exit 1
              ''
            );

        };
    in
    {
      packages = forAllSystems mkAllPackages;

      # Deliberately the plugin set and the gates, not mkAllPackages:
      # `nix flake check` runs on GitHub runners in update-flake-lock,
      # and building every agent CLI there would spend hours saying
      # what Hydra already says from packages.*.
      checks = forAllSystems mkChecks;
      lib = forAllSystems mkLib;

      # What Hydra builds. packages.* is published to the agent-stacks
      # catalog; checks.* builds as a gate and is never published. The
      # jobset configuration lives in deltaops doc/hydra-jobsets.md,
      # because Hydra jobsets are configured in its web UI.
      hydraJobs = {
        packages = nixpkgs.lib.genAttrs systems (system:
          mkAllPackages (pkgsFor system));

        # Only the gates. Every package is also a check, and packages.*
        # already builds those; repeating them here would double the
        # jobset for no extra coverage.
        checks = nixpkgs.lib.genAttrs systems (system:
          let pkgs = pkgsFor system;
          in removeAttrs (mkChecks pkgs)
            (builtins.attrNames (mkPackages pkgs)));
      };
    };
}
