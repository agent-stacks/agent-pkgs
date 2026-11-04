# 0028. The call file is default.json, and imports pass --pkgs-dir

Date: 2026-10-30

Status: Proposed

## Context

agent-stacks ADR 0086 renames each plugin package's call file from
`source.json` to `default.json`, and removes `import --out`, which
became an alias of `--pkgs-dir` in agent-stacks ADR 0083. This
repository reads the file in several places, and calls import with
`--out` in two workflows:

- `update-agent-plugins` lists every recorded input, then replays it.
- `update-agent-stacks` replays one recorded input with the newly
  uploaded binary.
- `audit-plugins` triggers on the file, and keys each audit to it.
- `scripts/audit-dashboard.py` reads each package's version and
  upstream from it.
- `pkgs/impeccable-engine` builds from the commit its sibling
  `agent-plugin-impeccable` pins there.

The workflows run the pinned binary, or in `update-agent-stacks` the
new one. So what they pass, and what they read, has to work with the
binaries on both sides of the change.

## Decision

We will read either name, `default.json` first, and pass `--pkgs-dir`.

- **Reading.** Every reader takes a package's `default.json` when it
  exists, else its `source.json`, the importer's own precedence. Each
  package is read once. Only `agent-plugin-*` directories are package
  directories: `pkgs/agent-stacks/default.json` is the pinned
  `hashes.json`, not a call.
- **The imports.** Both workflows' imports pass `--pkgs-dir pkgs`
  instead of `--out pkgs`.
- **Audits.** `audit-plugins` triggers on both names, and an audit's
  key hashes `default.nix` with whichever call file the package holds.
- **The landing order:**
  1. A binary with agent-stacks ADR 0083 is pinned here. It knows both
     `--pkgs-dir` and `--out`.
  2. This change lands.
  3. A binary with agent-stacks ADR 0086 is pinned. Each replay with
     it moves its packages: `default.json` added, `source.json`
     removed, and the head line changed. That is one cause across
     those diffs.

  Landing this before step 1 breaks every replay, because an older
  binary has no `--pkgs-dir`. Landing it after step 3 breaks the
  replay that brings the new binary in, because that binary has no
  `--out`.

  Every push to agent-stacks-cli's main dispatches
  `update-agent-stacks`, which pins that build, so merging there is
  releasing. `update-agent-stacks` stays paused from ADR 0026's
  landing until this change lands; agent-stacks ADR 0086 spells out
  the sequence.

## Consequences

- `+` No reader breaks across the move, in either direction, so the
  migration needs no commit by hand.
- `+` Every package moves for the same cause, so the diffs need no
  reading beyond that.
- `-` For one release, the readers handle two names.
  A later change can drop the `source.json` fallback once no package
  holds one.
- `-` This must land between two releases of agent-stacks, not at any
  time.
