# 0025. A skill's own engine is built from the skill's source

Date: 2026-10-22

Status: Proposed

## Context

Every command in `pbakaus/impeccable`'s skill runs
`scripts/impeccable <verb>`, a shell launcher in front of a compiled
Rust engine that `agent-plugin-impeccable` does not contain (AI-760).
The launcher tries `$IMPECCABLE_BIN`, a sibling binary at
`scripts/bin/<os>-<arch>/impeccable`, two caches under
`~/.impeccable`, and `impeccable` on PATH. Failing all of those, it
downloads the release asset for `scripts/VERSION` from GitHub,
checks it against the `.sha256` beside it, and caches it in the
user's home. With no network it exits 127. So the package builds and
passes `check-plugin`, but what runs is not in the closure, and the
skill does not work offline.

The engine is not a third-party tool. It is built from the Cargo
workspace in the same repository at the same commit, and upstream
pins it to the skill: `scripts/VERSION` names the exact engine
release, and upstream's own distribution puts the binary in the
sibling slot inside the skill's tree. ADR 0011 refuses to carry or
pin a tool a skill drives, because the user already has that tool at
a version they chose. Its other rule fits better here: "a script in
the skill's own tree is part of the skill".

Checked at `e07dc01` (skill 4.7.0, engine 0.1.16):
`cargo build --release -p impeccable` builds offline from the
committed `Cargo.lock`, with no `wasm-pack`. With the engine in the
slot, `context` and `detect` work with no network. The engine also
checks `impeccable.style` for a newer skill, caches the answer in
`~/.impeccable/update-check.json`, and tells the agent to offer
`npx impeccable update`, which cannot rewrite a store path.
`IMPECCABLE_NO_UPDATE_CHECK=1` turns that check off.

Reading `Cargo.lock` out of a `fetchFromGitHub` source is
import-from-derivation. The alternative is a vendor hash kept by
hand, and the hourly replay moves the source without moving that
hash.

## Decision

We will package the engine as `pkgs/impeccable-engine`, its own
package as ADR 0011 requires of a tool we package. It builds
`crates/cli` from the commit `agent-plugin-impeccable` pins, read from
that package's `source.json`, so a replay moves both. It fetches the
source with `builtins.fetchTarball` and the recorded hash, which
yields the same store path as the plugin's source. It reads
`Cargo.lock` and the version from that tree at evaluation, so there
is no vendor hash to keep and no import-from-derivation. Its install
check fails when `engine-probe` disagrees with the skill's
`scripts/VERSION`, since the launcher runs the slot without asking.

We will ship it in the plugin from its `default.nix` custom block: a
binary wrapper at the launcher's sibling slot for the build's
platform, setting `IMPECCABLE_NO_UPDATE_CHECK=1` unless the caller
set it. The launcher finds it before anything in the user's home, and
never downloads.

This classifies a binary built from the skill's own commit and
pinned by the skill as part of the skill. ADR 0011 still governs a
tool the skill drives. We will not build an importer or builder
mechanism for one package. A second case is the evidence for one.

## Consequences

- `+` The skill and its hooks work offline, and run what Nix built.
  Nothing is written to `~/.impeccable`.
- `+` A replay moves the engine with the skill. There is no hash or
  version to keep in step by hand.
- `+` `impeccable-engine` is installable on its own, for a skill
  installed some other way.
- `-` Evaluating either package fetches the impeccable tarball, so
  `nix flake check` and Hydra's evaluation do too.
- `-` The plugin's closure gains a 19 MB binary. Each bump is a Rust
  build with fat LTO, where it used to be a copy.
- `-` A commit whose engine fails to build now fails the plugin too.
  So does one whose engine and `scripts/VERSION` disagree.
- `-` The build runs the binary's unit tests only. The integration
  suites drive Chrome and timed loopback servers, and fail in the
  sandbox.
- `-` The slot is filled by hand in one package's block. A second
  skill shaped like this repeats the work until a mechanism exists.
- `-` The engine's telemetry stays as upstream ships it, on unless
  `DO_NOT_TRACK` or `IMPECCABLE_NO_TELEMETRY` is set.
