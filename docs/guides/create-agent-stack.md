# Create an agent-stack package

How to create a reproducible agent-stack package. This guide uses the
`flox` plugin with 3 skills from
[create-agent-plugin.md](create-agent-plugin.md) and Claude Code as the
harness.

A stack is three things in one package: the plugins in the Agent
Plugins spec layout, one harness, and a launcher that configures the plugins to the
harness. Nothing in the agent stack itself is per-harness. The
adaptation happens at run time in `agent-stacks launch`. A stack
does not need to be rebuilt when that wiring changes. The full argument list is
[reference/mk-agent-stack.md](../reference/mk-agent-stack.md).

## Where the stack lives

Stacks are typically defined in a repository of your own. No
directory under `pkgs/` calls `mkAgentStack`. A stack is a reusable
composition: your harness, at the version you want, with the plugins
you happen to use for your team or organization. It could be relevant
for wider distribution as a reproducible way to use an agent.

The plugins are reusable, and they belong wherever
[create-agent-plugin.md](create-agent-plugin.md) says: this repo when
public, your own repo when not. A stack composes them from either — or
from both at once, since `plugins` is just a list of packages.

## Requirements

Nix with flakes. You do not need this repository checked out: a stack
is written in *your* flake, against `agent-pkgs` as an input.

## 1. Write the stack

`mkAgentStack` is exposed per system under the flake's `lib` output:

```nix
{
  inputs.agent-pkgs.url = "github:agent-stacks/agent-pkgs";

  outputs = { self, agent-pkgs }:
    let system = "aarch64-darwin";
    in {
      packages.${system}.flox-stack =
        agent-pkgs.lib.${system}.mkAgentStack {
          name = "flox-stack";
          harness = agent-pkgs.packages.${system}.claude-code;
          plugins = [ agent-pkgs.packages.${system}.agent-plugin-flox ];
        };
    };
}
```

