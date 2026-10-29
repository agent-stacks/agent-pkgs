# 0027. A plugin import cannot read is written by hand

Date: 2026-10-28

Status: Proposed

## Context

`Graphify-Labs/graphify` ships its Claude Code skill as
`graphify/skill.md`, package data that `graphify install` copies to
`~/.claude/skills/graphify/SKILL.md` with the claude bundle's
`references/` beside it. Nothing in the repository is named `SKILL.md`,
so `agent-stacks import` finds no skill and writes nothing (agent-stacks
ADR 0027). floxenvs packages it by hand as `skills-graphify`, and that
package is what keeps graphify-demo on `flox/flox-ai` (AI-1055).

Every other plugin here is generated, and the contributing guide says
to leave out a package whose import fails and report it upstream.
Changing import is out: agent-stacks ADR 0027 refuses a skill file not
named `SKILL.md`, and on 2026-10-28 the team decided that packaging
import cannot express lives in this repository, not in the CLI (AI-924).
That logic goes in a generated package's custom block, as ADR 0025's
does, and here there is no generated package to hold one.
Asking upstream to rename the file was considered and not taken: the fix
would wait on another project, and its own installer already produces a
valid skill from the file it ships.

`buildAgentPlugin` takes a hand-written call: a `src` derivation, an
explicit `skills` map and a `manifest`. The import contract describes
one.

## Decision

We will write `pkgs/agent-plugin-graphify-labs-graphify` by hand. It
fetches a release tag and lays the skill out as `graphify install` does,
`skill.md` as `SKILL.md` with `references/` beside it, then calls
`buildAgentPlugin`. It is named as import names a repository nothing
names, `<owner>-<repo>`, versioned by the release, and declares no
runtimes, as the skill ships no scripts.

The exception is for an upstream whose own installer turns what it
ships into a valid skill, so the package repeats that installer's steps
and guesses at nothing. An import that fails for any other reason is
still left out and reported. When import can read graphify, the package
is regenerated and this file goes.

The audit workflow keys an audit on a hash of `default.nix` and
`source.json`, and audits a pushed package only when its `source.json`
changed. We will hash `source.json` only when it exists, and audit a
push that changes the `default.nix` of a package with no `source.json`,
so this package is audited when it is bumped and the nightly run does
not fail on it. A generated `default.nix` changing alone is left to the
nightly run, as before: an importer template change rewrites most of
them at once, right after a pin bump that already audits everything.

## Consequences

- `+` graphify-demo can move to this package and drop `flox/flox-ai`
  without waiting on upstream.
- `+` The skill is byte for byte what `graphify install` writes for
  Claude Code, and the build's `check-plugin` validates it.
- `-` The hourly replay reads only `source.json`, so it never moves this
  package. A new release is a hand edit of `version` and `hash`.
- `-` A package nothing regenerates can drift from upstream's layout
  unnoticed until the build fails.
- `-` The audit dashboard reads provenance from `source.json`, so this
  package's row has no version or upstream links.
- `-` One package is not generated, against the contributing guide's
  rule. A second would argue for teaching import, not for more of these;
  the end-of-year packaging review is where that is decided.
