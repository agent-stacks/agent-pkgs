# 0010. A stack's launcher execs `flox-agent launch`

Date: 2026-09-14

Status: Accepted

## Context

A stack has to put its plugins where the agent will find them. Every
agent expects a different shape, and none of them expects
`share/agent-plugins/`, which is the layout this set builds
(ADR 0005).

That translation already exists. `flox-agent launch` reads the
canonical layout and stages it into whatever the agent wants, just in
time, and it is the path a user on the Flox side already takes.

The alternative was for `mkAgentStack` to do its own staging in Nix.
It is a real option: it would keep a stack independent of the CLI, and
a builder that only emits a directory tree needs no runtime tool. It
was rejected.

## Decision

**`mkAgentStack` writes a launcher that execs `flox-agent launch`.**
The stack bakes no per-harness trees; it ships the canonical layout
and defers the shape to launch time.

One mechanism serves both doors. A Flox user activating an environment
and a Nix user running a stack's launcher get the same staging, from
the same code, because there is only one implementation of it.

A second implementation in Nix would have to track every agent's
layout independently, and would drift — agents change their
expectations without warning, and the two copies would disagree about
a plugin's shape with no test that compares them. The failure would be
silent: a plugin staged one way for one door and another way for the
other.

## Consequences

- `+` One staging implementation. A fix for an agent's layout reaches
  Flox users and Nix users in the same release.
- `+` A stack is a thin package: a launcher, the canonical layout, and
  the plugins. Nothing per-harness is baked, so adding an agent does
  not rebuild every stack.
- `+` `flox-agent launch` is where agent support is declared, so the
  set of agents a stack can name is exactly the set launch registers
  (ADR 0007).
- `-` Staging happens on every launch rather than once at build time.
  It is cheap — copying and linking a tree — but it is not free, and
  it is not captured in the closure.
