# 0024. A re-exported package can carry a patch

Date: 2026-10-22

Status: Proposed

## Context

ADR 0008 publishes the `llm-agents.nix` packages as upstream builds
them. agent-stacks passes skills to codex in `CODEX_FLOX_SKILL_ROOTS`,
which upstream codex doesn't read. agent-stacks ADR 0007 adds it with
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
overlay. Each patch sits next to it. codex is the only package it
changes.

The re-export and the checks see the patched codex. Packages upstream
builds against codex don't (see Consequences).

A change every user of the package would want goes upstream instead.

## Consequences

- `+` The published codex passes `doctor`, so floxenvs can drop its
  recipe.
- `+` codex's version and recipe still track upstream.
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

## Amended 2026-11-23

The patch now carries two env vars:

- `CODEX_FLOX_PLUGIN_ROOT` names a folder laid out as
  `<marketplace>/<plugin>/`. Codex loads a plugin with a folder there
  from that folder, at version `flox`, instead of from
  `$CODEX_HOME/plugins/cache/`, and never refreshes its cache copy.
  Plugins are still turned on with `-c plugins.<id>.enabled=true`,
  where `<id>` is `<plugin>@<marketplace>`. So `agent-stacks launch`
  can hand codex plugins for one process without writing the cache.
- `CODEX_FLOX_SKILL_ROOTS` stays until agent-stacks stops setting it.

`CODEX_FLOX_INSTRUCTIONS_FILE` is dropped: nothing set it.

Plugin data stays in `$CODEX_HOME/plugins/data`, and codex's own
install and uninstall still act only on the cache. A plugin folder may
be a link, but codex refuses hooks from a plugin that contains one. A
hook approval carries over between folders when the files are the
same. Executor capability discovery, off by default, reads only the
cache.

agent-stacks will tell a patched codex by this variable's name once
its launch uses it; today it still looks for `CODEX_FLOX_SKILL_ROOTS`.

The plugin root is also asked of codex upstream. If codex adds one,
the patch drops this part.

The codex build now runs a check that a plugin loads from the root and
not without it. A patch that compiles but stops loading plugins fails
Hydra's build instead of being caught by nothing. The other
consequences above still hold.

---

Extends [0008](0008-re-export-llm-agents-nix.md).
