# Patches packages of the llm-agents set. Compose it after
# llm-agents.nix's shared-nixpkgs overlay. ADR 0024.
final: prev: {
  llm-agents = prev.llm-agents // {
    # Adds the env vars agent-stacks passes skills through (agent-stacks
    # ADR 0011).
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
    });
  };
}
