# 0011. A skill and the tool it drives are separate packages

Date: 2026-09-15

Status: Accepted

## Context

A common upstream shape is a CLI that ships skills teaching an agent to
drive it. `vercel-labs/agent-browser` is one: nine of its ten skills
declare `allowed-tools: Bash(agent-browser:*)`. `supabase/agent-skills`
is another, whose skill bodies are instructions for the Supabase CLI,
with version floors stated in prose. `vercel-labs/skills` is the
skills.sh CLI itself, of which we package one `SKILL.md` and none of
the binary.

Packaging the skills and dropping the tool leaves the agent instructed
to run a binary that may not be there.

Carrying the tool inside the plugin is not available to us. Agent
Plugins rule 3 requires every path a client reads or executes to
resolve inside the plugin root, and a symlink from the plugin's `bin/`
into another store path resolves outside it. Copying the tool in
instead would discard sharing and closure semantics.

Nothing in `buildAgentPlugin` expresses "this plugin needs tool X".
`runtimes` is interpreters only; `allowPathCommands` says the opposite,
that a command is expected from the consumer's PATH.

An AI pod call on 2026-09-08 sketched a fuller answer: the plugin
declares the binaries it needs, in an agent-stacks extension field, and
a client offers to install what is missing. That mechanism is not
built, and on 2026-09-15 it was deferred rather than scheduled.

## Decision

**A skill and the tool it drives are two packages.** The skills are
packaged by `buildAgentPlugin`; the tool, when we package it at all, is
its own package. Neither carries the other, and neither pins the
other's version. A consumer installs both into one environment.

**Scripts that ship inside a skill are unaffected.** They are packaged
as they always were: shebang rewritten, interpreter pinned, carried in
the closure (ADR 0006). The distinction is ownership — a script in the
skill's own tree is part of the skill; a third-party CLI the skill
talks to is not.

**No declaration mechanism, for now.** `buildAgentPlugin` gains no
required-tools field, `mkAgentStack` gains no way to satisfy one, and
nothing prompts for a missing binary. When that is built, it belongs in
the agent-stacks specification rather than here, under a reverse-domain
key in `extensions` as Agent Plugins §5 requires.

Version pinning of the tool is refused on its own merits, not merely
deferred. A skill that silently used a different `flox` — or `gh`, or
`supabase` — than the one on the user's PATH would surprise the user
in a way the reproducibility argument does not justify.

## Consequences

- `+` Nothing has to be built to adopt this: it is what the packages
  already do, now written down as a choice rather than a gap.
- `+` The tool the agent runs is the tool the user has, at the version
  they chose, so a skill does not fork the user's toolchain.
- `+` No new field, no sidecar file, and no hand-authored data for
  `import` to preserve across a re-run.
- `-` A plugin can be installed without the tool its skills drive, and
  nothing warns. The agent fails at the point of use, with whatever
  error the missing binary produces.
- `-` `supabase/agent-skills` documents version floors (`db query`
  needs 2.79.0+, `db advisors` 2.81.3+) that stay prose and are
  enforced by nothing.
- `-` `flox/floxenvs` answers the same question differently for
  `agent-browser`, copying the skills into `share/agent-browser/` for
  the tool's own discovery. Until those packages are retired (AI-681),
  one upstream has two packaging shapes in two repositories.
