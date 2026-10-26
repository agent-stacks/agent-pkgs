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
| `pluginRootPaths` | `null` | Plugin-root entries to ship beside `skills/`, destination → path in src: what the skills and MCP servers reference, and a Claude plugin's `agents/`, `commands/` and `hooks/` (whose `hooks.json` then comes from `hooks`). Copied before the runtime pass, pruned like a skill. See the [import contract](import-contract.md). |
| `ignoredPaths` | `null` | Skill name → paths `--path-ignore` kept out of it, which `assemble-plugin` leaves out. The build fails if one is still in the tree, which means an older agent-stacks (agent-stacks ADR 0067). See the [import contract](import-contract.md). |
| `hooks` | `null` | Claude Code's hooks, an event map, written under a `hooks` key as `com.anthropic.claude-code/hooks/hooks.json`, or as `hooks/hooks.json` when `pluginRootPaths` ships `hooks/` at the root. An agent-stacks older than the key ignores it and the build fails. Not the `hooks` a generated `default.nix` binds for `overrideAttrs` (agent-stacks ADR 0051). |
| `nodeModules` | `null` | The plugin's `bun.lock` as import recorded it, one `{ path, url, integrity, bin?, binDir? }` per package, laid out under `node_modules/`. The build fails unless every `path` is laid out ([ADR 0026](../decisions/0026-a-plugins-lockfile-is-laid-out-by-the-build.md)). See the [import contract](import-contract.md). |
| `mcpServers` | `null` | Attrset serialized to `mcp.json` at the `manifest`'s spec version (1.0.0 without one). Without it, a passed-through tree keeps its own `mcp.json`, rewritten to the manifest's version when `manifest` replaced its `plugin.json`; an assembled package takes a root `mcp.json` only when it declares an `agent-plugins.org` `$schema`, and reports one it skips. |
| `agentStacks` | this set's | The agent-stacks package that assembles the plugin tree (`assemble-plugin`) and whose `check-plugin` validates the output. Packages built from this repo get `pkgs/agent-stacks`; required — `null` fails the build, since assembly cannot be skipped (ADR 0013). What it validates is documented in the agent-stacks repo, `docs/reference/check-plugin-command.md`. |
| `strict` | `false` | Pass `--strict`, making warnings fail the build. Off by default: skills in the wild carry harness frontmatter fields the Agent Skills spec does not list, and those are warnings a correct plugin can have. |
| `requiredRuntimes` | `null` | Interpreter tokens the package's files name, as recorded by `agent-stacks import`. Required for a generated package — one whose `source.json` carries `import` — and the build fails, naming the fix, if it is missing there. A hand-written call omits it and gets only the default packages and what it declares: no package named like a token, as it records no tokens, so a call running `bun`, `tsx`, `uv` or `pwsh` names the package in `dependencies`. |
| `dependencies` | `[ ]` | nixpkgs attribute names from `agent-stacks import --dependency`, searched before the defaults; also the version pin: `[ "python312" ]`. Not searched when `requiredRuntimes` is `[ ]`, as nothing is linked. One nixpkgs lacks, or one that does not evaluate on the system, fails evaluation ([ADR 0023](../decisions/0023-the-plugin-declares-packages-and-the-build-finds-binaries-in-them.md)). |
| `allowPathCommands` | `[ ]` | Bare `mcp.json` commands that intentionally resolve from the consumer environment's PATH instead of the closure. |
| `extraSubstitutions` | `[ ]` | List of `{ file; replace; with; }` applied after the automatic pass, for interpreter mentions in script bodies or SKILL.md text. |
| `meta` | `{ }` | Standard derivation meta, merged over computed defaults ([ADR 0014](../decisions/0014-generated-package-meta.md)): `category = "agent-plugin"`, `platforms = lib.platforms.all`, `description` and `homepage` from the manifest or `sourceUrl` when present, and `license` when `manifest.license` resolves to a known `lib.licenses` entry by `spdxId`. A `meta.license` given as a string names a licence, which is how a generated `source.json` records one the manifest does not spell as SPDX does: an SPDX identifier (`"Apache-2.0"` for a manifest saying `Apache 2.0`), or a `lib.licenses` attribute name where SPDX has none (`"publicDomain"`). It is replaced by that licence; a string nixpkgs has no licence for is dropped ([ADR 0018](../decisions/0018-a-licence-named-in-meta.md)). The manifest's full description is kept as `longDescription` when it says more than the effective `description`. The merge is `defaultMeta // longDescription // meta`, key by key: an explicit key in the caller's `meta` wins over the computed default. The merge can only add or override a key, not remove one — a caller whose manifest declares a licence cannot suppress `meta.license` from the call site by passing an empty `meta`; the manifest is the thing making the claim, so that is where to change it. |

