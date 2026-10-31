# 0028. The audit leaves out what a reviewed baseline lists

Date: 2026-10-31

Status: Proposed

Relates to [0022](0022-plugins-are-audited-in-ci-and-the-result-is-kept-beside-the-package.md):
plugins are still audited in CI and the record still sits beside the
package.

## Context

The 426 audits recorded on 2026-10-30 hold 35,338 findings, and 178
plugins are marked `do not install`. Read against the upstream
lines, most of the volume is SkillSpector matching ordinary text:

| Rule | Findings | What it matched |
| ---- | -------- | --------------- |
| AE1, HIGH | 2,854 in 170 plugins | One per `reference_missing` exception (25,412 of them). In a sample of 200: about 14% version strings and dotted ids, 8% example and runtime paths, 16% sibling skills named as `doca-setup/SKILL.md`, and most of the rest other path-like text, `.j2`, `model.name`, `src/chat.py:42` |
| P9 | 4,058, 4,027 in Markdown | Aligned table columns (`U+0020 x83`) |
| LP3 | 1,149 | Line 1 of a `SKILL.md` with no `allowed-tools` |

AE1 alone moves a score a long way: on launchdarkly, recording with
it left out takes the plugin from 15 (`do not install`) to 50
(`caution`), with 30 findings set aside.

agent-stacks-cli #212 adds `audit --baseline FILE`. It hands the file
to SkillSpector, whose own baseline format drops matched findings
before scoring; the CLI keeps each one under the component's
`suppressed`, with the baseline's reason, and names the file by the
SHA-256 of its content. The CLI ships no baseline: what counts as
noise is the auditor's call. The same change scans a plugin's hooks,
agents, commands and scripts, which adds findings with the same
false positives.

## Decision

We will keep one baseline, `scripts/audit-baseline.yaml`, and record
every audit with it.

- It holds only rules that, across the recorded audits, match
  ordinary text far more often than risk, each with its reason: AE1
  everywhere, P9 in Markdown, LP3 in `SKILL.md`.
- `scripts/record-plugin-audit.sh` passes it as `--baseline` when
  the pinned CLI's `audit --help` lists the flag, as it already does
  for `--scan-timeout`. `AUDIT_BASELINE` names another file, or none.
- A change to it re-audits every package, as a change to SkillSpector
  or the pinned agent-stacks does.
- The dashboard shows what it left out under each component, closed,
  with the reason, and counts it apart from the scored findings.

A finding accepted in one plugin is not added: SkillSpector matches a
rule's `path` inside each component, so a rule cannot name one skill.

## Consequences

- `+` Scores stop following rules that match text: launchdarkly goes
  from `do not install` to `caution` on the findings that remain.
- `+` Nothing is hidden. Every finding set aside is in `audit.json`
  with the reason, and `git log` on the baseline says who set a rule
  aside and why.
- `+` Hooks, agents and scripts can be scanned (agent-stacks-cli
  #212) without the dashboard filling up with the same noise.
- `-` A rule left out everywhere is left out where it would have been
  right: a real broken reference no longer weighs on a score. Its
  `reference_missing` exception is still listed.
- `-` Until the pinned agent-stacks carries #212, the file is read by
  nothing and scores are unchanged.
- `-` Changing the baseline re-audits every package, a full run.
