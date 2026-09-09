# 0007. One harness per stack, detected from the binary

Date: 2026-09-02

Status: Accepted

## Context

A stack has to name the agent it runs. The original design specified
a list of harnesses, so that one stack could serve Claude, Codex and
an OSS agent at once, and nobody sharing the stack would be pushed
onto a particular agent.

Two things pull the other way. The stack's launcher is a single
binary named after the stack, and with several harnesses it has no
unambiguous meaning. And a list invites a mapping from package names
to agent names, because `claude-code` the package provides `claude`
the binary.

## Decision

A stack takes exactly one `harness`, given as a string resolved from
PATH, or as a path or package that pins it along with its own
runtime. The agent is identified by the binary's basename, matched
against the agents `flox-agent launch` supports. Package harnesses
resolve through `meta.mainProgram`; a package without one is an
evaluation error asking for the binary path, because listing a
package's `bin/` during evaluation is import from derivation.

Several agents over the same plugins means several stacks in one
environment, which is consistent with a stack being an environment
and needing no new file format.

## Consequences

- `+` The launcher is unambiguous: `my-stack` runs one thing.
- `+` No mapping table between package names and agent names, and no
  build forced during evaluation.
- `+` Pinning the harness pins its runtime with it, per stack.
- `-` Amends the original design, which describes a list.
- `-` Three stacks over the same plugins duplicate the plugin copies
  in three store paths.
