# 0026. A plugin's lockfile is laid out by the build

Date: 2026-10-23

Status: Proposed

## Context

The discord, imessage and telegram plugins from
`anthropics/claude-plugins-official` start their servers with
`bun install` and then `bun server.ts`, from a root that ships
`package.json` and `bun.lock` (agent-stacks ADR 0035, AI-924). Their
packages hold no `node_modules`. ADR 0012 prunes one wherever it
appears, and ADR 0016 accepted that shipping code does not resolve
what the code imports: "the package becomes coherent rather than
self-contained".

Claude Code installs these dependencies itself. When it copies a
plugin into its cache, "it also installs the plugin's Node.js package
dependencies there", if the plugin root has `package.json` and a
supported lockfile (plugins/loading, "Node.js package dependencies").
It installs registry packages pinned in the lockfile, frozen, without
running their scripts. A plugin loaded in place gets no install, and
`agent-stacks launch` loads every package in place.

Measured under launch on 2026-10-23 (agent-stacks ADR 0075): online,
the servers connect on whatever versions Bun's auto-install fetches,
not the lock's; offline, or under the sandbox's default policy, they
fail. With a `node_modules` laid out beside them and upstream's
install skipped, they connected from a read-only tree with the
registry unreachable.

What this repository already holds:

- ADR 0004: the builder refuses a `skills-lock.json` external
  source; external sources go through import, "where pinning
  belongs".
- ADR 0006: "`nix copy` of a plugin carries its interpreters; the
  offline demo claim holds."
- ADR 0011: a script in the skill's own tree is part of the skill.
  Libraries pinned by the plugin's own lockfile are the plugin's in
  the same way, not a tool the user chose.
- AI-592, closed: "Once everything is in a Nix package/derivation this
  functionality ootb." AI-565 points Python libraries at override
  hooks and `python3.withPackages`.

`importNpmLock`, bun2nix and uv2nix fetch per package, from hashes a
generator copies out of the lock. Reading the lock from the fetched
source here would be import-from-derivation. One hash over the whole
tree would be kept by hand, and the hourly replay would leave it
stale while Nix silently reused the old tree.

ADR 0025 handles one skill's engine in its own package and leaves a
mechanism to "a second case". This is a rule Claude Code applies to
every plugin, with three packages under it today.

## Decision

We will lay out a plugin's `bun.lock` at build time, as Claude Code
installs it when it caches the plugin.

Import decides when and records what (agent-stacks ADR 0075). It
reads only a root `bun.lock`. An npm lockfile is left as today until
a case needs it: nothing would stop an `npm install` at start from
writing to the read-only tree.
`source.json` carries `nodeModules`: for each package, its install
path, its registry tarball, the lockfile's sha512 integrity for it,
and its `bin` or `binDir`, sorted by path. The key is absent for
every other plugin. Import also sets
`BUN_CONFIG_SKIP_INSTALL_PACKAGES=1` for the servers that run from
the plugin root, so upstream's `bun install` there does nothing.

`buildAgentPlugin` checks each entry, fetches its tarball with
`fetchurl` by that integrity, and hands it to `assemble-plugin`. That
unpacks each at its path, skips one its parent's tarball already
bundles, and links each top-level package's bins into
`node_modules/.bin`, running no scripts. Nothing is resolved here.
The build fails unless every recorded path was laid out, as it does
for `hooks` and `ignoredPaths`.

This narrows ADR 0004. A fixed-output fetch by a hash import recorded
is pinning done in import, which 0004 allows; a `skills-lock.json`
external source is still refused because the lock carries no hash to
fetch it by. It extends ADR 0012: its list still prunes a
`node_modules` that upstream committed, and the shipped one is built
from the recorded tarballs after it. It narrows ADR 0016's last
consequence: a plugin with such a lockfile is self-contained for its
libraries.

## Consequences

- `+` These servers run the lock's versions, offline, from a
  read-only tree and under a default-deny sandbox, and `nix copy`
  carries their libraries as ADR 0006 says it carries interpreters.
- `+` No hash is kept by hand and nothing is read at evaluation. A
  changed lockfile arrives as a `source.json` diff on the next replay.
- `+` Every other package is unchanged: the call without the key is
  byte-identical, and so is each derivation.
- `-` A package grows by its tree, 26 to 49 MB for the three (17 MiB
  of NAR for telegram), with 95 to 115 fixed-output fetches each. The
  tarballs are build inputs, not runtime closure.
- `-` For these plugins, language libraries are resolved rather than
  recorded. Whether agent-pkgs resolves them at all is the decision
  this record asks for; it also sets the pattern for AI-565.
- `-` The flake does not assert the layout, which is the binary's
  (ADR 0017). `node-modules-call` covers the call only.
- `-` A plugin with an npm lockfile still gets no `node_modules`.
- `-` The builder lands before an agent-stacks that emits the key.
  Until the pin moves past agent-stacks ADR 0075, nothing records it,
  and a hand-written call with entries fails at the guard.
