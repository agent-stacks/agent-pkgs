# Changes made to packages re-exported from llm-agents.nix, keyed by
# name. Each value is passed to that package's overrideAttrs. ADR 0024.
{
  # Adds the env vars agent-stacks passes skills through (agent-stacks
  # ADR 0011).
  #
  # builtins.path gives the patch its own store path. A plain path sits
  # inside this flake's source, so every commit would rebuild codex.
  codex = old: {
    patches = (old.patches or [ ]) ++ [
      (builtins.path {
        path = ./codex/flox-fragments.patch;
        name = "codex-flox-fragments.patch";
      })
    ];
  };
}
