# Decision records

Significant, hard-to-reverse choices for `agent-pkgs`, recorded so
the reasoning survives the people who made it. One decision per file,
numbered in order. A record is immutable once accepted: to change a
decision, add a new record that supersedes the old one.

Format and process live in [template.md](template.md).

## Decisions that live in agent-stacks

The tool owns what a plugin is called and what a valid one looks like,
so those records are in that repository rather than restated here. The
ones this package set is built on:

| # | Decision |
| ---- | -------- |
| agent-stacks 0021 | How import finds plugins and their skills; a root `SKILL.md` is one skill among those below it, and the builder copies it without them |
| agent-stacks 0019 | A plugin's directory must be named after its manifest, and nothing renames it |
| agent-stacks 0017 | A package directory belongs to one upstream, and `--name` is the way out |
| agent-stacks 0018 | Import hands the builder the manifest and servers it checked |
| agent-stacks 0020 | The CLI is the commercial surface; the ecosystem stays open — why the tool is unfree while this set is not |

These records cover the Nix side only: the builders, the package set,
and the contract this repo meets agent-stacks at. Decisions about
`agent-stacks import`, `check-plugin` or `launch` are recorded in the
agent-stacks repo, under `docs/decisions/`. A record here that depends
on one of those links to it rather than restating it.

| # | Decision |
| ---- | -------- |
| [0001](0001-flake-only-entry-point.md) | Flake-only entry point |
| [0002](0002-optional-check-phase.md) | Optional check phase until the -bin package exists (its `floxAgent ? null` default overturned by 0013) |
| [0003](0003-upstream-manifest-wins.md) | Upstream plugin.json wins; manifest argument fills the gap (superseded by 0009) |
| [0004](0004-skill-selection-precedence.md) | Skill selection: explicit args, then lock file, then passthrough |
| [0005](0005-canonical-output-layout.md) | Canonical output under share/agent-plugins/ |
| [0006](0006-runtime-substitution.md) | Runtime substitution: plugin-local bin/, deterministic scope |
| [0007](0007-one-harness-per-stack.md) | One harness per stack, detected from the binary |
| [0008](0008-re-export-llm-agents-nix.md) | Re-export llm-agents.nix into the package set |
| [0009](0009-assembled-package-from-arguments.md) | An assembled package is built from its arguments |
| [0010](0010-stack-launcher-reuses-flox-agent-launch.md) | A stack's launcher execs `agent-stacks launch` |
| [0011](0011-skill-and-tool-are-separate-packages.md) | A skill and the tool it drives are separate packages |
| [0012](0012-skill-content-is-pruned.md) | Skill content is pruned by a fixed list |
| [0013](0013-assembly-lives-in-flox-agent.md) | Assembly lives in agent-stacks |
| [0014](0014-generated-package-meta.md) | A generated package's meta asserts only what is known |
| [0015](0015-the-re-export-is-a-named-list.md) | What the re-export publishes is a named list, not a rule |
| [0016](0016-plugin-root-code-ships-when-skills-reference-it.md) | Plugin-root code ships when a plugin's skills reference it |
| [0017](0017-checks-live-where-the-behaviour-lives.md) | Checks live where the behaviour lives; this flake does not assert what the binary writes |
