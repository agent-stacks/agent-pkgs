# 0004. Skill selection: explicit args, then lock file, then passthrough

Date: 2026-08-28

Status: Accepted

## Context

Skills can be named three ways: the generated `skills` mapping that
`agent-stacks import` emits, a `skills-lock.json` project lock (written
by the upstream skills CLI) checked into the source repo, and a src
tree that already is a conformant plugin. A lock file may reference
skills that live in other repos — but `buildAgentPlugin` is pure and
cannot fetch at build time.

## Decision

We will select skills in this precedence order:

1. The explicit `skills` argument (name → path inside src).
2. A `skills-lock.json` at the src root, parsed at build time with
   jq; each entry is copied from its in-tree `skillPath`.
3. Passthrough of an already-conformant tree.

A lock entry whose files are not inside src fails the build with a
pointer to `agent-stacks import`, which resolves external sources into
pinned fetchers and an explicit `skills` mapping.

## Consequences

- `+` Repos with a checked-in lock build directly, no generation step.
- `+` Purity is preserved; external sources go through import, where
  pinning belongs.
- `-` The builder embeds knowledge of the lock format (version 1);
  format bumps upstream require a builder update.
