# Plugin audits: `audit.json`

Every plugin package under `pkgs/` may carry an `audit.json` beside
its `default.nix` and `source.json`. It is the latest security audit
of the built package by `agent-stacks audit`, which is a scan by
NVIDIA SkillSpector. Why it is kept here is
[ADR 0022](../decisions/0022-plugins-are-audited-in-ci-and-the-result-is-kept-beside-the-package.md).

## What it holds

When the plugin was audited, the file is the `agent-stacks audit
--json` document, as printed: the score (0 to 100, higher is
better), the status, each component's findings, and the `tool`
block naming the SkillSpector version. Its fields are documented in
the agent-stacks repo, `docs/reference/audit-command.md`. The
`target` is always `./result`. One field is added: `agentStacks`,
`{ "version": … }`, what `agent-stacks --version` printed for the CLI
that audited.

A component is a skill, or, with a CLI that carries
agent-stacks-cli #212, anything else the plugin carries: an entry of
`com.anthropic.claude-code/` (hooks, agents, commands, workflows),
`scripts/`, upstream's own files in `bin/`. With such a CLI the score
also leaves out what [the baseline](#the-baseline) lists: each
component's `suppressed` holds those findings, with the baseline's
reason, and `tool.baseline.sha256` names the baseline by its content.

When the plugin could not be audited for a reason of its own (the
CLI exited 3 with `nothing to audit`, `not an agent plugin…` or
`cannot read the plugin: …`), the file says so instead:

```json
{
  "target": "./result",
  "audited": false,
  "score": null,
  "status": "could not audit",
  "reason": "nothing to audit",
  "hints": [],
  "tool": { "name": "skillspector", "version": "2.12.0" },
  "agentStacks": { "version": "1.0.0" }
}
```

`reason` and `hints` are the CLI's error line and the lines indented
under it. A package with no `audit.json` has not been audited yet.

## When it is refreshed

`.github/workflows/audit-plugins.yml` writes it:

| Trigger | Packages audited |
| ------- | ---------------- |
| Push to main changing `pkgs/agent-plugin-*/source.json` | The packages whose `source.json` changed |
| Push to main changing `pkgs/skillspector/`, the `skillspector-src` input, `pkgs/agent-stacks/source.json` or `scripts/audit-baseline.yaml` | Every package |
| Nightly | Every package |
| Manual dispatch | The named package, or every package |

Each package is built and audited with the pinned `agent-stacks`
package, which carries this set's `skillspector`. The new document
is compared with the committed one without `tool.osv.checkedAt` and
`plugins[].dir`, which change on every run. The file is rewritten
only when anything else differs, a new agent-stacks version
included, and a run's changes land as one commit,
`chore(audit): record plugin audits`.

A package that does not build keeps its previous `audit.json`. Any
other failure is taken as the run's, not the plugin's: osv.dev
unreachable, SkillSpector missing, a scan that failed or timed out,
an interrupted or unexpected exit. It writes nothing, keeps the last
good record, and fails the run. While the pinned `agent-stacks` predates
the SkillSpector audit, every run skips with a notice.

The workflow runs `scripts/record-plugin-audit.sh` once per package.
The same run, locally, from the repository root (`agent-stacks`
there is the pinned CLI with this set's `skillspector` on its PATH;
it needs network access to `api.osv.dev`):

```sh
AGENT_STACKS_BIN=$(nix build --no-link --print-out-paths .#agent-stacks)/bin/agent-stacks \
SKILLSPECTOR_BIN=$(nix build --no-link --print-out-paths .#skillspector)/bin/skillspector \
  scripts/record-plugin-audit.sh agent-plugin-humanizer \
    "$(nix build --no-link --print-out-paths .#agent-plugin-humanizer)"
```

Each component's scan is stopped after 20 minutes, which large
skills need on a CI runner (the CLI's own default is 5).
`AUDIT_SCAN_TIMEOUT` changes that, as a Go duration such as `30m`.
It is passed as `--scan-timeout` only when the pinned CLI lists that
flag in `audit --help` (agent-stacks-cli #192); an older pin keeps
its fixed 5 minutes.

The scores leave out what `scripts/audit-baseline.yaml` lists
(below). `AUDIT_BASELINE` names another file, or none when empty. It
is passed as `--baseline` only when the pinned CLI lists that flag
in `audit --help` (agent-stacks-cli #212); an older pin scores every
finding. A baseline named but missing stops the script, exit 2.

It prints `agent-plugin-humanizer: new|changed|unchanged (<score>)`.
The pinned CLI has to carry agent-stacks-cli #186. With an older
one the script finds no readable result, exits 2 and writes nothing.

## The baseline

`scripts/audit-baseline.yaml` lists the SkillSpector rules every
plugin's score leaves out
([ADR 0028](../decisions/0028-the-audit-leaves-out-what-a-reviewed-baseline-lists.md)).
It is SkillSpector's baseline format; each rule carries the reason
it is there. A matched finding is dropped before SkillSpector scores
the component, and kept in `audit.json` under `suppressed`, so
nothing it hides is lost.

| Rule | Left out | Why |
| ---- | -------- | --- |
| AE1 | everywhere | One per `reference_missing` exception: version strings, dotted ids, example paths, sibling skills. The exceptions stay listed. |
| P9 | in `*.md` | Aligned Markdown table columns. Code keeps the rule. |
| LP3 | in `*SKILL.md` | No `allowed-tools` declared, on nearly every upstream skill. |

A rule belongs here when, across the recorded audits, it matches
ordinary text far more often than risk. A finding accepted in one
plugin does not: SkillSpector matches a rule's `path` inside each
component, so a rule cannot name one skill. Changing the file
re-audits every package.

## Reading them: the dashboard

<https://agent-stacks.github.io/agent-pkgs/> shows every `audit.json`
on main in one page. Plugins are ranked by how affected they are
(lowest score, then most critical and most high findings), with
filters by status, rule and name. A plugin scores its worst
component; next to that status the list says how many components
share it ("2 of 57"), and a plugin's header counts its components by
status. A plugin opens to its components, worst first, with the
findings grouped by rule. Each finding links
to its file and line in the upstream repository, at the revision
that was audited: a skill at its path in `source.json`'s `skills`,
anything else at its path in `pluginRootPaths`. What the baseline
left out is under each component, closed, with the baseline's
reason, and counted apart from the scored findings. Each plugin has
its own address, `#agent-plugin-<name>`.

`audit-plugins.yml` publishes it to GitHub Pages in the same run that
records the audits: once `record` has pushed, `page` builds it from
the tip of main and `publish` deploys it. A push that changes only
the page (`scripts/audit-dashboard.py` or `.html`) audits nothing and
publishes. `scripts/audit-dashboard.py` builds it, with the data
embedded in the page, so the page makes no requests of its own. The same build, locally, from the repository root:

```sh
python3 scripts/audit-dashboard.py pkgs scripts/audit-dashboard.html \
  result.html --rev "$(git rev-parse HEAD)"
```

## What it is not

The build never reads it: a package's `default.nix` reads only
`source.json`, so writing `audit.json` rebuilds nothing. The hourly
replay of each package's import leaves it alone. It gates nothing: a
low score does not stop a package from building or being published.
It is a record for readers, of what the scanner found at the last
run.
