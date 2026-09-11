# The import → builder contract

This is the call shape `flox-agent import --out pkgs/` generates into
`pkgs/agent-plugin-<name>/`, and the passthru schema consumers can
rely on. `flox-agent import` (flox-agent repo) codes against this file;
`buildAgentPlugin` (this repo) implements it. Change either side only
together with this document.

## Generated files

`flox-agent import` writes two files into `pkgs/agent-plugin-<name>/`:

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
path strings. `manifest` is always present, and the builder writes
it over any `plugin.json` the source root ships (ADR 0008); the
version in `$schema` is the newest the importer vendors, not a fixed
`1.0.0`. `mcpServers` is present when the plugin has MCP servers,
normalized by the importer to the transports the schema names, and
the builder writes it as `mcp.json` with the manifest's `$schema`
version, over any `mcp.json` in the source. Both arguments remain
available to hand-written callers.

`import` is declared but only reaches `passthru` — nothing in the
build reads it. It carries `input` (owner/repo), `flags` (the import
invocation's flags), and `warnings` (the `{ path, message }` entries
`flox-agent check-plugin` raised at import time) — present only when
check-plugin warned about something, since the Go struct marks it
`omitempty` — so the record of what produced the package travels with
it.

## What the generator decides

How `<name>`, `version`, `manifest` and the `skills` paths are chosen
is import's side of the contract, and lives with the importer: see
the flox-agent repo, `docs/decisions/0013-plugin-root-and-identity.md`
for the reasoning and `docs/reference/import-command.md` for the
behavior.

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
  (ADR 0008).
- **The manifest carries the spec version.** A generated `mcp.json`
  declares the same version the manifest does, because a client must
  disable MCP for a plugin whose `mcp.json` targets a different
  version than its `plugin.json` (spec §7.2.2). A src shipping its own
  `plugin.json` keeps whatever version that file declares.

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
  specVersion = "1.0.0";    # from manifest $schema; null when the
                            #   manifest came from the src tree
  skills = [ "skill-a" ];   # null when selected at build time
  import = { input = "OWNER/REPO"; flags = [ ]; };
                            # null when the package was hand-written
};
```

## Validation

The install check phase runs `flox-agent check-plugin` on the output,
using the flox-agent from this package set. Import validates trees at
generation time with the same command, so both ends of the pipeline
enforce the same spec (vendored in flox-agent). Pass `strict = true`
to fail on warnings as well.

## Runtime substitution

The builder itself rewrites shebangs and bare `mcp.json` commands to
a plugin-local `bin/` of store-path symlinks, resolved through
`mappings/runtimes.nix` and the per-plugin `runtimes` argument. See
[build-agent-plugin.md](build-agent-plugin.md) and ADR 0006. The
`postAssemble` hook still exists for extensions and runs on the fully
substituted tree.

Import may later emit `runtimes` hints into the generated call; that
is not part of the contract yet.
