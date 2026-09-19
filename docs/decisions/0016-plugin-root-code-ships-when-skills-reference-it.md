# 0016. Plugin-root code ships when skills reference it

Date: 2026-09-19

Status: Accepted

## Context

`buildAgentPlugin` assembles a plugin from its skill directories.
Nothing else in the source tree reaches the output, which was the
whole intent: a package carries what was selected and checked, not
whatever a repository happens to hold.

A skill reaches the rest of its plugin through `${PLUGIN_ROOT}`, which
Claude spells `${CLAUDE_PLUGIN_ROOT}`. Some plugins put their
executable code there rather than inside a skill.
`AgriciDaniel/claude-seo` is the case that surfaced this: 31 skills,
133 references to `${CLAUDE_PLUGIN_ROOT}/scripts/claude-seo`, and a
built package holding `plugin.json` and `skills/` and nothing else.
The build passed. `check-plugin` passed. 22 of the 31 skills were
inert, and nothing said so.

Upstream's launcher explains its own location: hosted marketplaces
reject a plugin that ships a top-level `bin/`, so the code went to
`scripts/`. That is a marketplace constraint, not a statement about
what the code is. ADR 0011 already settled that scripts shipped with a
plugin are packaged; the only thing different here is which directory
they sit in.

Three positions were available. Ship nothing and record the gap, which
leaves a package that builds cleanly and does not work. Ship the whole
plugin root, which drags in tests, screenshots and docs, and makes the
output a function of the repository rather than of what was selected.
Or ship what the skills actually name.

## Decision

We will ship the plugin-root entries a plugin's skills reference, and
only those.

Import reads `${PLUGIN_ROOT}` and `${CLAUDE_PLUGIN_ROOT}` references
out of the selected skills, resolves each against the plugin's own
directory, and records the plugin-root entry it names in
`pluginRootPaths` — destination inside the plugin tree to path inside
the source. `assemble-plugin` copies exactly those, before the runtime
pass, so what they hold is scanned, rewritten, pinned and guarded like
a skill's own files. A directory is copied whole, because a launcher's
siblings are what it loads at run time.

Three things this does not do. It ships no entry that no skill names.
It never ships `skills/` or `bin/`, which assembly writes itself and
which a copy would overwrite. And a reference the source does not hold
is recorded as a warning rather than shipped, since it resolves to
nothing wherever the plugin is installed.

`agents/` and `hooks/` are plugin components rather than skill code,
and stay outside this: a plugin that ships them is AI-728's question,
not this one.

The field is absent when the skills reference nothing outside
themselves, which is nearly every plugin, so their packages are
unchanged.

## Consequences

- `+` A plugin whose executable code sits at its root packages
  correctly instead of shipping skills that call a launcher that is
  not there.
- `+` What ships stays derived from what was selected and checked. The
  set is computed from references, not from the repository's shape, so
  it cannot quietly grow.
- `+` Shipped plugin-root files go through the same runtime pass as
  skill files, so their interpreters are pinned and recorded in
  `requiredRuntimes` rather than resolving off the consumer's PATH.
- `+` The reference itself becomes the record: a `${PLUGIN_ROOT}` path
  that exists nowhere in the source is now reported at import instead
  of being discovered at run time.
- `-` Packaging a plugin now depends on parsing its prose. A reference
  built by string concatenation, or written in a form the pattern does
  not match, ships nothing and warns about nothing.
- `-` A referenced directory is copied whole, so a plugin that keeps
  something large beside its launcher carries it. Prune rules do not
  apply here the way they do inside a skill.
- `-` Shipping the code does not resolve what the code imports.
  claude-seo's `requirements.txt` is still AI-565, and its launcher
  picks a python off PATH rather than the one the build pins, so the
  package becomes coherent rather than self-contained.
