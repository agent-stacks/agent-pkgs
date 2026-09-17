# 0005. Canonical output under share/agent-plugins/

Date: 2026-08-28

Status: Accepted

## Context

Built plugins need one predictable location inside each package so
stacks can compose them and launchers can find them.
`share/agents/` was considered but is ambiguous with agent
*definition* fragments, and agent-stacks's existing
`share/flox/<agent>/` layout is a per-harness build-time detail, not
a packaging convention.

## Decision

We will install every plugin at
`$out/share/agent-plugins/<plugin-name>/`, named after the Agent
Plugins specification, one directory per plugin.

## Consequences

- `+` `mkAgentStack` composes by symlink-joining one well-known tree.
- `+` The name matches the spec; no collision with agent fragments.
- `-` Harness launchers must map from this neutral location to their
  native config layouts (agent-stacks launch's job).