## The build phase

Assembly, substitution and the guard no longer run as Nix-generated
shell; the `buildPhase` is a fixed call, whatever the skill count:
`agent-stacks assemble-plugin` reads `source.json`, selects and prunes
the skills, writes `plugin.json` and `mcp.json`, rewrites shebangs and
`mcp.json` commands, and guards the result — see agent-stacks ADR 0025
and, on the agent-pkgs side, [ADR 0013](../decisions/0013-assembly-lives-in-flox-agent.md).
The `postAssemble` hook runs after, on the fully assembled tree,
before install and the check phase.

`dontPatchShebangs` is set, so nixpkgs' `fixupPhase` does not also
rewrite shebangs in `$out` — it disagreed with the substitution pass
about files under `assets/`, which both the pass and the guard leave
alone on purpose. Design and trade-offs for that:
[ADR 0013](../decisions/0013-assembly-lives-in-flox-agent.md).

## The runtime substitution pass

On the copied tree, `assemble-plugin`:

1. Detects interpreter names in shebangs (outside `assets/`) and in
   bare `mcp.json` commands.
2. Finds each name as an executable `bin/<name>` in the packages the
   builder handed it, in order: the `dependencies` the package
   declared, then `bash`, `python3` and `nodejs`, then the package
   named like it, with that package's main program as a fallback
   (`nodejs`, `bin/node`). Two declared packages shipping a name is
   an error; a name none ships fails the build, naming the file and
   `--dependency`. There is no table.
3. Symlinks each resolved interpreter into the plugin's `bin/` and
   rewrites the references to point there. The symlink targets are
   store paths, so the interpreters land in the plugin's closure.

A generated package recording no runtime gets neither the defaults
nor its declared packages, so a Markdown-only plugin pulls no
interpreter even when its import's `--dependency` names one for a
sibling plugin; a hand-written call gets both. A package named like a
token is left out when it is already listed and its main program is
the token, as `bin/<token>` was searched there.

After the pass, a guard fails the build for any executable outside
`assets/` whose shebang does not point into that plugin-local `bin/` —
not only the `/usr/bin/env` form the pass targets, but any shebang the
pass left alone. An upstream `bin/` is read like the rest; the
interpreter links beside its files are symlinks, which the guard skips
([ADR 0019](../decisions/0019-an-upstream-bin-ships-beside-the-interpreter-links.md)).
The fix is to declare the package that ships the runtime, or to move
the file under `assets/`. Design and trade-offs:
[ADR 0006](../decisions/0006-runtime-substitution.md),
[ADR 0013](../decisions/0013-assembly-lives-in-flox-agent.md) and
[ADR 0023](../decisions/0023-the-plugin-declares-packages-and-the-build-finds-binaries-in-them.md).

## Passthru

```nix
passthru.agentPlugin = {
  name = "NAME";
  path = "share/agent-plugins/NAME";
  sourceUrl = "...";        # the argument; null without it
  specVersion = "1.0.0";    # from manifest $schema; null without a
                            #   manifest argument or its $schema
  skills = [ "skill-a" ];   # the skills argument's names; null when
                            #   selected at build time
  import = { input = "OWNER/REPO"; flags = [ ]; };
                            # the argument; null when hand-written
  rev = "...";              # the src pin's rev and hash; null when
  hash = "sha256-...";      #   src is a path or a derivation
  unresolvedLicense = null; # a meta.license string nixpkgs has no
                            #   licence for; null when it resolved
  pluginRootPaths = [ "scripts" ];
                            # the argument's destinations; null when
                            #   unset, [ ] for { }
  nodeModules = [ "node_modules/which" ];
                            # each entry's path; null when unset or [ ]
  call = { name = "NAME"; ... };
                            # what assemble-plugin reads
  runtimeCandidates = [ { attr = "bash"; tier = "default"; } ];
};
```

`runtimeCandidates` is the packages the build searches for runtimes,
in order, with the tier `declared`, `default` or `named`.

## Extension point

`postAssemble` runs on the fully assembled tree, after the guard,
before install and checks — the guard now runs inside
`agent-stacks assemble-plugin` itself, not as a separate Nix-side step
after it. Attach with `overrideAttrs`; the `override-hook` flake check
keeps this working.
