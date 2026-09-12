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

          # ADR 0008, every path: an assembled package with a foreign
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
      packages = forAllSystems mkPackages;
      checks = forAllSystems mkChecks;
      lib = forAllSystems mkLib;

      # What Hydra builds. packages.* is published to the agent-stacks
      # catalog; checks.* builds as a gate and is never published. The
      # jobset configuration lives in deltaops doc/hydra-jobsets.md,
      # because Hydra jobsets are configured in its web UI.
      hydraJobs = {
        packages = nixpkgs.lib.genAttrs systems (system:
          mkPackages (pkgsFor system));

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
