# 0026. A server's dependencies are their own package

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
plugin's source, fetched as ADR 0025 fetches it, fetches each package
by the lock's sha512, and lays out the hoisted tree without running
Bun or any script.

The plugin's custom block copies that tree into the plugin, so nothing
resolves outside the plugin root, and wraps `bin/bun` with
`BUN_CONFIG_SKIP_INSTALL_PACKAGES=1`, so upstream's `bun install`
does nothing and its `start` runs as written.

## Consequences

- `+` The servers run the lock's versions offline. The tree matches
  `bun install --frozen-lockfile` file for file.
- `+` The replay moves the dependencies with the plugin; no hash is
  kept by hand.
- `-` A lock with a platform-limited package or another registry
  fails evaluation, naming the package.
- `-` Evaluating these packages fetches the plugin's source, as ADR
  0025 accepted.
- `-` Each plugin adds about 17 to 32 MiB.
