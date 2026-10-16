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
| Push to main changing `pkgs/skillspector/`, the `skillspector-src` input or `pkgs/agent-stacks/source.json` | Every package |
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

It prints `agent-plugin-humanizer: new|changed|unchanged (<score>)`.
The pinned CLI has to carry agent-stacks-cli #186. With an older
one the script finds no readable result, exits 2 and writes nothing.

## What it is not

The build never reads it: a package's `default.nix` reads only
`source.json`, so writing `audit.json` rebuilds nothing. The hourly
replay of each package's import leaves it alone. It gates nothing: a
low score does not stop a package from building or being published.
It is a record for readers, of what the scanner found at the last
run.
