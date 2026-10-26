# 0026. A plugin's lockfile is laid out by the build

Date: 2026-10-23

Status: Proposed

## Context

The discord, imessage and telegram plugins from
`anthropics/claude-plugins-official` run `bun install` and then
`bun server.ts` from a root that ships `package.json` and `bun.lock`.
Their packages hold no `node_modules`: ADR 0012 prunes it, and ADR
0016 accepted that a package is "coherent rather than
self-contained".

Claude Code installs these dependencies itself when it caches a
plugin: registry packages pinned in the lockfile, frozen, no scripts
(plugins/loading, "Node.js package dependencies"). Launch loads
packages in place, which gets no install. Measured under launch,
the servers run unpinned versions online and fail offline; with
`node_modules` laid out they connect offline (agent-stacks ADR 0078).

| Already decided | |
| --------------- | - |
| ADR 0004 | External sources go through import, "where pinning belongs" |
| ADR 0006 | `nix copy` of a plugin carries what it runs |
| ADR 0011 | Code in the plugin's own tree is part of the plugin |
| AI-592 | "Once everything is in a Nix package/derivation this functionality ootb." |

`importNpmLock`, bun2nix and uv2nix fetch per package by hashes
copied out of the lock. One hash over the whole tree would be kept
by hand and go stale on the hourly replay.

## Decision

We lay out a plugin's `bun.lock` at build time, from what import
records (agent-stacks ADR 0078).

- `source.json` carries `nodeModules`: per package, its install
  path, `registry.npmjs.org` tarball, sha512 integrity, and `bin` or
  `binDir`.
- `buildAgentPlugin` checks each entry, refusing another registry,
  fetches it with `fetchurl` by
  its integrity, and hands it to `assemble-plugin`, which lays it
  out and links bins without running scripts. The build fails
  unless every recorded path was laid out.

This narrows ADR 0004: a fetch by a hash import recorded is pinning
in import. A `skills-lock.json` external source is still refused; it
records no hash. It extends ADR 0012: upstream's own `node_modules` is
still pruned. It narrows ADR 0016 for a plugin with a `bun.lock`.

This is the "second case" ADR 0025 left to a mechanism. Whether
agent-pkgs resolves language libraries at all is the question this
record asks; it also sets AI-565's pattern.

## Consequences

- `+` These servers run the lock's versions offline, and `nix copy`
  carries their libraries.
- `+` No hash is kept by hand. Every other package is unchanged.
- `-` A package grows by its tree, 17 to 32 MiB here.
- `-` A plugin with an npm lockfile still gets no `node_modules`.
- `-` The builder must merge before an agent-stacks that emits the
  key.
