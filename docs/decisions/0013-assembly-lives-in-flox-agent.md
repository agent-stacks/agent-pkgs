# 0013. Assembly lives in flox-agent

Date: 2026-09-15

Status: Accepted

## Context

Plugin assembly, substitution, and the shebang guard used to be a
shell `buildPhase` generated per skill inside
`lib/build-agent-plugin.nix`. The reasoning for moving that work into
`flox-agent assemble-plugin` — a shared, tested scanner used by both
`import` and the build, instead of a Go answer and an untested shell
answer that could silently disagree — is recorded in flox-agent
ADR 0025, `docs/decisions/0025-the-scanner-is-shared-and-recorded.md`
in that repository. This record does not restate it; it covers what
changes on the agent-pkgs side, the same division the two
repositories already keep with each other (see
`docs/decisions/README.md`).

## Decision

**`lib/build-agent-plugin.nix` no longer assembles a plugin tree
itself.** Its build phase calls `flox-agent assemble-plugin`, which
performs skill selection in all three modes, the prune rule (ADR
0012), the ADR 0009 manifest precedence, runtime substitution, and the
guard, in one process. The Nix side keeps fetching, runtime
resolution, install, the check phase, and passthru.

Consequences that follow from that move:

**`lib/` now requires a flox-agent package.** `defaultFloxAgent ?
null` used to mean "skip validation" — a `check-plugin` run over a
tree the shell had already built. Assembly cannot be skipped the same
way, because assembly is now where the tree gets built in the first
place, not an optional check layered on top of one the shell already
produced. `buildAgentPlugin` asserts `floxAgent != null`.

**`allowEnvShebangs` is gone, formal and all.** It was declared as a
`buildAgentPlugin` argument but never reachable from a generated
package: `import` had no way to emit it, because it was absent from
the `Call` struct that defines `source.json`'s shape. The guard's old
error message told a reader to use a flag that no generated `source.json`
could ever set. The two real remedies — map the runtime, or move the
file under `assets/` — are what the new guard names instead.

**`requiredRuntimes` is mandatory for a generated package and absent
for a hand-written one.** A `source.json` that carries `import` (the
mark of a package `flox-agent import` produced) must also carry
`requiredRuntimes`; a package built from a hand-written
`buildAgentPlugin` call — the flake checks, a downstream consumer of
`lib/` — carries no `import` and falls back to resolving the whole
runtime table, which is what every package got before this change.
That fallback is what keeps the `unmapped` and `arguments-alone` flake
checks working: they call `buildAgentPlugin` directly, with no
`source.json` and no recorded runtime list, and still need every
mapped name available to exercise.

**`jq` is no longer a build input.** The shell phase used it to read
`source.json` and assemble `plugin.json`; both are now read and
written by `assemble-plugin` itself.

**`dontPatchShebangs = true` is now set.** This was found during the
work, not planned going in: nixpkgs' `fixupPhase` runs `patchShebangs`
over `$out`, and it was rewriting shebangs under `assets/` — the exact
files the substitution pass and the guard both deliberately leave
alone, because they are static templates a skill may copy out of the
plugin. `fixupPhase` rewrote them not to `<plugin>/bin/<tok>`, the
form the pass uses, but to a bare interpreter store path such as
`/nix/store/…-bash-5.3p15/bin/bash` — a path that dangles on any other
machine, which is worse than the `/usr/bin/env` shebang it replaced. A
static template whose whole purpose is to leave the plugin was
shipping an absolute path that only resolves on the machine that built
it. It was a third actor disagreeing with both the substitution pass
and the guard about who owns shebangs in this tree; disabling
`patchShebangs` settles that the builder owns them outright.

One package's output changed as a direct result:
`agent-plugin-hyperframes`'s three `assets/test-corpus` files now ship
upstream's own `#!/usr/bin/env bash`, unrewritten, instead of the
dangling store path `fixupPhase` had been substituting.

## Consequences

- `+` One assembly implementation, tested in Go, replaces a shell
  phase whose edge cases were found in production (see ADR 0025's
  account of AI-718).
- `+` A generated package's `source.json` fully determines what the
  build does; there is no shell-side logic left to diverge from it.
- `+` The `assets/` exemption is enforced consistently: neither the
  substitution pass nor `fixupPhase` touches those files now.
- `-` `lib/` cannot build a plugin without a flox-agent binary
  present, even for the simplest hand-written call. There is no
  reduced-dependency path left.
- `-` `allowEnvShebangs`'s removal forecloses the escape hatch for
  anyone who was relying on hand-editing a `source.json` to set it,
  unreachable as it already was from `import`.
- `-` Reading what a build phase does now means reading Go across two
  flox-agent packages (`internal/plugin/scan`,
  `internal/plugin/assemble`) rather than one Nix expression; the
  six-line `buildPhase` left in `lib/build-agent-plugin.nix` is a
  dispatch, not a description.
