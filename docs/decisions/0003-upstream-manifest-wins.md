# 0003. Upstream plugin.json wins; manifest argument fills the gap

Date: 2026-08-28

Status: Superseded by 0008

## Context

Some source repos already ship a spec-conformant `plugin.json`;
most (skill collections) ship none. The builder needs manifest data
in both cases, and silently preferring one source over the other
would hide authorship mistakes.

## Decision

We will use an upstream `plugin.json` from the src root whenever it
exists. The `manifest` argument (a Nix attrset serialized to JSON)
is only for sources that ship none. Passing both is a build error.
`mcpServers` and an upstream `mcp.json` follow the same rule.

## Consequences

- `+` Upstream authorship is respected; generated manifests are
  clearly generated.
- `+` The ambiguous case fails loudly instead of guessing.
- `-` Fixing a broken upstream manifest requires patching src (or a
  future override mechanism), not shadowing it with `manifest`.
