# 0008. An assembled package is built from its arguments

Date: 2026-09-11

Status: Accepted

Supersedes [0003](0003-upstream-manifest-wins.md).

## Context

ADR 0003 made an upstream `plugin.json` in the src root win over the
`manifest` argument and passing both a build error, and applied the
same rule to `mcpServers` and an upstream `mcp.json`. The reasoning
was that upstream authorship is respected and the ambiguous case
fails loudly.

The rule assumes the upstream file is an Agent Plugins file. In the
sources `flox-agent import` meets it usually is not: `mcp.json` files
are Claude's, with no `$schema` and a transport the schema spells
differently, and a root `plugin.json` is often a Cursor or VS Code
manifest. The importer validates the plugin tree before it writes a
package and knows which fields conform, but the builder copied the
upstream file and treated a `manifest` beside it as an error, so
import could not hand over what it had checked. Several leaderboard
repositories failed to import for exactly this; flox-agent's record
"Import hands the builder the manifest and servers it checked" names
them.

## Decision

An assembled package, one whose skills come from the `skills`
argument or a `skills-lock.json`, is built from its `manifest` and
`mcpServers` arguments. A passed-through tree keeps its own files; an
argument, if given, replaces the matching file. A `manifest` that
replaces the tree's `plugin.json` also rewrites the tree's `mcp.json`
to its spec version, so the pair a client checks still agrees.

Without an argument, an assembled package takes a src root file only
when it is an Agent Plugins file, one declaring an `agent-plugins.org`
`$schema`. Any other file at the root is another tool's and is not
read; an `mcp.json` skipped this way is reported at build time. This
stand-in is what a `source.json` from an importer that predates the
flox-agent record relies on: such a file omits `manifest` when the
plugin's own `plugin.json` sits at the root, and never carries
`mcpServers`. It is also what a repository building from a checked-in
`skills-lock.json` (the second case of ADR 0004) with its own
conformant `plugin.json` relies on.

An importer carrying that record always passes `manifest`, and passes
`mcpServers` whenever the plugin declares servers, so a package it
generates never depends on what its src root holds and the stand-in
is never consulted. Until the flox-agent pinned here carries it, a
regenerated package can still omit `manifest` and rely on the
stand-in.

## Consequences

- `+` The manifest and servers the importer validated are what get
  built; a foreign or non-conformant upstream file cannot displace
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
- `-` `mcpServers` without `manifest` writes an `mcp.json` at spec
  1.0.0 whatever the `plugin.json` beside it declares, whether a
  passed-through tree's own or a stand-in, since the version is read
  from the argument. Pass both, or neither.
- `-` The stand-in keeps one reading of the src root in the builder.
  It can go once every generated `source.json` carries `manifest`.
