# 0021. Plugins are audited in CI and the result is kept beside the package

Date: 2026-10-16

Status: Proposed

## Context

A stack built with `mkAgentStack` had an `audit` output, a script
named `<name>-audit` that ran `agent-stacks audit` on each plugin in
the stack. Three things were wrong with it:

- It duplicated the CLI. Since agent-stacks-cli #187,
  `agent-stacks audit ./result` audits every plugin under a built
  stack's `share/agent-plugins/`, which is all the script did.
- It ran on the user's machine, after they had chosen the plugins.
  Every user auditing the same plugin repeated the same scan.
- It threw the result away. Nothing recorded what a plugin scored, so
  nobody could see it before building a stack, and nothing showed a
  score moving when a plugin or SkillSpector changed.

`agent-stacks audit` is a security audit by NVIDIA SkillSpector
(agent-stacks-cli #186). Its `--json` document carries the score,
every finding and the tool block (SkillSpector's version, the mode,
when osv.dev answered) that makes two results comparable. The score
of an unchanged plugin still moves when SkillSpector changes, or when
the CVE data it checks against does.

Every plugin package here reads only its `source.json`
(`builtins.fromJSON (builtins.readFile ./source.json)`), so another
file in its directory changes no derivation. The hourly replay
(`update-agent-plugins.yml`) runs `agent-stacks import --replay`,
which writes `default.nix` and `source.json` and leaves every other
file in the directory alone.

## Decision

We will remove the stack audit: the `audit` output, the script, the
`audit` option, and `mappings/audit-tools.nix`. A call passing
`audit` fails evaluation with a message naming the removal. A built
stack is audited with `agent-stacks audit ./result`.

We will audit every plugin package in CI, in
`.github/workflows/audit-plugins.yml`, and commit the result beside
it as `pkgs/agent-plugin-<name>/audit.json`:

- on a push to main, the packages whose `source.json` changed, or
  every package when SkillSpector changed;
- nightly, every package, because the CVE data moves on its own;
- on dispatch, one package or all of them.

Each package is built, and the repository's pinned `agent-stacks`
(wrapped with this set's `skillspector`, ADR 0020) audits it. A
score, good or bad, is written as the CLI printed it. A plugin that
cannot be audited gets a small record saying so, with the reason and
the SkillSpector version. Neither fails the run. Only a fault that is
not the plugin's does: the runner, nix, osv.dev being unreachable,
the CLI misbehaving.

A new result is compared with the committed one without the fields
that change on every run (`tool.osv.checkedAt`, and `plugins[].dir`,
the store path). The file is written only when something else
differs, so a nightly run that finds nothing new commits nothing. A
run's changes land as one commit, pushed to main by the same app as
the other bot workflows.

The record is informational. Nothing reads it to decide whether a
package builds, is published, or is offered.

## Consequences

- `+` Every plugin's score is visible in the repository, before
  anyone builds a stack, and `git log` on an `audit.json` shows how
  it moved and why.
- `+` One audit per plugin per change, not one per user per stack.
- `+` No rebuilds: no derivation reads `audit.json`.
- `+` A stack is simpler, with one output and nothing on its PATH it
  does not launch with.
- `-` main gets commits from a bot for every run that changed a
  score, nightly ones included.
- `-` A result is only as fresh as the last run. Between nightly runs
  a new CVE is not reflected.
- `-` There is no gate yet: a plugin scoring "do not install" is
  still built and published. Gating on the score is a separate
  decision.
- `-` The workflow needs the pinned `agent-stacks` to carry #186.
  Until the pin moves past it, every run skips with a notice and
  records nothing.
- `-` A user who relied on `nix build .#<stack>^audit` has to switch
  to `agent-stacks audit ./result`, and learns so from an evaluation
  error.
