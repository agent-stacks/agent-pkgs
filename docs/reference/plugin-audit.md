# Plugin audits: `audit.json`

Every plugin package under `pkgs/` may carry an `audit.json` beside
its `default.nix` and `source.json`. It is the latest security audit
of the built package by `agent-stacks audit`, which is a scan by
NVIDIA SkillSpector. Why it is kept here is
[ADR 0021](../decisions/0021-plugins-are-audited-in-ci-and-the-result-is-kept-beside-the-package.md).

## What it holds

When the plugin was audited, the file is the `agent-stacks audit
--json` document, as printed: the score (0 to 100, higher is
better), the status, each component's findings, and the `tool`
block naming the SkillSpector version. Its fields are documented in
the agent-stacks repo, `docs/reference/audit-command.md`. The
`target` is always `./result`.

When the plugin could not be audited (the CLI exited 3, for example
`nothing to audit`), the file says so instead:

```json
{
  "target": "./result",
  "audited": false,
  "score": null,
  "status": "could not audit",
  "reason": "nothing to audit",
  "hints": [],
  "tool": { "name": "skillspector", "version": "2.12.0" }
}
```

`reason` and `hints` are the CLI's error line and the lines indented
under it. A package with no `audit.json` has not been audited yet.

## When it is refreshed

`.github/workflows/audit-plugins.yml` writes it:

| Trigger | Packages audited |
| ------- | ---------------- |
| Push to main changing `pkgs/agent-plugin-*/source.json` | The packages whose `source.json` changed |
| Push to main changing `pkgs/skillspector/` or the `skillspector-src` input | Every package |
| Nightly | Every package |
| Manual dispatch | The named package, or every package |

Each package is built and audited with the pinned `agent-stacks`
package, which carries this set's `skillspector`. The new document
is compared with the committed one without `tool.osv.checkedAt` and
`plugins[].dir`, which change on every run. The file is rewritten
only when anything else differs, and a run's changes land as one
commit, `chore(audit): record plugin audits`.

A package that does not build keeps its previous `audit.json`. An
audit that fails for a reason that is not the plugin's (osv.dev
unreachable, SkillSpector missing, the CLI misbehaving) writes
nothing and fails the run. While the pinned `agent-stacks` predates
the SkillSpector audit, every run skips with a notice.

The workflow runs `scripts/record-plugin-audit.sh` once per package.
The same command works locally:

```sh
nix build .#agent-plugin-<name>
scripts/record-plugin-audit.sh agent-plugin-<name> ./result
```

It needs `agent-stacks` with `skillspector` on its PATH (`nix run
.#agent-stacks` provides both; `AGENT_STACKS_BIN` names another) and
network access to `api.osv.dev`.

## What it is not

The build never reads it: a package's `default.nix` reads only
`source.json`, so writing `audit.json` rebuilds nothing. The hourly
replay of each package's import leaves it alone. It gates nothing: a
low score does not stop a package from building or being published.
It is a record for readers, of what the scanner found at the last
run.
