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
  `<marketplace>/<plugin>/`. When codex looks up a plugin that has a
  folder there, it loads it from that folder instead of
  `$CODEX_HOME/plugins/cache/`. Plugins are still turned on with
  `-c plugins.<id>.enabled=true`. So `agent-stacks launch` can hand
  codex its plugins for one process without writing the user's cache.
  Such a plugin reports the version `flox`.
- `CODEX_FLOX_SKILL_ROOTS` stays until agent-stacks stops setting it.

`CODEX_FLOX_INSTRUCTIONS_FILE` is dropped: nothing set it.

The patch changes only how codex finds a plugin's folder. Skills, MCP
servers and hooks load from it as from the cache. Plugin data stays in
`$CODEX_HOME/plugins/data`, and codex's own install and uninstall still
act only on the cache. A hook approval carries over between folders
when the plugin's files are the same, because codex hashes them
relative to the plugin's root. Executor capability discovery, a codex
feature that is off by default, still reads only the cache.

agent-stacks finds the patch by looking for a variable's name in the
binary; `CODEX_FLOX_PLUGIN_ROOT` is the one that marks plugin support.
The consequences above still hold.

---

Extends [0008](0008-re-export-llm-agents-nix.md).
