# 0019. Harness packages run through `agent-stacks launch`

Date: 2026-10-09

Status: Proposed

## Context

AI-570 promises that typing `claude` in an activated environment
starts it with the environment's plugins, with no wiring command and
nothing to set up. Until now a user had to type `agent-stacks launch
claude`; plain `claude` ran the re-exported package (ADR 0008) and got
no plugins.

A spike on 2026-10-08 (Flox 1.17.0, macOS) tried four ways to put a
wrapper in front of the program:

- **The harness package is the wrapper.** Plain `claude` went through
  launch in `flox activate -- cmd` and in interactive zsh and bash.
- **A package's `etc/profile.d` puts a wrappers folder on PATH.** Flox
  sources it (since 1.15.0), but interactive shells re-sort PATH after
  the user's rc files, so the environment's own `bin/claude` wins.
- **A separate wrapper package next to the harness.** Two packages
  providing `bin/claude` conflict, and a catalog package cannot set its
  own priority; only the user's manifest can.
- **A manifest hook that writes the wrapper.** A setup step in every
  manifest, which AI-570 rules out.

Launch hands Claude its plugins in `CLAUDE_CODE_PLUGIN_DIRS`
(agent-stacks-cli AI-1011), not flags in front of the user's arguments,
so a subcommand typed through the wrapper stays a subcommand.

## Decision

We will ship the agents named in `mappings/harnesses.nix` as packages
whose own program runs through `agent-stacks launch`. `lib/wrap-harness.nix`
builds one from the re-exported package: `bin/<program>` is a script
that runs launch for that agent, the real program sits under
`libexec/agent-stacks/<adapter>/bin`, and everything else the package
ships is linked unchanged. The CLI it runs is this set's `agent-stacks`,
by store path.

- The wrapper puts the real program first on PATH before calling
  launch, so launch's lookup finds the real one, not the wrapper.
- It runs the real program directly when `AGENT_STACKS=1` is set, which
  launch sets for the agent it starts, so a stack's launcher or an
  explicit `agent-stacks launch` never launches twice.
- `AGENT_STACKS_OFF=1` runs the real program directly, for a user who
  wants it unwrapped.
- It sets `AGENT_STACKS_WRAPPED=1`, and launch then skips its "no
  plugins found" warning: a plain `claude` in an environment with no
  plugins is ordinary.

The list starts with `claude-code` and `opencode`, the agents launch
hands plugins to without touching the user's arguments. pi waits until
launch stops putting `--skill` flags in front of them; codex waits for
the flox-patched build (AI-1012).

## Consequences

- `+` A plain `claude` or `opencode` in an environment gets its
  plugins, in every way a shell is started, with nothing to set up.
- `+` Outside an environment nothing changes: the wrapper exists only
  inside it.
- `+` The wrapper is a small derivation over the re-exported package,
  so the agent itself is still the cached upstream build.
- `-` These packages are no longer exactly what llm-agents.nix
  publishes. `passthru.unwrapped` is the upstream package.
- `-` Each wrapped agent depends on this set's `agent-stacks`, so a
  launch fix reaches users only when that pin moves. The pin today,
  0.9.0-22, still passes `--plugin-dir`; it must move past AI-1011
  before this ships.
- `-` Every launch is a staging step before the agent starts. It is
  small, and it is the cost AI-569 accepted.
