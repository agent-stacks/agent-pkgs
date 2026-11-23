# Patches packages of the llm-agents set. Compose it after
# llm-agents.nix's shared-nixpkgs overlay. ADR 0024.
final: prev: {
  llm-agents = prev.llm-agents // {
    # Adds the env vars agent-stacks passes skills and plugins through
    # (agent-stacks ADR 0007, ADR 0024 here).
    #
    # builtins.path gives the patch its own store path. A plain path sits
    # inside this flake's source, so every commit would rebuild codex.
    codex = prev.llm-agents.codex.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        (builtins.path {
          path = ./codex-flox-fragments.patch;
          name = "codex-flox-fragments.patch";
        })
      ];

      # A patch that still applies and compiles can stop working after a
      # codex bump. Fail the build if codex no longer loads a plugin's
      # MCP server from CODEX_FLOX_PLUGIN_ROOT, or loads it without one.
      postInstallCheck = (old.postInstallCheck or "") + ''
        plugin_root=$(mktemp -d)
        probe=$plugin_root/flox-check/probe
        mkdir -p $probe/.codex-plugin
        echo '{"name":"probe","version":"1.0.0"}' > $probe/.codex-plugin/plugin.json
        echo '{"mcpServers":{"flox-probe":{"command":"true"}}}' > $probe/.mcp.json
        servers() {
          HOME=$(mktemp -d) CODEX_HOME=$(mktemp -d) \
            $out/bin/codex -c plugins.probe@flox-check.enabled=true mcp list < /dev/null
        }
        with_root=$(CODEX_FLOX_PLUGIN_ROOT=$plugin_root servers)
        without_root=$(servers)
        if [[ $with_root != *flox-probe* ]]; then
          echo "codex did not load a plugin from CODEX_FLOX_PLUGIN_ROOT:" >&2
          echo "$with_root" >&2
          exit 1
        fi
        if [[ $without_root == *flox-probe* ]]; then
          echo "codex loaded a plugin with CODEX_FLOX_PLUGIN_ROOT unset" >&2
          exit 1
        fi
      '';
    });
  };
}
