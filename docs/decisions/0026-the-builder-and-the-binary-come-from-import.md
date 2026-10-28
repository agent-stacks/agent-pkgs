# 0026. The builder and the binary come from import

Date: 2026-10-28

Status: Proposed

## Context

Until now this repository owned three things every generated package
builds with: `lib/build-agent-plugin.nix`, the hand-written
`pkgs/agent-stacks` that `update-agent-stacks` re-pinned by rewriting
its `source.json`, and `lib/runtime-defaults.nix`, the default runtime
packages, which agent-stacks mirrored in Go.

That made a generated package buildable only here (AI-928): anywhere
else `buildAgentPlugin` was missing. agent-stacks ADR 0079 moves all
three into `agent-stacks import`, which now writes the builder into
`lib/`, the binary that ran it into `pkgs/agent-stacks/` (pinned from
that build's `hashes.json`), and the default packages into every
`source.json` as `defaultDependencies`.

## Decision

We will take the builder, the binary package and the runtime list from
import, and stop maintaining our own.

- `lib/build-agent-plugin.nix` and `pkgs/agent-stacks/` are generated.
  They are never edited here; a change goes to agent-stacks-cli.
- `flake.nix` passes the builder the binary package as `agent-stacks`,
  in place of `defaultAgentStacks`. The builder runs its
  `passthru.unwrapped`, as before. `mkAgentStack` is unchanged.
- `lib/runtime-defaults.nix` and the `runtime-defaults-resolve` check
  are deleted. The hand-written builder calls in `flake.nix`'s checks
  pass `defaultDependencies` where they link runtimes.
- `update-agent-stacks` no longer rewrites a `source.json`. It fetches
  the newly uploaded binary, checks it against its `hashes.json`, and
  runs that binary's `import --replay` on one recorded input; every
  import rewrites the shared files for the binary that ran it.
- `audit-plugins` keys on `pkgs/agent-stacks/default.json`.

## Consequences

- `+` A package from this set builds in any flox environment or flake
  it is imported into, through the same builder.
- `+` The pin, the builder and the runtime list change together, in
  the commit that moves the binary.
- `-` This lands together with the first pin to a binary carrying
  agent-stacks ADR 0079: such a binary refuses the hand-written
  `pkgs/agent-stacks`, and its builder takes formals the old flake did
  not pass.
- `-` Every package needs one replay with such a binary before it
  builds: a generated `source.json` without `defaultDependencies`
  fails, saying to re-import.
- `-` A hand-written `buildAgentPlugin` call that relied on the
  implicit defaults now passes `defaultDependencies` itself.
