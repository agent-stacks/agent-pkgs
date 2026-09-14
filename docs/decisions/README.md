# Decision records

Significant, hard-to-reverse choices for `agent-pkgs`, recorded so
the reasoning survives the people who made it. One decision per file,
numbered in order. A record is immutable once accepted: to change a
decision, add a new record that supersedes the old one.

Format and process live in [template.md](template.md).

## Decisions that live in flox-agent

The tool owns what a plugin is called and what a valid one looks like,
so those records are in that repository rather than restated here. The
ones this package set is built on:

| # | Decision |
| ---- | -------- |
| flox-agent 0014 | How import finds plugins, and how it finds their skills — a name comes from the manifest that defined the plugin, with `<owner>-<repo>` synthesized only when there is no manifest |
| flox-agent 0019 | A plugin's directory must be named after its manifest, and nothing renames it |
| flox-agent 0017 | A package directory belongs to one upstream, and `--name` is the way out |
| flox-agent 0018 | Import hands the builder the manifest and servers it checked |

These records cover the Nix side only: the builders, the package set,
and the contract this repo meets flox-agent at. Decisions about
`flox-agent import`, `check-plugin` or `launch` are recorded in the
flox-agent repo, under `docs/decisions/`. A record here that depends
on one of those links to it rather than restating it.

| # | Decision |
| ---- | -------- |
| [0001](0001-flake-only-entry-point.md) | Flake-only entry point |
| [0002](0002-optional-check-phase.md) | Optional check phase until the -bin package exists |
| [0003](0003-upstream-manifest-wins.md) | Upstream plugin.json wins; manifest argument fills the gap (superseded by 0009) |
| [0004](0004-skill-selection-precedence.md) | Skill selection: explicit args, then lock file, then passthrough |
| [0005](0005-canonical-output-layout.md) | Canonical output under share/agent-plugins/ |
| [0006](0006-runtime-substitution.md) | Runtime substitution: plugin-local bin/, deterministic scope |
| [0007](0007-one-harness-per-stack.md) | One harness per stack, detected from the binary |
| [0008](0008-re-export-llm-agents-nix.md) | Re-export llm-agents.nix into the package set |
| [0009](0009-assembled-package-from-arguments.md) | An assembled package is built from its arguments |
