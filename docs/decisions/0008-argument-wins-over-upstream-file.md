# 0008. The manifest and mcpServers arguments win; an upstream file fills the gap

Date: 2026-09-11

Status: Accepted

Supersedes [0003](0003-upstream-manifest-wins.md).

## Context

ADR 0003 made an upstream `plugin.json` in the src root win over the
`manifest` argument, with both given a build error, and gave
`mcpServers` and an upstream `mcp.json` the same rule. The reasoning
was that upstream authorship is respected and the ambiguous case
fails loudly.

The rule assumes the upstream file is an Agent Plugins file. In the
sources `flox-agent import` meets it is not: `mcp.json` files are
Claude's, with no `$schema` and a transport the schema spells
differently, and a root `plugin.json` is as often a Cursor or VS Code
manifest as ours. The importer already validates the plugin tree
before it writes a package, and knows which fields are conformant; the
builder, copying the upstream file first, discarded that judgement and
refused the corrected one beside it. Five repositories on the
skills.sh leaderboard failed to import for exactly this.

## Decision

We will use the `manifest` argument whenever it is given, and an
upstream `plugin.json` in the src root only when it is not. Passing
both is no longer an error: the argument is what the caller checked,
and it replaces the file. `mcpServers` and an upstream `mcp.json`
follow the same rule.

A src that ships neither file and gets no argument still fails: a
plugin needs a manifest.

`flox-agent import` always passes `manifest`, and passes `mcpServers`
whenever the plugin has servers (flox-agent ADR 0017), so a generated
package never depends on what its src root holds. Hand-written callers
may still omit both and let the upstream files through.

## Consequences

- `+` The importer's validated manifest and servers are what get
  built, and a foreign or non-conformant upstream file cannot displace
  them.
- `+` A subdirectory plugin's `mcp.json` can be carried, as
  `mcpServers`, where before it was refused.
- `-` An upstream author's `plugin.json` is no longer authoritative
  for a generated package; a generated manifest that drops a field is
  what ships. The importer reports every dropped field on stderr.
- `-` A hand-written call that passes `manifest` beside a src with a
  conformant `plugin.json` silently overrides the file where it used
  to fail. The override is what the caller asked for.
