# Changes this set makes to a package it re-exports from llm-agents.nix.
#
# Exceptions only, keyed by the re-exported name: each value is the
# function handed to that package's overrideAttrs. Everything not named
# here is published as upstream builds it. A name upstream no longer
# defines fails evaluation rather than being skipped, so a rename
# cannot drop a patch without anyone seeing it. ADR 0024.
#
# A patch here changes the store path, so Hydra builds the package
# itself instead of finding it in upstream's cache, and the packages
# upstream builds against it (codex-acp, for codex) keep upstream's
# unpatched build: the scope they are called from is not exposed.
{
  # The two env vars agent-stacks launches codex with, so skills reach
  # it without writing to ~/.codex or the working tree: agent-stacks
  # ADR 0011. `agent-stacks doctor` finds the patch by grepping the
  # binary for CODEX_FLOX_SKILL_ROOTS, and reports codex degraded
  # without it. Carried verbatim from floxenvs' .flox/pkgs/codex.
  # Paths are relative to codex-rs, upstream's sourceRoot; re-verify on
  # every codex bump, which arrives with flake.lock.
  #
  # builtins.path copies the patch into a store path of its own. A bare
  # ./codex/flox-fragments.patch resolves inside this flake's source, so
  # every commit to the repository would change codex's derivation and
  # rebuild it from scratch.
  codex = old: {
    patches = (old.patches or [ ]) ++ [
      (builtins.path {
        path = ./codex/flox-fragments.patch;
        name = "codex-flox-fragments.patch";
      })
    ];
  };
}
