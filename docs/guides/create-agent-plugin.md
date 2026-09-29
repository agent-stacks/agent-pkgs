# Create an agent-plugin package

How to create an agent-plugin Nix package from an existing skills
repository, using
[juliusbrussee/caveman](https://github.com/juliusbrussee/caveman) as
the example.

Packages are generated rather than hand-written. The CLI command
`agent-stacks import` pins an upstream repository and writes the two
files that make a package; `buildAgentPlugin` turns those into the
canonical file layout at build time. See
[reference/import-contract.md](../reference/import-contract.md).
The flags belong to the tool, so this page links to
[agent-stacks's import reference](https://github.com/agent-stacks/agent-stacks-cli/blob/main/docs/reference/import-command.md).

## Where the package should be defined

A plugin package is defined by two small generated files, and it can
live in any repository whose Nix scope can supply `buildAgentPlugin`.
Which repository that should be depends on who the skills are for:

| The skills are | Put the package in | Why |
| -------------- | ------------------ | --- |
| public and broadly applicable | this repo, under `pkgs/` | CI builds it on every PR and Hydra publishes it to `cache.agent-stacks.org`, so everyone gets it prebuilt |
| private, or specific to one organization | a repository of your own | a public package set is the wrong home for skills that should not be published; see [Building outside agent-pkgs](#building-outside-agent-pkgs) |

This guide walks the public case, which would involve a pull request
to contribute the package upstream.

## Requirements

Nix with flakes, and git. You do not need `agent-stacks` installed.

## 1. Import the upstream skills repository

The example skills you import are at
`github.com/juliusbrussee/caveman`. Change the repository as
appropriate for your scenario.

```sh
# in the top-level directory of agent-pkgs
nix run .#agent-stacks -- import juliusbrussee/caveman -out pkgs
```

`-out` is the output root, not the package directory. The importer
appends `agent-plugin-<name>/` to it, so `-out pkgs` writes
`pkgs/agent-plugin-caveman/`.

The `-out` flag is not optional here. Its default writes outside this
repository's `pkgs/`, where nothing supplies `buildAgentPlugin` and the
package cannot be built.

Import prints what it did and what it noticed:

```text
warning: skills/cavecrew: skill "cavecrew" already found at plugins/caveman/skills/cavecrew, not imported
warning: skills/caveman: skill "caveman" already found at plugins/caveman/skills/caveman, not imported
warning: skills/caveman-compress: skill "caveman-compress" already found at plugins/caveman/skills/caveman-compress, not imported
warning: skills/caveman-stats: skill "caveman-stats" already found at plugins/caveman/skills/caveman-stats, not imported
warning skills/caveman-explore/SKILL.md: unknown frontmatter fields: model, tools
caveman: unchanged at 2fd153c67988
```

Warnings are not failures. The first four say the upstream tree
carries the same skill twice; import kept the copy under
`plugins/caveman/` and skipped the one under `skills/`. Spec
deviations outside a plugin's own `SKILL.md` errors are recorded
rather than fatal, and the ones import attributes to a file land in
the generated `source.json` under `import.warnings`, so a reviewer
sees them without re-running the command.

The final summary line explains the outcome:

| Line | Meaning |
| ------------------------ | ------- |
| `new plugin` | First import of this upstream |
| `unchanged at <rev>` | Byte-identical to what is already committed; nothing written |
| `regenerated at <rev>` | Same upstream commit, different bytes — an older importer wrote it, or it was edited |
| `<old> -> <new>` | Upstream moved; skills added and removed are listed |

caveman is already packaged in this repo, so the command above
reports `unchanged`. A repository not yet packaged reports `new
plugin` and creates a new directory. Re-import is also the
update path: there is no `upgrade` verb.

## 2. Read the files from the import

```sh
ls pkgs/agent-plugin-caveman/
```

Two files, and `source.json` is the one to read first. It is the
`buildAgentPlugin` call, serialized: its top level is exactly the
builder's argument set, key for key. The formals carry no `...`, so a
key the builder does not declare fails the build rather than being
ignored. If you have seen nvfetcher's `_sources/generated.json`, or
any nixpkgs package that keeps its pin in a JSON file beside a thin
`default.nix`, this uses that familiar pattern.

Twenty of caveman's entries are skills. A flat object, with these
keys:

| Key | What it holds | What it becomes |
| --- | --- | --- |
| `name`, `version` | the plugin name, and the derivation version | the package name, and `share/agent-plugins/<name>/` |
| `src` | for a generated package, a `fetchFromGitHub` pin: `owner`, `repo`, `rev`, `hash` | the upstream tree the build copies from |
| `manifest` | the Agent Plugins manifest, carrying its own `$schema` | `plugin.json`, written out verbatim |
| `skills` | skill name → path in the upstream tree, described below | the `skills/` directory |
| `requiredRuntimes` | interpreter tokens the tree's scripts name, such as `python3` | symlinks in the plugin's `bin/`, with shebangs rewritten to them |
| `mcpServers` | server definitions, when the plugin declares any | `mcp.json` |
| `sourceUrl`, `meta` | the upstream URL, and derivation meta | `passthru.agentPlugin`, and the package's `meta` |
| `import` | the input, the flags, and the warnings from the run that wrote the file | nothing: it is provenance a reviewer reads |

caveman declares no MCP servers, so it has no `mcpServers` and its
build produces no `mcp.json`.
`pkgs/agent-plugin-agentmemory/source.json` is one that does.

### `skills` names paths in the upstream tree

The values are paths relative to the root of `src`, not paths in the
output. Upstream decides where a skill's directory sits; `skills` is
how the build finds it, and the key is the name it will have under
`share/agent-plugins/caveman/skills/`. caveman shows both shapes in
one package: `"lean-build": "skills/lean-build"` for a skill upstream
keeps at the top level, and `"caveman": "plugins/caveman/skills/caveman"`
for one it keeps under a plugin directory.

The map is also the selection: the build copies what `skills` names
and prunes the rest of the fetched tree. That is what the warnings in
step 1 were about — caveman carries four skills at two paths each, and
only one path per name survives into this file.

`default.nix` is the shim that hands that data to the builder,
identical in every package a current importer has generated:

```nix
# Generated by agent-stacks import.
#
# Everything outside the custom markers is rewritten on every import, so
# changes there are lost. Everything between them is left alone.
{ buildAgentPlugin, pkgs }:

let
  source = builtins.fromJSON (builtins.readFile ./source.json);
  # BEGIN custom — kept as it is when this file is regenerated
  args = { };
  hooks = old: { };
  # END custom — anything outside these markers is overwritten
in
(buildAgentPlugin (source // args)).overrideAttrs hooks
```

`source.json` is never edited by hand: to move a package, re-import
it. In `default.nix` only the region between the custom markers is
yours, and re-import carries it across — see [Per-repository
workarounds](#per-repository-workarounds).

## 3. Stage a new package in git before building

```sh
git add pkgs/agent-plugin-caveman
```

Nix flakes only see git-tracked files, so a brand-new package
directory is invisible to the build until it is staged. Skip this and
the build fails by naming an attribute rather than the files:

```text
error: flake 'git+file:///…' does not provide attribute
'packages.aarch64-darwin.agent-plugin-testcase', …
```

Package discovery reads `pkgs/` from the flake's source, which is the
git tree — an untracked directory is not in it, so the attribute
genuinely does not exist. There is nothing to stage when re-importing
an already-committed package.

## 4. Nix build

```sh
nix build .#agent-plugin-caveman && readlink -f result
```

`nix build` does not print the output path on success; it leaves a
`result` symlink into the store, and `readlink -f` shows the path.

The result is the canonical layout — `plugin.json` and `skills/`
always, `mcp.json` when the plugin declares servers, and whatever
else the upstream tree carries (caveman's scripts bring a `bin/`):

```text
result/share/agent-plugins/caveman/
├── plugin.json
├── skills/          # 20 skills: caveman, cavecrew, lean-build, …
└── bin/             # python3
```

A build includes plugin validation as `buildAgentPlugin` runs
`agent-stacks check-plugin` on the output.

## 5. Inspect the warnings yourself (optional)

The install check above is not strict by default, so warnings do not
fail the build. To read them:

```sh
nix run .#agent-stacks -- check-plugin ./result/share/agent-plugins/caveman
```

```text
warning skills/caveman-explore/SKILL.md: unknown frontmatter fields: model, tools
OK ./result/share/agent-plugins/caveman (Agent Plugins 1.1.0)
```

## 6. Open the pull request

This step is only required if you are contributing plugin updates to
this repository.

```sh
git checkout -b import/caveman
git commit -m "import: juliusbrussee/caveman"
```

CI builds every package on every PR. Commit only the two generated
files; `result` is a build artifact and should be ignored.

## Next: run it in a stack

The package is a directory of skills in the spec layout, which is not
yet something you can run. Composing it with a harness into a launcher
is the other guide:
[create-agent-stack.md](create-agent-stack.md) builds a stack around
this plugin and Claude Code.

That does not wait on the pull request. `mkAgentStack` accepts any
package `buildAgentPlugin` produced, a local checkout included, so the
stack can be built and run while the import is still in review.

## Building outside agent-pkgs

For skills that should not be published, run the same import in your
own repository. The generated `default.nix` is a callPackage-style
function taking two arguments: `buildAgentPlugin`, which this repo
exposes as a `lib` output, and `pkgs`, which `callPackage` fills in
from your nixpkgs.

```nix
# flake.nix, in your own repository
{
  inputs.agent-pkgs.url = "github:agent-stacks/agent-pkgs";
  inputs.nixpkgs.follows = "agent-pkgs/nixpkgs";

  outputs = { self, nixpkgs, agent-pkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system}.agent-plugin-internal =
        pkgs.callPackage ./pkgs/agent-plugin-internal {
          inherit (agent-pkgs.lib.${system}) buildAgentPlugin;
        };
    };
}
```

Following `agent-pkgs`'s nixpkgs rather than pinning your own keeps one
revision under the build. A second revision is how two repositories
produce two store paths for the same plugin.

```sh
nix run github:agent-stacks/agent-pkgs#agent-stacks -- \
  import your-org/your-skills -out pkgs
git add pkgs
nix build .#agent-plugin-internal
```

Every other step on this page applies unchanged: the generated files,
staging before building, the install check. The result is the same
derivation it would be here — importing `juliusbrussee/caveman` into a
standalone repository and building it that way evaluates to the same
`.drv`, and so the same store path, as `nix build
.#agent-plugin-caveman` does in this one.

## Per-repository workarounds

Most repositories import with no flags. When one needs help, there
are two places to put it, and which one depends on what it changes:
if it decides what gets imported, it is a flag; if it changes the
built package, it is the block in `default.nix`.

A flag is recorded in `source.json` under `import.flags` and replayed
by CI, so it is written once at import:

```sh
agent-stacks import garrytan/gstack --path-ignore 'test/**'
```

The block is the text between the two markers in a package's
`default.nix`. Everything outside the markers is rewritten on every
import; the block is carried across untouched:

```nix
  # BEGIN custom — kept as it is when this file is regenerated
  # why: 22 skills call ${CLAUDE_PLUGIN_ROOT}/scripts/*, which the
  # contract doesn't ship
  args = { };
  hooks = old: { postAssemble = ''cp -R scripts "$dest/"''; };
  # END custom — anything outside these markers is overwritten
```

Every block needs a `why:` line.

A block may never set `doInstallCheck = false`, and may never narrow
`installCheckPhase`. That would switch off `check-plugin` for a
package people install. A block is a workaround for a packaging gap,
never an escape from validation.

The markers are how a current importer writes `default.nix`, so the
package should have them. A package generated before
they existed will not, and a block added by hand to one of those is
erased the next time it is re-imported. Re-import it first, then write
the block into the regenerated file.

## Where the details live

| Question | Page |
| -------- | ---- |
| What the generated files must contain | [reference/import-contract.md](../reference/import-contract.md) |
| Every `buildAgentPlugin` argument | [reference/build-agent-plugin.md](../reference/build-agent-plugin.md) |
| Import's flags and discovery rules | [agent-stacks `import`](https://github.com/agent-stacks/agent-stacks-cli/blob/main/docs/reference/import-command.md) |
| Which deviations warn | [agent-stacks `check-plugin`](https://github.com/agent-stacks/agent-stacks-cli/blob/main/docs/reference/check-plugin-command.md) |
| Composing plugins into a stack | [create-agent-stack.md](create-agent-stack.md) |
| Every `mkAgentStack` argument | [reference/mk-agent-stack.md](../reference/mk-agent-stack.md) |
