{
  description = "Nix package set for Agent Plugins and Agent Stacks";

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

      # Upstream's packages/ also holds builders and hooks — wrapBuddy,
      # buildNpmPackage, the fetchers — which are functions rather than
      # derivations. Broken and foreign-platform packages are dropped
      # the same way that flake drops them from its own packages
      # output: a package that cannot run on aarch64-darwin has no
      # business being an aarch64-darwin job.
      llmAgentsFor = system:
        let
          pkgs = llmAgentsPkgsFor system;
          keep = _: p:
            nixpkgs.lib.isDerivation p
            && nixpkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform p
            && !(p.meta.broken or false);
        in
        nixpkgs.lib.filterAttrs keep pkgs.llm-agents;

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
