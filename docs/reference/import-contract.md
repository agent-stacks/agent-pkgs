# The import → builder contract

This is the call shape `agent-stacks import --out pkgs/` generates into
`pkgs/agent-plugin-<name>/`, and the passthru schema consumers can
rely on. `agent-stacks import` (agent-stacks repo) codes against this file;
`buildAgentPlugin` (this repo) implements it. Change either side only
together with this document.

## Generated files

`agent-stacks import` writes two files into `pkgs/agent-plugin-<name>/`:

`default.nix` is a three-line template, byte-identical across every
generated package — it reads `source.json` and hands it to
`buildAgentPlugin` whole:

```nix
{ buildAgentPlugin }:

buildAgentPlugin (builtins.fromJSON (builtins.readFile ./source.json))
```

`source.json`'s top level is exactly `buildAgentPlugin`'s argument
set — every key is a declared formal, and the formals carry no `...`,
so an undeclared key is a build error by design:

```json
{
  "name": "NAME",
  "version": "0-unstable-YYYY-MM-DD",
  "src": {
    "owner": "OWNER",
    "repo": "REPO",
    "rev": "COMMIT",
    "hash": "sha256-..."
  },
  "sourceUrl": "https://github.com/OWNER/REPO",

  "manifest": {
    "$schema": "https://agent-plugins.org/schemas/VERSION/plugin.schema.json",
    "name": "NAME",
    "description": "...",
    "license": "..."
  },

  "mcpServers": {
    "server-a": { "type": "streamable-http", "url": "https://..." }
  },

  "skills": {
    "skill-a": "path/inside/src/skill-a",
    "skill-b": "other/path/skill-b"
  },

  "requiredRuntimes": ["python3", "node"],

  "pluginRootPaths": { "scripts": "scripts" },

  "meta": {
    "description": "...",
    "homepage": "https://github.com/OWNER/REPO"
  },

  "import": {
    "input": "OWNER/REPO",
    "flags": [],
    "warnings": [
      { "path": "skills/skill-a/SKILL.md", "message": "..." }
    ]
  }
}
```

`src` is a pin, not a derivation — JSON cannot hold one, so
`buildAgentPlugin` fetches it with `fetchFromGitHub` whenever it is an
attrset carrying `owner` and `repo`. `skills` values are plain in-tree
path strings. A file written by an importer carrying agent-stacks's
record "Import hands the builder the manifest and servers it checked"
carries `manifest` in every case, and the builder writes it as
`plugin.json`; a `plugin.json` the source root ships is not read
(ADR 0009). The version in `$schema` is the newest the importer
vendors, not a fixed `1.0.0`. `mcpServers` is present when the plugin
declares MCP servers, with `http` and untyped servers mapped by the
importer to the transports the schema names, and the builder writes
it as `mcp.json` with the manifest's `$schema` version. A file from
an earlier importer is still built: such a file omits `manifest` when
the plugin's own `plugin.json` sits at the root and never carries
`mcpServers`, and the builder then takes a root `plugin.json` that
declares an `agent-plugins.org` `$schema`, and a root `mcp.json` that
does the same. Any other root file is not read.

`import` is declared but only reaches `passthru` — nothing in the
build reads it. It carries `input` (owner/repo), `flags` (the import
invocation's flags), and `warnings` (the `{ path, message }` entries
`agent-stacks check-plugin` raised at import time, plus two kinds the
scanner itself raises while staging the tree: a script under
`skills/` with no shebang, which the build links no interpreter for,
and a dependency manifest — `pyproject.toml`, `requirements.txt`,
`package.json` — which the build does not resolve) — present only
when something was found, since the Go struct marks it `omitempty` —
so the record of what produced the package travels with it.

`pluginRootPaths` maps a plugin-root entry's destination inside the
plugin tree to its path inside `src`. It is what the selected skills
reach through `${PLUGIN_ROOT}`, which Claude spells
`${CLAUDE_PLUGIN_ROOT}`: a plugin whose executable code sits beside
`skills/` rather than inside a skill ships it this way. The builder
copies exactly these entries, before the runtime pass, so their
contents are rewritten, pinned and guarded like a skill's own files;
a directory is copied whole. Destinations are one path segment, and
never `skills` or `bin`, which assembly writes itself. The field is
absent when the skills reference nothing outside themselves, so a
package that predates it is unchanged. See
[ADR 0016](../decisions/0016-plugin-root-code-ships-when-skills-reference-it.md).

`requiredRuntimes` is a flat array of the interpreter tokens the
scanner found named in the package's files — shebangs and bare
`mcp.json` commands. It is required for a generated package: a
`source.json` carrying `import` must also carry `requiredRuntimes`,
and `buildAgentPlugin` throws, naming the fix, if it does not. A
hand-written `buildAgentPlugin` call omits both `import` and
`requiredRuntimes` and falls back to resolving every name in
`mappings/runtimes.nix`, the behavior every package had before this
key existed. See [ADR 0013](../decisions/0013-assembly-lives-in-flox-agent.md)
for why the fallback stays hand-written-only, and the minimum
agent-stacks rev that emits this key.

