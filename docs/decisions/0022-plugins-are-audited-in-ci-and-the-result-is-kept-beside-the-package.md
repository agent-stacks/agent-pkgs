# 0022. Plugins are audited in CI and the result is kept beside the package

Date: 2026-10-16

Status: Proposed

## Context

A stack used to carry its own audit script, which ran on the user's
machine, once per user per stack, and kept nothing of what it found.
ADR 0021 (`0021-a-stack-has-no-audit-output.md`, proposed with the
stack-audit removal) removes it and leaves auditing to the CLI. That
leaves no record anywhere of what a plugin in this set scores: nobody
can see it before building a stack, and nothing shows a score moving
when a plugin or SkillSpector changes.

`agent-stacks audit` is becoming a security audit by NVIDIA
SkillSpector (agent-stacks-cli #186, open). Its `--json` document
carries the score, every finding and the tool block (SkillSpector's
version, the mode, when osv.dev answered) that makes two results
comparable. Taking a built package's `./result` as the target is a
further change (agent-stacks-cli #187, open). The score of an
unchanged plugin still moves when SkillSpector changes, when the CLI's
scoring changes, or when the CVE data it checks against does.

Every plugin package here reads only its `source.json`
(`builtins.fromJSON (builtins.readFile ./source.json)`), so another
file in its directory changes no derivation. The hourly replay
(`update-agent-plugins.yml`) runs `agent-stacks import --replay`,
which writes `default.nix` and `source.json` and leaves every other
file in the directory alone.

## Decision

We will audit every plugin package in CI, in
`.github/workflows/audit-plugins.yml`, and commit the result beside
it as `pkgs/agent-plugin-<name>/audit.json`:

- on a push to main, the packages whose `source.json` changed, or
  every package when SkillSpector or the pinned agent-stacks changed;
- nightly, every package, because the CVE data moves on its own;
- on dispatch, one package or all of them.

Each package is built, and the repository's pinned `agent-stacks`
(wrapped with this set's `skillspector`, ADR 0020) audits its plugin
directory, which needs only #186. A score, good or bad, is written as
the CLI printed it. A plugin that cannot be audited for a reason of
its own (nothing to audit, not an agent plugin, unreadable) gets a
small record saying so. Neither fails the run. Every other failure is
treated as the run's, not the plugin's: the runner, nix, osv.dev, a
scan that failed or timed out, anything unforeseen. It writes nothing,
keeps the last good record, and fails the run. Every record names the
agent-stacks version that produced it.

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
- `-` main gets commits from a bot for every run that changed a
  score, nightly ones included, and every package's file changes when
  the agent-stacks version does.
- `-` A result is only as fresh as the last run. Between nightly runs
  a new CVE is not reflected.
- `-` There is no gate yet: a plugin scoring "do not install" is
  still built and published. Gating on the score is a separate
  decision.
- `-` The workflow depends on agent-stacks-cli #186, which is open.
  Until the pinned agent-stacks carries it, every run skips with a
  notice and records nothing.
