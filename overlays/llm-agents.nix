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

    # nixpkgs' cargo setup hook now exports AWS_LC_SYS_USE_SYSTEM=1, so
    # aws-lc-sys links the system AWS-LC instead of building its own, and
    # panics when it finds none. nono vendors aws-lc-sys and declares
    # none; give it nixpkgs' aws-lc, and pkg-config to find it (nono has
    # pkg-config only on Linux), as nixpkgs does for its own packages.
    # Harmless before that change: the hook did not set the variable, so
    # aws-lc-sys built from source.
    nono = prev.llm-agents.nono.overrideAttrs (old: {
      buildInputs = (old.buildInputs or [ ]) ++ [ final.aws-lc ];
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.pkg-config ];
    });
  };
}
