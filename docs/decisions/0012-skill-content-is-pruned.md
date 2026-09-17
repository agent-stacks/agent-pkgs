# 0012. Skill content is pruned by a fixed list

Date: 2026-09-15

Status: Accepted

## Context

A root-skill package (`"skills": {"x": "."}`) copies the whole
checkout into the skill directory, because the skill root and the
repository root are the same path. Everything else a maintainer
checked in for the repository's own sake — CI workflows, a test
suite, dotfiles, a dependency cache — lands inside the skill
directory alongside `SKILL.md` and its references.

An agent that reads a skill directory does not distinguish "this file
is instructions" from "this file happened to be here." The stack
audit runner scores whatever text is under the skill root as skill
content, so a CI workflow or a test fixture is weighed the same as a
reference document the skill author actually wrote for the agent to
read.

Three imports made the shape of the problem concrete (AI-713):
`temporalio/skill-temporal-developer` shipped
`.github/workflows/package-skill.yml` and `.github/CODEOWNERS` inside
its skill tree; `browser-use/video-use` shipped a 512 KiB banner
image, `poster.html`, a `tests/` directory, `.gitignore`,
`.env.example`, and `pyproject.toml`; `mvanhorn/last30days-skill`
shipped every one of its own development scripts, which its own
`.skillignore` lists rather than relying on any default to catch.

## Decision

**A fixed list is pruned from every skill, unconditionally:** `.git*`,
`.github`, `tests`, `.env*`, `node_modules`. The list is matched
against every path component, so `tests/` is excluded whether it sits
at the skill root or nested under `scripts/`.

**A `.skillignore` at the skill root adds entries to this list and can
never remove one from it.** There is no negation syntax and no way to
un-prune `.github` for a repository that wants to ship it as skill
content. The fixed list is the floor, not a default a maintainer can
opt out of.

This rule is implemented once, in agent-stacks
(`internal/plugin/assemble`), and shared between `import`'s runtime
scan and `assemble-plugin`'s copy — see agent-stacks ADR 0025. Nothing
in this repository re-implements or overrides it; a package here
either accepts what the pruner keeps or is not packaged.

## Consequences

- `+` A generated plugin cannot ship its upstream's CI configuration,
  dotfiles, or dependency tree as skill content, without a maintainer
  having to notice and exclude it by hand for each import.
- `+` The three AI-713 packages import clean without a per-package
  exception file living in this repository.
- `+` One rule, tested once, applies to every package; there is no
  per-skill prune list to keep in sync as imports are re-run.
- `-` A skill that legitimately ships a directory named `tests` — as
  reference material, not as its own test suite — loses it, with no
  per-file way to keep it. The remedy is a package-level decision (an
  `extraSubstitutions`-style escape hatch has not been built for this,
  deliberately: the fixed list is meant to be non-negotiable), not a
  per-file exception threaded through `.skillignore`.
- `-` A repository whose real skill content happens to collide with a
  pruned name (a skill about writing `.github` workflows, say) cannot
  be packaged as a root skill without losing part of itself.