`harness` is a package here, so the agent is pinned: the stack carries
that exact Claude Code in its closure and runs it regardless of what
the machine has installed. The agent CLIs re-exported into this set
are single binaries carrying their own runtimes, so pinning the
package pins everything it runs on. A package is resolved through
`meta.mainProgram`; one without it is rejected, and you pass
`"${claude-code}/bin/claude"` instead. To use an agent already on the
machine, see [Using a pre-installed harness](#using-a-pre-installed-harness).

`plugins` takes packages built by `buildAgentPlugin`: anything under
`pkgs/` in this repo, a plugin package in your own repository, or a
mix of the two. Passing something else fails to
evaluate rather than building a broken stack, as does a missing
`harness`, a duplicate plugin name, or an agent `agent-stacks` cannot
launch.

## 2. Build it

```sh
nix build .#flox-stack && readlink -f result
```

Two things in the output, and no per-harness directories:

```text
result/
├── bin/flox-stack                      # the launcher
└── share/agent-plugins/flox/           # the plugin, spec layout
    ├── plugin.json
    ├── skills/                         # flox, flox-debug, floxify
    └── bin/
```

## 3. Use the stack

Run it:

```sh
./result/bin/flox-stack
```

The agent starts with the stack's plugins already wired in. Nothing to
install, activate, configure or copy into a dotfile, and no
`agent-stacks` on your PATH. The binary in `result/bin` is the launcher.

Arguments reach the agent verbatim, so the quickest check that a stack
runs what it claims is:

```sh
./result/bin/flox-stack --version
```

```text
2.1.273 (Claude Code)
```

With a pinned harness that is the version the stack was built against,
on any machine, whatever the machine has installed.

### The launcher

`bin/flox-stack` is a five-line script, worth reading because it
explains the design:

```sh
export PATH="/nix/store/…-claude-code-2.1.273/bin:$PATH"
exec "${AGENT_STACKS_BIN:-/nix/store/…-agent-stacks-bin-…/bin/agent-stacks}" \
  --dir "/nix/store/…-agent-stack-flox-stack-0/share" \
  launch claude -- "$@"
```

The pinned harness goes on PATH first, so `launch claude` finds the
stack's Claude Code rather than the machine's. The stack also carries
its own `agent-stacks` in its closure rather than hoping the consumer
has one on PATH, points it at its own `share`, and names the agent.
Arguments you pass reach the agent verbatim — `./result/bin/flox-stack
--version` prints the pinned agent's version, which is the quickest
check that a stack runs what it says. `AGENT_STACKS_BIN` overrides the
pinned agent-stacks, which is how you run a stack against a local build.

Without a pinned harness that first line is absent, and the script is
four lines.

### What reaches the agent

`agent-stacks launch` stages the stack's plugins into whatever shape the
agent expects, into a per-run directory under `--config-dir`, and then
execs the agent pointed at it. Each adapter does that differently:

| Agent | How the skills arrive |
| ------------ | --------------------- |
| `claude` | `--plugin-dir <staged>/plugins/flox`, a tree with `.claude-plugin/plugin.json` and `skills/` |
| `pi` | `--skill <staged>/skills/flox` |
| `codex` | staged to `<staged>/skills/flox`, reached through the environment rather than a flag |
| `opencode` | staged to `<staged>/skills/flox`, same shape as codex |
| `agent-deck` | a seeded `config.toml` whose tool command is `agent-stacks launch claude --`, so it inherits claude's staging |

To see what a stack holds without launching anything:

```sh
agent-stacks --dir ./result/share doctor
```

```text
  Installed plugins: 1
  Skills: 3
```

## Using a pre-installed harness

Name the agent as a string instead of passing a package, and the
stack resolves it from PATH at run time:

```nix
harness = "claude";
```

This is the convenient form, not the reproducible one. It adds no
PATH entry and puts no agent in the closure, so whatever `claude` the
machine has is what runs. The launcher says so on every run:

```text
warning: claude resolved to /Users/you/.local/bin/claude, outside
/nix/store: this agent and the runtime it runs on come from the host,
so the same stack can behave differently on another machine
```

The drift risk is real: a machine with Claude Code 2.1.257 installed
runs 2.1.257 under this form, while the pinned stack above runs the
2.1.273 it was built against, on the same machine and from the same
flake.

Use it when you want the stack to follow an agent you update yourself,
or when the agent is not packaged here. Prefer a pinned package for
anything that has to run the same way twice, or on someone else's
machine.

Either way, PATH is prepended, not scrubbed. An agent that shells out
to `git` still gets the host's copy. A stack's closure bounds the
agent, not every binary the agent can reach.

## Update the stack

There is nothing to re-run. `mkAgentStack` is evaluated during `nix
build` rather than being a generator whose output you regenerate, so
the version your stack runs is not written into any file you edit — it
is decided by `flake.lock`, which pins `agent-pkgs` and through it the
harness package.

Read what you have now, without building:

```sh
nix eval --raw .#flox-stack.passthru.agentStack.harness.name
```

```text
claude-code-2.1.273
```

Adopt a newer one by updating that input and rebuilding:

```sh
nix flake update agent-pkgs
nix build .#flox-stack
./result/bin/flox-stack --version
```

Then commit the changed `flake.lock`. That is the whole upgrade, and
for everyone who consumes the stack it is the only thing that moved.
It moves the plugins as well as the harness, since both come from
`agent-pkgs`: a newer pin picks up every package re-imported since,
which is what makes this the stack's update rather than the agent's
alone.
`nix flake update` with no argument updates every input instead, which
also moves nixpkgs underneath the plugins.

The version you get this way is the one `agent-pkgs` pins, because the
agent CLIs are re-exported from
[llm-agents.nix](https://github.com/numtide/llm-agents.nix) through
it. When a harness release has not reached `agent-pkgs` yet, take it
from upstream directly:

```nix
inputs.llm-agents.url = "github:numtide/llm-agents.nix";
inputs.agent-pkgs.inputs.llm-agents.follows = "llm-agents";
```

`nix flake update llm-agents` then moves the harness on its own
schedule. The cost is that you build it yourself: agent-stacks' binary
cache holds what `agent-pkgs` pinned, not what you overrode it with.

A stack using a [pre-installed
harness](#using-a-pre-installed-harness) needs none of this. It
follows whatever the machine has, and `flake.lock` has no say in the
agent's version.

## Share a stack with others

A stack is a flake, so sharing one is sharing its repository. Commit
both files:

```sh
git add flake.nix flake.lock
git commit -m "flox-stack"
```

`flake.lock` is what makes this reproducible. It pins `agent-pkgs`,
and through it the plugins, the harness and the agent-stacks the
launcher runs. Without it a consumer resolves those inputs afresh and
can build a different stack than you did.

On the other machine, Nix with flakes and git are the only
prerequisites — not Flox, not `agent-stacks`, not the agent itself when
the harness is pinned:

```sh
git clone <repo-url>
cd <repo>
nix build .#flox-stack
./result/bin/flox-stack
```

Those three commands are the entire setup, and they produce the same
store path you built from, because the lock and the pinned harness
leave nothing to resolve.

Building the harness from source is the slow part. agent-pkgs
publishes prebuilt packages, so point Nix at its cache to skip that:

```sh
nix build .#flox-stack \
  --extra-substituters https://cache.agent-stacks.org \
  --extra-trusted-public-keys agent-stacks-1:RWT4eI3clOY7jhOzIQNTyXL1Z8yQpN3KlNvvPMfFCRk=
```

Consumers who will run this more than once should put those two
settings in `nix.conf` instead; the
[README](../../README.md#binary-cache) has both forms.

## The audit output

Not built by default. Ask for it explicitly:

```sh
nix build .#flox-stack^audit
./result-audit/bin/flox-stack-audit
```

The audit script needs its tools on PATH; `doctor` lists which are
missing and which audits they gate.

## Several agents

A stack runs exactly one agent. For several agents over the same
plugins, build multiple stacks.

## Where the details live

| Question | Page |
| -------- | ---- |
| Every `mkAgentStack` argument, and what fails to evaluate | [reference/mk-agent-stack.md](../reference/mk-agent-stack.md) |
| Creating the plugins a stack carries | [create-agent-plugin.md](create-agent-plugin.md) |
| What the builder produces | [reference/build-agent-plugin.md](../reference/build-agent-plugin.md) |
| How staging works per agent | [agent-stacks `docs/architecture/launch.md`](https://github.com/agent-stacks/agent-stacks-cli/blob/main/docs/architecture/launch.md) |
