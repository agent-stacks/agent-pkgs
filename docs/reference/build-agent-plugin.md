# `buildAgentPlugin`

Builds one Agent Plugin into
`$out/share/agent-plugins/<name>/`. The call shape for generated
packages is defined by the
[import→builder contract](import-contract.md); this page documents
every argument.

## Arguments

| Argument | Default | What it does |
| -------------------- | ------- | ------------ |
| `name` | required | Plugin name; also the package name and the output directory name. `check-plugin` requires it to match the manifest's `name`. |
| `version` | `"0"` | Derivation version. |
| `src` | required | Source tree (fetcher output or local path). |
| `sourceUrl` | `null` | Upstream URL recorded in `passthru.agentPlugin`. |
| `manifest` | `null` | Attrset serialized to `plugin.json` when the src ships none. Passing both is a build error. |
| `skills` | `null` | Skill name → path in src. When null, the builder falls back to `skills-lock.json`, then to a passthrough tree. |
| `mcpServers` | `null` | Attrset serialized to `mcp.json` when the src ships none; same both-is-an-error rule. The generated file declares the same spec version as `manifest`, defaulting to 1.0.0 when there is no manifest. |
| `floxAgent` | `null` | When set, the install check runs `flox-agent check-plugin --strict` on the output. What that validates is documented in the flox-agent repo, `docs/reference/check-plugin-command.md`. |
| `runtimes` | `{ }` | Interpreter name → package. Overrides `mappings/runtimes.nix` and pins versions, e.g. `{ python3 = python312; }`. |
| `allowPathCommands` | `[ ]` | Bare `mcp.json` commands that intentionally resolve from the consumer environment's PATH instead of the closure. |
| `extraSubstitutions` | `[ ]` | List of `{ file; replace; with; }` applied after the automatic pass, for interpreter mentions in script bodies or SKILL.md text. |
| `allowEnvShebangs` | `[ ]` | Executables (paths relative to the plugin root) allowed to keep a `/usr/bin/env` shebang. |
| `meta` | `{ }` | Standard derivation meta. Absent `license` means no assertion (ADR 0003 context). |

## The runtime substitution pass

After the tree is assembled the builder:

1. Detects interpreter names in shebangs (outside `assets/`) and in
   bare `mcp.json` commands.
2. Resolves each through the `runtimes` argument, then
   `mappings/runtimes.nix`. An unmapped name fails the build and
   names the file that wanted it.
3. Symlinks each resolved interpreter into the plugin's `bin/` and
   rewrites the references to point there. The symlink targets are
   store paths, so the interpreters land in the plugin's closure.

After the pass and the `postAssemble` hook, a guard fails the build
for any executable that still has a `/usr/bin/env` shebang, unless
listed in `allowEnvShebangs`. Design and trade-offs:
[ADR 0006](../decisions/0006-runtime-substitution.md).

## Passthru

```nix
passthru.agentPlugin = {
  name; path; sourceUrl; specVersion; skills;
};
```

## Extension point

`postAssemble` runs on the fully substituted tree before the guard,
install, and checks. Attach with `overrideAttrs`; the
`override-hook` flake check keeps this working.
