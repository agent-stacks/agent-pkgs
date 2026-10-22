# 0024. A re-exported package can carry a patch, named in `overrides/`

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
overlay and exposed as the flake output `overlays.llm-agents`. It
passes each entry in `overrides/default.nix` to that package's
`overrideAttrs`. Patch files live under `overrides/<name>/`. codex is
the only entry.

The re-export and the checks see the patched codex. Packages upstream
builds against codex don't (see Consequences).

Two checks guard the list:

- `overrides-name-packages` fails on a name upstream no longer
  defines, so a rename can't drop a patch unnoticed.
- `<name>-patches-apply` applies a package's patches to its source
  without building it, so a bump that breaks a patch fails the lock
  update. It also fails if the published package lacks a patch its
  override adds, as it would if the overlay stopped applying.

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
- `-` A patch that stops applying blocks the hourly lock update until
  someone rebases it.
- `-` `codex-acp`, `t3code`, `oh-my-codex` and `kandev` keep upstream's
  unpatched codex. Upstream builds them against codex from its own
  internal scope, which the overlay can't reach. If `llm-agents.nix`
  exposed that scope, for example so `overrideScope` works, the same
  overlay would patch codex for them too.
- `-` Not verified: the patched codex keeps version 0.163.0, which
  the catalog already has unpatched. Check what `agent-stacks/codex`
  resolves to before floxenvs deletes its codex.

---

Extends [0008](0008-re-export-llm-agents-nix.md).
