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
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      # flox-agent carries an unfree license, which a default nixpkgs refuses
      # to evaluate — that would break the plain `nix run <flake>#flox-agent`
      # this set exists to offer. The allowance is scoped to that one pname
      # rather than the whole instance, so an unfree dependency drifting into
      # any other package still fails loudly. It governs only packages built
      # through this flake; a consumer's own nixpkgs config is untouched.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "flox-agent-bin";
      };

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (pkgsFor system));

      # Systems Hydra builds and the catalog caches. x86_64-darwin is
      # deliberately absent: it stays in packages and checks so an Intel
      # Mac can still build from source, it is simply not cached.
      hydraSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];

      # Held out of hydraJobs entirely, so the publish hook never pushes it.
      # The binary is already downloadable from downloads.agent-stacks.org;
      # whether it is also served from a public catalog is a separate call,
      # not a side effect of adding a file to pkgs/. Drop the name from this
      # list to start publishing it.
      isUnpublished = name: name == "flox-agent";

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
        buildAgentPlugin = pkgs.callPackage ./lib/build-agent-plugin.nix { };
        mkAgentStack = pkgs.callPackage ./lib/mk-agent-stack.nix {
          defaultAuditTools = import ./mappings/audit-tools.nix { inherit pkgs; };
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
    in
    {
      packages = forAllSystems mkPackages;
      checks = forAllSystems (pkgs:
        mkPackages pkgs // {
          # Assert the canonical layout and passthru for every package.
          layout = pkgs.runCommand "check-layout"
            {
              plugins = map (p: "${p} ${p.passthru.agentPlugin.path}")
                (builtins.filter (p: p.passthru ? agentPlugin)
                  (builtins.attrValues (mkPackages pkgs)));
            } ''
            set -- $plugins
            while [ $# -ge 2 ]; do
              root="$1"; rel="$2"; shift 2
              tree="$root/$rel"
              [ -f "$tree/plugin.json" ] || { echo "missing plugin.json in $tree"; exit 1; }
              [ -d "$tree/skills" ] || { echo "missing skills/ in $tree"; exit 1; }
              found=0
              for s in "$tree/skills"/*/; do
                [ -f "$s/SKILL.md" ] || { echo "missing SKILL.md in $s"; exit 1; }
                found=1
              done
              [ "$found" = 1 ] || { echo "no skills in $tree"; exit 1; }
            done
            touch $out
          '';

          # AI-640: an unmapped runtime fails the build with a message
          # pointing at the table, and the guard catches executables
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

        });
      lib = forAllSystems mkLib;

      # What Hydra builds: packages.*, published to the agent-stacks
      # catalog. The jobset configuration lives in deltaops
      # doc/hydra-jobsets.md, because Hydra jobsets are configured in
      # its web UI.
      hydraJobs = {
        packages = nixpkgs.lib.genAttrs hydraSystems (system:
          let all = mkPackages (pkgsFor system);
          in nixpkgs.lib.filterAttrs (name: _: !isUnpublished name) all);
      };
    };
}
