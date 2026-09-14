# 0008. Re-export llm-agents.nix into the package set

Date: 2026-09-14

Status: Accepted

## Context

This set packages plugins and stacks. A stack also needs the agent
itself — `claude-code`, `codex`, `opencode` — and nothing here
packages one. `numtide/llm-agents.nix` already packages roughly 170 of
them and updates daily.

Two things stand in the way of simply depending on it. That flake
builds against `NixOS/nixpkgs-unstable`, and the Flox catalog rejects
a revision it has no page for, so its `packages.*` outputs cannot be
published from here. And about a seventh of the set is unfree, while
`allowUnfreePredicate` here is deliberately narrowed to the single
`flox-agent-bin` name.

Upstream anticipates the first problem: `overlays.shared-nixpkgs`
calls its `mkPackagesFor` against the consumer's `final`, which is how
that flake supports being rebuilt against another package set.

## Decision

We will add `llm-agents.nix` as a flake input and re-export the
packages it produces, built through `overlays.shared-nixpkgs` against
the Flox nixpkgs fork this set already pins.

The input's own `nixpkgs` is not followed to ours. That set pins its
own `bun` on purpose, to keep the bun-built packages substitutable
from its cache, and following would take the pin away.

Re-exported packages are named flat, without a prefix. The filter is
upstream's own: derivations only, available on the platform, not
broken. Where a name exists both here and upstream, the package in
`pkgs/` wins and the evaluation prints a warning naming the
collision — silent shadowing is how a plugin stops matching what
upstream publishes without anyone noticing.

`allowUnfree` is set for the nixpkgs instance the re-export is built
from, and only that instance. The set gains packages daily, so a list
of permitted names here would be stale within the week. The narrow
predicate still governs everything built from `pkgs/`.

The re-export reaches `packages.*` and `hydraJobs.packages`, not
`checks`. `nix flake check` runs on GitHub runners in
`update-flake-lock`, where building every agent CLI would take hours
to report what Hydra reports anyway.

## Consequences

- `+` A stack can name its harness as a package from this set, pinned
  with its runtime, instead of resolving one from PATH.
- `+` The catalog carries the agents and the plugins together, built
  against one nixpkgs revision.
- `+` Upstream's daily updates arrive with `flake.lock`; no list of
  packages to maintain here.
- `-` Hydra's jobset grows by roughly 170 jobs per system, and the
  builds are against the Flox fork, so upstream's cache hits only for
  packages whose inputs happen to match.
- `-` We redistribute unfree binaries through our own cache and
  catalog. Accepted deliberately; the licences are upstream's to
  state and ours to respect.
- `-` The lock file carries a second nixpkgs.
- `-` An upstream package that breaks becomes a red Hydra job here,
  for a package nobody in this repo wrote.
