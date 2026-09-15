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
| `src` | required | Source tree (fetcher output or local path), or a `fetchFromGitHub` argument set — an attrset carrying `owner` and `repo` — which the builder fetches itself. A generated `source.json` always writes the pin form, since JSON cannot hold a derivation. |
| `sourceUrl` | `null` | Upstream URL recorded in `passthru.agentPlugin`. |
| `import` | `null` | The import that produced this package, when it was generated: `{ input, flags, warnings }`. Nothing in the build reads it; it exists so a generated `source.json` can be passed whole, and it reaches `passthru` so a reader can see what produced the package. |
| `manifest` | `null` | Attrset serialized to `plugin.json`, replacing a passed-through tree's own. Without it an assembled package takes a root `plugin.json` only when it declares an `agent-plugins.org` `$schema`, else fails (ADR 0009). |
| `skills` | `null` | Skill name → path in src. When null, the builder falls back to `skills-lock.json`, then to a passthrough tree. |
| `mcpServers` | `null` | Attrset serialized to `mcp.json` at the `manifest`'s spec version (1.0.0 without one). Without it, a passed-through tree keeps its own `mcp.json`, rewritten to the manifest's version when `manifest` replaced its `plugin.json`; an assembled package takes a root `mcp.json` only when it declares an `agent-plugins.org` `$schema`, and reports one it skips. |
| `floxAgent` | this set's | The flox-agent whose `check-plugin` validates the output. Packages built from this repo get `pkgs/flox-agent`; `null` skips validation. What it validates is documented in the flox-agent repo, `docs/reference/check-plugin-command.md`. |
| `strict` | `false` | Pass `--strict`, making warnings fail the build. Off by default: skills in the wild carry harness frontmatter fields the Agent Skills spec does not list, and those are warnings a correct plugin can have. |
| `runtimes` | `{ }` | Interpreter name → package. Overrides `mappings/runtimes.nix` and pins versions, e.g. `{ python3 = python312; }`. |
| `requiredRuntimes` | `null` | Interpreter tokens the package's files name, as recorded by `flox-agent import`. Required for a generated package — one whose `source.json` carries `import` — and the build fails, naming the fix, if it is missing there. A hand-written call omits it and gets every name in `mappings/runtimes.nix` resolved, the old behavior. |
| `allowPathCommands` | `[ ]` | Bare `mcp.json` commands that intentionally resolve from the consumer environment's PATH instead of the closure. |
| `extraSubstitutions` | `[ ]` | List of `{ file; replace; with; }` applied after the automatic pass, for interpreter mentions in script bodies or SKILL.md text. |
| `meta` | `{ }` | Standard derivation meta. Absent `license` means no assertion. |

## The build phase

Assembly, substitution and the guard no longer run as Nix-generated
shell; the `buildPhase` is a fixed call, whatever the skill count:
`flox-agent assemble-plugin` reads `source.json`, selects and prunes
the skills, writes `plugin.json` and `mcp.json`, rewrites shebangs and
`mcp.json` commands, and guards the result — see flox-agent ADR 0025
and, on the agent-pkgs side, [ADR 0013](../decisions/0013-assembly-lives-in-flox-agent.md).
The `postAssemble` hook runs after, on the fully assembled tree,
before install and the check phase.

`dontPatchShebangs` is set, so nixpkgs' `fixupPhase` does not also
rewrite shebangs in `$out` — it disagreed with the substitution pass
about files under `assets/`, which both the pass and the guard leave
alone on purpose. Design and trade-offs for that:
[ADR 0013](../decisions/0013-assembly-lives-in-flox-agent.md).

## The runtime substitution pass

Before writing the tree, `assemble-plugin`:

1. Detects interpreter names in shebangs (outside `assets/`) and in
   bare `mcp.json` commands, limited to the tokens the package records
   in `requiredRuntimes` (or, for a hand-written call, every name in
   `mappings/runtimes.nix`).
2. Resolves each through the `runtimes` argument, then
   `mappings/runtimes.nix`. An unmapped name fails the build and
   names the file that wanted it.
3. Symlinks each resolved interpreter into the plugin's `bin/` and
   rewrites the references to point there. The symlink targets are
   store paths, so the interpreters land in the plugin's closure.

After the pass, a guard fails the build for any executable that still
has a `/usr/bin/env` shebang; the fix is to map the runtime, or to
move the file under `assets/`. Design and trade-offs:
[ADR 0006](../decisions/0006-runtime-substitution.md) and
[ADR 0013](../decisions/0013-assembly-lives-in-flox-agent.md).

## Passthru

```nix
passthru.agentPlugin = {
  name; path; sourceUrl; specVersion; skills; import;
};
```

## Extension point

`postAssemble` runs on the fully substituted tree before the guard,
install, and checks. Attach with `overrideAttrs`; the
`override-hook` flake check keeps this working.
