# 0021. A stack has no audit output

Date: 2026-10-16

Status: Proposed

## Context

A stack built with `mkAgentStack` had a second output, `audit`,
holding `bin/<name>-audit`. The script ran `agent-stacks audit` on
each plugin under the stack's `share/agent-plugins/`, with the tools
in `audit.tools` (default: `mappings/audit-tools.nix`) on its PATH and
`--threshold` from `audit.threshold`.

`agent-stacks audit` is becoming a security audit by NVIDIA
SkillSpector of one plugin (agent-stacks-cli #186, open). A further
change (agent-stacks-cli #187, open) lets it take a directory holding
`share/agent-plugins/*`, such as a built stack's `./result`, and
audit every plugin there. With both, the script is the CLI run on
the stack's output, nothing more.

The script ran on the user's machine, once per user per stack, and
kept nothing of what it found. Auditing the plugins of this
repository once, centrally, and recording the result is proposed
separately, in ADR 0022.

## Decision

We will remove the stack audit: the `audit` output and its
`<name>-audit` script, the `audit` argument (`audit.tools`,
`audit.threshold`) and its validation, and `mappings/audit-tools.nix`
with the `defaultAuditTools` binding in `flake.nix`. A stack has one
output, `out`.

A call that still passes `audit` fails evaluation with a message
saying the argument was removed and how to audit a stack instead,
rather than with Nix's "called with unexpected argument". The
`stack-audit-removed` check asserts both the refusal and that a stack
has only `out`.

A built stack is audited with the CLI:
`agent-stacks audit ./result` once the agent-stacks in use carries
#187, and plugin by plugin,
`agent-stacks audit ./result/share/agent-plugins/<name>`, with one
carrying only #186.

## Consequences

- `+` A stack is one output with nothing on its PATH that it does not
  launch with, and `mkAgentStack` loses an option and its validation.
- `+` There is one way to audit a plugin, the CLI's, documented in
  one place, agent-stacks `docs/reference/audit-command.md`.
- `-` A caller passing `audit` breaks at evaluation and has to drop
  the argument. The message says why.
- `-` `nix build .#<stack>^audit` no longer exists, and a stack no
  longer carries its audit tools: the user needs `skillspector` on
  PATH to audit.
- `-` Until the pinned agent-stacks carries #187,
  `agent-stacks audit ./result` does not exist; audit a plugin with
  `agent-stacks audit ./result/share/agent-plugins/<name>` once the
  pin carries #186. Before #186 there is no SkillSpector audit to
  run at all.