## What the generator decides

How `<name>`, `version`, `manifest` and the `skills` paths are chosen
is import's side of the contract, and lives with the importer: see
the agent-stacks repo, `docs/decisions/0021-root-skill-beside-nested-skills.md`
for the reasoning and `docs/reference/import-command.md` for the
behavior. (0021 supersedes 0014, which supersedes 0013, which this
page used to name: the fallback to a directory name is gone, and a
name now always comes from the manifest that defined the plugin; a
root `SKILL.md` is one skill among those below it rather than the
end of the search.)

One naming rule matters on this side: the package directory, and so
the flake attribute, is the plugin's name behind an `agent-plugin-`
prefix, while `name` in the call is the unprefixed plugin name that
`share/agent-plugins/<name>/` and the manifest both use. The plugin
`flox` is `pkgs/agent-plugin-flox/`, built as `agent-plugin-flox`.

Two further consequences bind the builder:

- **`src` is the repository, not the plugin root.** A plugin held in
  a subdirectory still arrives with `skills` paths relative to the
  repository root, because `fetchFromGitHub` pins the whole
  repository. Whatever the repository root ships, the package is
  built from the `manifest` and `mcpServers` the importer checked
  (ADR 0009).
- **The root skill's copy excludes every skill directory below it.**
  A repository whose root `SKILL.md` is a router or a parent arrives
  as `"skills": {"parent": ".", "inner": "skills/inner", ...}`: the
  root skill at `.` and every nested one at its own path. The
  importer's search went on below the root, so every directory below
  it holding a `SKILL.md` was either imported as its own skill or
  dropped. The builder removes each from the root skill's copy,
  whether the map lists it or not, so a nested skill is packaged once
  at its own name and a dropped one is not packaged at all. A wrapper
  directory left empty goes too. Any other skill is copied whole. The
  importer stages the same tree for its check phase and records what
  the copy left out in `import.warnings`. `.` may be spelled `./`. A
  `source.json` written before this rule with a skill at `.` builds
  the same way (agent-stacks ADR 0021).
- **The manifest carries the spec version.** A generated `mcp.json`
  declares the same version the manifest does, because a client must
  disable MCP for a plugin whose `mcp.json` targets a different
  version than its `plugin.json` (spec §7.2.2). A passed-through
  tree's `mcp.json` is brought to the manifest's version when a
  manifest argument replaces its `plugin.json`.

## Skill selection precedence (builder side)

1. Explicit `skills` argument — what import generates.
2. `skills-lock.json` at the src root, read at build time. Entries
   whose files are not inside src fail the build (a pure build cannot
   fetch external sources).
3. Passthrough: src already is a conformant plugin tree.

## Output layout

```text
$out/share/agent-plugins/<name>/
├── plugin.json
├── skills/<skill-name>/SKILL.md ...
└── mcp.json        # only when configured
```

## Passthru schema

```nix
passthru.agentPlugin = {
  name = "NAME";
  path = "share/agent-plugins/NAME";
  sourceUrl = "...";        # null for local sources
  specVersion = "1.0.0";    # from manifest $schema; null without a
                            #   manifest argument or its $schema
  skills = [ "skill-a" ];   # null when selected at build time
  import = { input = "OWNER/REPO"; flags = [ ]; };
                            # null when the package was hand-written
};
```

## Validation

The install check phase runs `agent-stacks check-plugin` on the output,
using the agent-stacks from this package set. Import validates trees at
generation time with the same command, so both ends of the pipeline
enforce the same spec (vendored in agent-stacks). Pass `strict = true`
to fail on warnings as well.

## Assembly and runtime substitution

Assembly and substitution are performed by `agent-stacks assemble-plugin`,
not by Nix: it selects and prunes the skills, writes `plugin.json` and
`mcp.json`, and rewrites shebangs and bare `mcp.json` commands to a
plugin-local `bin/` of store-path symlinks. `buildAgentPlugin`'s
`buildPhase` is a single call into it; the Nix side keeps fetching,
resolving `requiredRuntimes` through `mappings/runtimes.nix` and the
per-plugin `runtimes` argument, install, and the check phase. See
[build-agent-plugin.md](build-agent-plugin.md), ADR 0006, and
[ADR 0013](../decisions/0013-assembly-lives-in-flox-agent.md) for the
move out of Nix. The `postAssemble` hook still exists for extensions
and runs on the fully assembled, substituted tree.

Import already emits the `requiredRuntimes` hint described above; a
generated call is scoped to the tokens it found rather than resolving
every name in `mappings/runtimes.nix`.
