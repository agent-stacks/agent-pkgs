# 0008. An assembled package is built from its arguments alone

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

We will build an assembled package, one whose skills the builder
selects from the `skills` argument or from a `skills-lock.json`, from
its `manifest` and `mcpServers` arguments. When the src is passed
through as a plugin tree, its own files are the source, and an
argument, if given, replaces its file; a manifest that replaces the
tree's `plugin.json` also brings the tree's `mcp.json` to its spec
version, so the pair a client checks still agrees.

Without an argument, an assembled package takes a src root file only
when it is an Agent Plugins file, one declaring an
`agent-plugins.org` `$schema`. Any other file at the root is another
tool's and is not read; an `mcp.json` skipped this way is reported at
build time. This is what a `source.json` written before the importer
carried `manifest` relies on, and what a repository with a checked-in
lock and its own conformant `plugin.json` relies on (ADR 0004); for
a package the current importer generates the stand-in is never
consulted.

`flox-agent import` always passes `manifest`, and passes `mcpServers`
whenever the plugin declares servers (the flox-agent record "Import
hands the builder the manifest and servers it checked"), so a
generated package never depends on what its src root holds, and the
tree the importer validated is the tree the builder produces.

## Consequences

- `+` The importer's validated manifest and servers are what get
  built, and a foreign or non-conformant upstream file cannot displace
  them.
- `+` A subdirectory plugin's `mcp.json` can be carried, as
  `mcpServers`, where before it was refused, and a root file that
  belongs to another plugin or another tool is never picked up.
- `-` An upstream author's `plugin.json` is no longer authoritative
  for a generated package; a generated manifest that drops a field is
  what ships. The importer reports every dropped field on stderr.
- `-` A passed-through tree given a `manifest` has its own file
  replaced where it used to fail. The replacement is what the caller
  asked for.
- `-` A passed-through tree given `mcpServers` but no `manifest`
  gets an `mcp.json` at spec 1.0.0 whatever its `plugin.json`
  declares, since the version is read from the argument. Pass both,
  or neither.
- `-` The stand-in rule keeps one reading of the src root in the
  builder. It can go once every generated `source.json` carries
  `manifest`.
