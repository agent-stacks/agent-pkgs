{
  description = "Nix package set for Agent Plugins and Agent Stacks";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; }));

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

          # The substitution pass (AI-640) attaches via overrideAttrs
          # on the postAssemble hook — prove that extension point works.
          override-hook =
            let
              overridden = (mkPackages pkgs).example-assembled.overrideAttrs (prev: {
                postAssemble = (prev.postAssemble or "") + ''
                  echo hooked > "$dest/HOOKED"
                '';
              });
            in
            pkgs.runCommand "check-override-hook" { } ''
              [ -f ${overridden}/share/agent-plugins/example-assembled/HOOKED ] \
                || { echo "postAssemble hook did not run"; exit 1; }
              touch $out
            '';

          # A generated mcp.json must target the same spec version as
          # the manifest; a mismatch makes clients disable MCP for the
          # plugin (spec §7.2.2).
          mcp-spec-version =
            let
              plugin = (mkLib pkgs).buildAgentPlugin {
                name = "mcp-versioned";
                src = ./pkgs/example-runtimes/src;
                manifest = {
                  "$schema" = "https://agent-plugins.org/schemas/1.1.0/plugin.schema.json";
                  name = "mcp-versioned";
                };
                skills.greet = "skills/greet";
                mcpServers.hello = {
                  type = "stdio";
                  command = "bash";
                };
              };
            in
            pkgs.runCommand "check-mcp-spec-version" { } ''
              got=$(${pkgs.jq}/bin/jq -r '."$schema"' \
                ${plugin}/share/agent-plugins/mcp-versioned/mcp.json)
              want=https://agent-plugins.org/schemas/1.1.0/mcp.schema.json
              [ "$got" = "$want" ] || { echo "mcp.json targets $got, want $want"; exit 1; }
              touch $out
            '';

          # AI-640 acceptance: interpreters land in the closure, the
          # shebangs and mcp.json point at the plugin-local bin/.
          runtimes-closure =
            let plugin = (mkPackages pkgs).example-runtimes;
            in pkgs.runCommand "check-runtimes-closure" { } ''
              tree=${plugin}/share/agent-plugins/example-runtimes
              for tok in python3 node; do
                [ -L "$tree/bin/$tok" ] || { echo "bin/$tok missing"; exit 1; }
                target=$(readlink "$tree/bin/$tok")
                [ -x "$target" ] || { echo "bin/$tok target $target not in closure"; exit 1; }
              done
              py="$tree/skills/greet/scripts/hello.py"
              head -1 "$py" | grep -q "^#!$tree/bin/python3$" \
                || { echo "shebang not rewritten: $(head -1 "$py")"; exit 1; }
              [ -x "$py" ] || { echo "hello.py not executable"; exit 1; }
              "$py" | grep -q "hello from python" || { echo "hello.py does not run"; exit 1; }
              cmd=$(${pkgs.jq}/bin/jq -r '.mcpServers.hello.command' "$tree/mcp.json")
              [ "$cmd" = "$tree/bin/python3" ] \
                || { echo "mcp command not rewritten: $cmd"; exit 1; }
              touch $out
            '';

          # AI-640 acceptance: two plugins with conflicting interpreter
          # versions coexist in one stack.
          runtimes-two-pythons =
            let
              lib' = mkLib pkgs;
              pinned = lib'.buildAgentPlugin {
                name = "example-runtimes-pinned";
                src = ./pkgs/example-runtimes/src;
                manifest = {
                  "$schema" = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json";
                  name = "example-runtimes-pinned";
                };
                skills.greet = "skills/greet";
                runtimes.python3 = pkgs.python312;
              };
              stack = lib'.mkAgentStack {
                name = "two-pythons";
                harness = "claude";
                plugins = [ (mkPackages pkgs).example-runtimes pinned ];
              };
            in
            pkgs.runCommand "check-two-pythons" { } ''
              a=$(readlink ${stack}/share/agent-plugins/example-runtimes/bin/python3)
              b=$(readlink ${stack}/share/agent-plugins/example-runtimes-pinned/bin/python3)
              [ "$a" != "$b" ] || { echo "expected two different pythons, got $a twice"; exit 1; }
              case "$b" in *3.12*) ;; *) echo "pinned python is not 3.12: $b"; exit 1 ;; esac
              "$a" -c 'print(1)' >/dev/null && "$b" -c 'print(1)' >/dev/null \
                || { echo "one of the pythons does not run"; exit 1; }
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

          # A stack composed from two real plugins.
          stack-layout =
            let
              demoStack = (mkLib pkgs).mkAgentStack {
                name = "demo-stack";
                harness = "claude";
                plugins = [
                  (mkPackages pkgs).example-plugin
                  (mkPackages pkgs).example-runtimes
                ];
              };
            in
            pkgs.runCommand "check-stack-layout" { } ''
              for p in example-plugin example-runtimes; do
                [ -f ${demoStack}/share/agent-plugins/$p/plugin.json ] \
                  || { echo "missing plugin.json for $p"; exit 1; }
                [ -d ${demoStack}/share/agent-plugins/$p/skills ] \
                  || { echo "missing skills/ for $p"; exit 1; }
              done
              # AI-640 put interpreters here; composition must not lose them.
              [ -L ${demoStack}/share/agent-plugins/example-runtimes/bin/python3 ] \
                || { echo "runtime bin/ lost in composition"; exit 1; }
              touch $out
            '';

          # The launcher names the adapter, pins a package harness, and
          # keeps the FLOX_AGENT_BIN override until AI-635 lands.
          stack-launcher =
            let
              fakeClaude = pkgs.writeShellScriptBin "claude" "exec true";
              pinnedStack = (mkLib pkgs).mkAgentStack {
                name = "pinned-stack";
                harness = fakeClaude;
                plugins = [ (mkPackages pkgs).example-plugin ];
              };
              pathStack = (mkLib pkgs).mkAgentStack {
                name = "path-stack";
                harness = "claude";
                plugins = [ (mkPackages pkgs).example-plugin ];
              };
            in
            pkgs.runCommand "check-stack-launcher" { } ''
              pinned=${pinnedStack}/bin/pinned-stack
              [ -x "$pinned" ] || { echo "launcher not executable"; exit 1; }
              grep -q 'launch claude' "$pinned" \
                || { echo "launcher does not name the adapter"; exit 1; }
              grep -q '${fakeClaude}/bin' "$pinned" \
                || { echo "pinned harness not on PATH"; exit 1; }
              grep -q 'FLOX_AGENT_BIN' "$pinned" \
                || { echo "launcher lost the FLOX_AGENT_BIN override"; exit 1; }
              grep -q "${pinnedStack}/share" "$pinned" \
                || { echo "launcher does not point at its own share dir"; exit 1; }

              plain=${pathStack}/bin/path-stack
              grep -q 'export PATH' "$plain" \
                && { echo "unpinned harness must not touch PATH"; exit 1; }
              touch $out
            '';

          # The audit output ships a runnable auditor over every skill.
          stack-audit =
            let
              gatedStack = (mkLib pkgs).mkAgentStack {
                name = "gated-stack";
                harness = "claude";
                plugins = [ (mkPackages pkgs).example-plugin ];
                audit = {
                  tools = [ pkgs.jq ];
                  threshold = 70;
                };
              };
              plainStack = (mkLib pkgs).mkAgentStack {
                name = "plain-stack";
                harness = "claude";
                plugins = [ (mkPackages pkgs).example-plugin ];
              };
            in
            pkgs.runCommand "check-stack-audit" { } ''
              gated=${gatedStack.audit}/bin/gated-stack-audit
              [ -x "$gated" ] || { echo "audit script missing"; exit 1; }
              grep -q -- '--threshold 70' "$gated" \
                || { echo "threshold not passed to audit"; exit 1; }
              grep -q '${pkgs.jq}/bin' "$gated" \
                || { echo "audit tools not on PATH"; exit 1; }
              grep -q "${gatedStack}/share/agent-plugins" "$gated" \
                || { echo "auditor does not read its own stack"; exit 1; }

              plain=${plainStack.audit}/bin/plain-stack-audit
              [ -x "$plain" ] || { echo "default audit script missing"; exit 1; }
              grep -q -- '--threshold' "$plain" \
                && { echo "no threshold configured, none expected"; exit 1; }
              touch $out
            '';

          # AI-560: invalid stacks must fail at evaluation, not at run
          # time. tryEval catches throw; forcing drvPath forces the
          # arguments that contain the throws.
          stack-assertions =
            let
              plugin = (mkPackages pkgs).example-plugin;
              failsToEval = args:
                !(builtins.tryEval
                  ((mkLib pkgs).mkAgentStack args).drvPath).success;
              cases = [
                {
                  label = "missing harness";
                  bad = failsToEval { name = "s"; plugins = [ plugin ]; };
                }
                {
                  label = "unknown adapter";
                  bad = failsToEval { name = "s"; harness = "emacs"; };
                }
                {
                  label = "non-plugin package";
                  bad = failsToEval {
                    name = "s";
                    harness = "claude";
                    plugins = [ pkgs.hello ];
                  };
                }
                {
                  label = "duplicate plugin names";
                  bad = failsToEval {
                    name = "s";
                    harness = "claude";
                    plugins = [ plugin plugin ];
                  };
                }
                {
                  label = "package harness without mainProgram";
                  bad = failsToEval {
                    name = "s";
                    harness = pkgs.stdenvNoCC.mkDerivation {
                      name = "no-mainProgram";
                      dontUnpack = true;
                      dontPatchShebangs = true;
                      installPhase = "mkdir -p $out/bin; touch $out/bin/test";
                      meta = { };
                    };
                  };
                }
                {
                  label = "harness given as a Nix path literal";
                  bad = failsToEval {
                    name = "s";
                    harness = ./flake.nix;
                  };
                }
                {
                  label = "unknown audit option";
                  bad = failsToEval {
                    name = "s";
                    harness = "claude";
                    audit.threshhold = 70;
                  };
                }
              ];
              report = c:
                if c.bad
                then ''echo "ok: ${c.label} rejected"''
                else ''
                  echo "FAIL: ${c.label} evaluated but should not have"
                  exit 1
                '';
            in
            pkgs.runCommand "check-stack-assertions" { }
              (pkgs.lib.concatMapStringsSep "\n" report cases + ''

                touch $out
              '');
        });
      lib = forAllSystems mkLib;
    };
}
