# 0024. A re-exported package can carry a patch

Date: 2026-10-22

Status: Proposed

## Context

ADR 0008 publishes the `llm-agents.nix` packages as upstream builds
them. agent-stacks passes skills to codex in `CODEX_FLOX_SKILL_ROOTS`,
which upstream codex doesn't read. agent-stacks ADR 0011 adds it with
`flox-fragments.patch`, and without the patch `agent-stacks doctor`
reports codex as degraded. floxenvs builds its own patched codex and
can't drop it until this set publishes one.

The options:

- **Package codex under `pkgs/`.** It would clash with the re-export,
  `nix flake check` would build it on GitHub runners, and we would own
  upstream's whole recipe.
- **Upstream.** The env vars serve agent-stacks, not codex users.
  codex 0.163 does have its own extra skill roots
  (`SkillsExtraRootsSet`), but only over the app-server protocol. If
  upstream exposed that on the command line, the patch could go.
- **`overrideAttrs` on each package as it is re-exported.** The recipe
  and version still come from upstream; only the patch lives here. But
  the patch exists only in the re-export, so some checks read a
  different codex from the one published.
- **An overlay on the llm-agents set.** The same, except the patched
  package is in the set itself, so the re-export and every check see
  one codex. Later changes to the set have one place to go.

## Decision

We will patch packages with an overlay on the llm-agents set,
`overlays/llm-agents.nix`, applied after upstream's `shared-nixpkgs`
overlay and exposed as the flake output `overlays.llm-agents`. Each
patch sits next to it. codex is the only package it changes.

The re-export and the checks see the patched codex. Packages upstream
builds against codex don't (see Consequences).

A change every user of the package would want goes upstream instead.

## Consequences

- `+` The published codex passes `doctor`, so floxenvs can drop its
  recipe.
- `+` codex's version and recipe still track upstream.
- `+` A flake that builds its own llm-agents set can apply the same
  overlay.
- `-` `overlays.llm-agents` is a public output, so changing what it
  takes or does affects those flakes.
- `-` codex no longer comes from `cache.numtide.com`. Hydra builds it
  on every bump.
- `-` `nix flake check` doesn't build the re-export (ADR 0008), so a
  patch that stops applying or compiling is caught only by Hydra,
  after the lock update merges. One that compiles but stops working is
  caught by nothing: `doctor` only looks for the env var's name in the
  binary.
- `-` If upstream renames or drops codex, the flake fails to evaluate
  and the lock update is blocked until the overlay is fixed.
- `-` `codex-acp`, `t3code`, `oh-my-codex` and `kandev` keep upstream's
  unpatched codex. Upstream builds them against codex from its own
  internal scope, which the overlay can't reach. If `llm-agents.nix`
  exposed that scope, for example so `overrideScope` works, the same
  overlay would patch codex for them too.
- `+` The patched codex keeps upstream's version. The catalog already
  holds several builds of one version (two of codex 0.163.0 per
  system on 2026-10-22), and resolving `agent-stacks/codex@0.163.0`
  returned the newest, so no version suffix is needed. A suffix would
  also fail upstream's `versionCheckHook`.

---

Extends [0008](0008-re-export-llm-agents-nix.md).
