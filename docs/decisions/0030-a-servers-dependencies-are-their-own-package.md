# 0030. A server's dependencies are their own package

Date: 2026-10-28

Status: Proposed

## Context

discord, imessage and telegram from `anthropics/claude-plugins-official`
start their MCP server with `bun install && bun server.ts`, from a
plugin root that ships `package.json` and `bun.lock`. The root is
read-only here, so the servers run whatever Bun fetches online and
fail offline.

At the 2026-10-28 sync the team decided import does not bundle
language dependencies (agent-stacks ADR 0080). It warns, and packaging
lives in this repo, in custom blocks, with the binary and the plugin
as separate packages (ADR 0011, 0025).

## Decision

A server's dependencies are a package of their own,
`<plugin>-node-modules`, built from the `bun.lock` the plugin pins.
`lib/bun-lock-modules.nix` reads the lock at evaluation from the
plugin's source, fetched by `lib/plugin-source.nix` as ADR 0025
fetches it, fetches each package by the lock's sha512, and lays out the
hoisted tree without running Bun or any script. A package limited by
`os`, `cpu` or, on Linux, `libc` is laid out only where it matches, as
Bun selects it, and a `binDir` is linked as Bun links it. The
`bun-lock-modules` check lays out a fixture lock for several platforms,
since the real locks have no platform packages. The packages are
published, as `impeccable-engine` is.

Not bun2nix: it builds from a generated `bun.nix` committed per
server, which the hourly replay cannot regenerate when upstream's
`bun.lock` moves, and it defaults to an isolated layout. These
servers need the hoisted one: two import `zod` without declaring it.

The plugin's custom block, through `lib/bun-server-hooks.nix`, copies
that tree into the plugin, since the Agent Plugins spec rejects a path
resolving outside the plugin root. Bun is not wrapped: with the
lock's tree in place, upstream's `bun install` finds nothing to do,
writes nothing and needs no network, so its `start` runs as written.
The plugin's install check runs that install unwrapped, offline, in a
read-only copy, which fails the build when the tree does not match the
lock or a Bun upgrade starts writing to the root. It then removes one
package and requires the same install to fail, so a Bun that stopped
checking the tree cannot pass.

An earlier draft wrapped `bin/bun` with
`BUN_CONFIG_SKIP_INSTALL_PACKAGES=1`. That made the check unable to
fail, hid a tree that did not match the lock, and reached every process
the server starts.

## Consequences

- `+` The servers run the lock's versions offline, and each build
  proves Bun accepts the tree as the lock's.
- `+` The replay moves the dependencies with the plugin; no hash is
  kept by hand.
- `-` A lock entry from another registry, or a lock this cannot read,
  fails that package's build, naming the entry.
- `-` Evaluating these packages fetches the plugin's source, as ADR
  0025 accepted, so a source that cannot be fetched fails evaluation.
- `-` The plugin audit re-audits these plugins when the tree or the
  libraries laying it out change, not only when their call file does.
- `-` Each plugin adds about 17 to 32 MiB.
