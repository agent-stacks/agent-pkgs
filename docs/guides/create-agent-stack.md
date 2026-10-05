# Create an agent-stack package

Agents configured by hand tend to drift over time. One machine has a
newer Claude Code, another is missing the `python3` that a skill's
script needs, and a third has an older version of a plugin. The 
solution is to define all of these dependencies as an agent stack.
An agent stack is the harness, plugins, and runtimes, built as a
single package that runs the same on every machine.

This guide builds the following agent stack from scratch:

- Claude Code as the harness
- The `caveman` plugin and its 20 skills

By the end, you'll have a launcher that starts Claude Code with those
skills wired in. To share this stack with someone else on your team,
just push it to a Git repository.

## Prerequisites

You need Nix (with flakes enabled) and git. The
[README](../../README.md#prerequisites) shows how to enable flakes.
You do _not_ need to clone this repository or have Claude Code
pre-installed.

## 1. Create a directory

Let's create a new directory and initialize it with `git`:

```sh
mkdir caveman-stack && cd caveman-stack
git init
printf 'result\n.agent-stacks/\n' > .gitignore
```

NOTE: The `.gitignore` prevents the build's `result` link and the
launcher's staging directory from being committed.

## 2. Write the stack

Save the following code as `flake.nix` in that directory:

```nix
{
  inputs.agent-pkgs.url = "github:agent-stacks/agent-pkgs";

  outputs = { self, agent-pkgs }:
    let system = "aarch64-darwin"; # or "x86_64-linux", "aarch64-linux"
    in {
      packages.${system}.caveman-stack =
        agent-pkgs.lib.${system}.mkAgentStack {
          name = "caveman-stack";
          harness = agent-pkgs.packages.${system}.claude-code;
          plugins = [ agent-pkgs.packages.${system}.agent-plugin-caveman ];
        };
    };
}
```

NOTE: Set `system` to match your machine. To see your current system,
run `nix eval --raw --impure --expr builtins.currentSystem`.

This flake names one harness and one plugin, both packages from
`agent-pkgs`. If you already have Claude Code installed and want the
stack to run that one, write `harness = "claude";` instead; the rest
of this guide is the same, see [Using a pre-installed harness](#using-a-pre-installed-harness) for more details.

Next, stage the file with `git` (Nix won't build an untracked flake
in a git repository):

```sh
git add flake.nix
```

## 3. Build it

```sh
nix build .#caveman-stack
```

The first build takes a couple of minutes, because Nix fetches the
harness, the plugin and all of their dependencies. Later builds are
much faster because they reuse what is already in the Nix store. If 
enabled, the [binary cache](../../README.md#binary-cache) can speed
up the first build by downloading pre-built packages of the harness
and plugins.

The build writes `flake.lock`, which records the exact versions of
packages it used, and leaves a `result` link to the stack:

```text
result/
├── bin/caveman-stack                   # the launcher
└── share/agent-plugins/caveman/        # the plugin, spec layout
    ├── plugin.json
    ├── skills/                         # 20 skills: caveman, cavecrew, …
    └── bin/                            # python3
```

Commit the stack and its lock file:

```sh
git add .gitignore flake.nix flake.lock
git commit -m "caveman-stack"
```

## 4. Run it

```sh
./result/bin/caveman-stack
```

The agent starts with the stack's plugins already wired in. You don't
need to install, activate, configure or copy anything into a dotfile,
and you don't need `agent-stacks` on your PATH. The binary in
`result/bin` is the launcher.

Type `/caveman:` at the prompt to see the skills from your stack.
There should be 20 skills in the plugin, including `/caveman:caveman`.

Alternatively, you can pass arguments to the launcher from the command
line directly:

```sh
./result/bin/caveman-stack plugin list
```

```text
  ❯ caveman@inline
    Version: unknown
    Path: …/.agent-stacks/launch/claude/…/plugins/caveman
    Status: ✔ loaded
```

Passing arguments to the launcher is also a good way to confirm that
the harness version is correct.

```sh
./result/bin/caveman-stack --version
```

```text
2.1.284 (Claude Code)
```

NOTE: `agent-pkgs` follows upstream daily, so the version depends on
whatever `flake.lock` contains from when it was locked. The benefit
is that with a pinned harness you can have confidence that every machine
will have the same experience, regardless of what's installed locally.

## 5. Update the stack

A pinned stack stays on the versions it was locked to until you move
it. That is what makes it reproducible, but it also means that stacks 
need to be periodically updated to prevent them from falling behind
upstream.

`mkAgentStack` is evaluated during `nix build`, so the version your
stack runs is decided by `flake.lock`, which pins `agent-pkgs` and
through it the harness package.

To see the version of the harness in your stack:

```sh
nix eval --raw .#caveman-stack.passthru.agentStack.harness.name
```

```text
claude-code-2.1.284
```

Update to a newer harness by updating that input and rebuilding:

```sh
nix flake update agent-pkgs
nix build .#caveman-stack
./result/bin/caveman-stack --version
```

Then commit the changed `flake.lock`:

```sh
git commit -m "update agent-pkgs" flake.lock
```

That's the whole upgrade! It moves the plugins as well as the
harness, since both come from `agent-pkgs`: a newer pin picks up every
package re-imported since, which is what makes this the stack's update
rather than the agent's alone. `nix flake update` with no argument
updates every input instead, which also moves nixpkgs underneath the
plugins.

The versions you get are the ones `agent-pkgs` pins, because the
agent CLIs are re-exported from
[llm-agents.nix](https://github.com/numtide/llm-agents.nix). When a
harness update has not reached `agent-pkgs` yet, you can get it
from upstream directly:

```nix
inputs.llm-agents.url = "github:numtide/llm-agents.nix";
inputs.agent-pkgs.inputs.llm-agents.follows = "llm-agents";
```

`nix flake update llm-agents` then moves the harness on its own
schedule. The cost is that you build it yourself: agent-stacks' binary
cache only contains the versions that `agent-pkgs` pinned.

In contrast, a stack using a [pre-installed
harness](#using-a-pre-installed-harness) uses whatever harness
is already installed on the machine; `flake.lock` doesn't determine
the harness version in this case.

## 6. Share it with others

A stack is a flake, so sharing one means sharing its repository. Push
the repository somewhere the people you are sharing with can clone it.

`flake.lock` is what makes this reproducible. It pins `agent-pkgs`,
and through it the plugins, the harness and the agent-stacks the
launcher runs. Without it a consumer resolves those inputs afresh and
can build a different stack than you did.

After someone clones the repository, Nix with flakes and git are the
only prerequisites. Neither `agent-stacks` nor the agent itself has
to be installed when the harness is pinned:

```sh
git clone <repo-url>
cd <repo>
nix build .#caveman-stack
./result/bin/caveman-stack
```

This produces the same store path you built from, because the lock
and the pinned harness leave nothing to resolve.

Building the harness is the slow part. agent-pkgs publishes prebuilt
packages, and anyone who will build the stack more than once should
point Nix at its cache: see the
[README](../../README.md#binary-cache) for more details.

## Clean up

When you're done with the stack, delete the directory:

```sh
cd .. && rm -rf caveman-stack
```

That removes the repository, the `result` link and the launcher's
staging directory. The stack's packages stay in the Nix store with
nothing referring to them, and `nix store gc` reclaims those along
with everything else in the store that is unreferenced.

## Variations

### Using a pre-installed harness

Name the agent as a string instead of adding the harness to the stack
itself. When you launch the stack, it will use PATH to find your
existing harness:

```nix
harness = "claude";
```

Note that this approach is not as reproducible. Without a harness in
the closure, you're reliant on whatever `claude` is pre-installed. You'll 
see the following warning every time you launch the stack:

```text
warning: claude resolved to /Users/you/.local/bin/claude, outside
/nix/store: this agent and the runtime it runs on come from the host,
so the same stack can behave differently on another machine
```

This approach can make sense when you want the stack to use an agent you
update yourself. Prefer a pinned package for anything that has to run the
same way every time on any machine.

Either way, PATH is prepended, not scrubbed. An agent that shells out
to `git` still gets the host's copy. A stack's closure bounds the
agent, not every binary the agent can reach.

### Several agents

A stack runs exactly one agent. For several agents over the same
plugins, build multiple stacks. We may change this limitation in
the future, please reach out if this is something you need!

### The audit output

Not built by default. Ask for it explicitly:

```sh
nix build .#caveman-stack^audit
./result-audit/bin/caveman-stack-audit
```

The audit script needs its tools on PATH; `doctor` lists which are
missing and which audits they gate.

## How it works

A stack is three things in one package: the plugins in the Agent
Plugins spec layout, one harness, and a launcher that wires the
plugins into the harness. The adaptation happens at run time in
`agent-stacks launch`. A stack does not need to be rebuilt when that
wiring changes. See [mkAgentStack](../reference/mk-agent-stack.md)
for the full argument list.

### Where the stack lives

Stacks are typically defined in a repository of your own. No
directory under `pkgs/` calls `mkAgentStack`. A stack is a reusable
composition: your harness, at the version you want, with the plugins
you happen to use for your team or organization.

The plugins are reusable, and they belong wherever
[Create an agent-plugin package](create-agent-plugin.md) says: this repo when
public, your own repo when not.

### Where the harness and the plugins come from

A stack composes two kinds of package, and both are attributes of
`agent-pkgs.packages.<system>`, so an input is all you need to reach
either.

**The harness comes from
[numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix)**,
which packages roughly 170 agent CLIs and updates daily. This set
rebuilds them against the nixpkgs it pins and re-exports them under
their own names, with no prefix, so `claude-code`, `codex` and
`opencode` are attributes of `agent-pkgs.packages.<system>` directly
([ADR 0008](../decisions/0008-re-export-llm-agents-nix.md)). Nothing
here packages an agent itself.

Being packaged is not enough to be a harness, though: a stack's agent
has to be one `agent-stacks launch` has an adapter for, which
currently means one of the following:

| Package | Adapter |
| ------------- | ------- |
| `claude-code` | `claude` |
| `codex` | `codex` |
| `opencode` | `opencode` |
| `pi` | `pi` |
| `agent-deck` | `agent-deck` |

The adapter is the basename of the package's `meta.mainProgram`, which
is why `claude-code` resolves to `claude`. Any other agent fails to
evaluate. For example, naming `gemini-cli` gives this error:

```text
error: mkAgentStack: 'gemini' is not an agent agent-stacks
can launch. Known agents: agent-deck, claude, codex, opencode, pi
```

**The plugins are packaged here**, under `pkgs/`, one directory per
plugin named `agent-plugin-<name>` — a couple hundred of them,
generated by `agent-stacks import` from upstream skills repositories.
They are attributes of the same set, which is where
`agent-pkgs.packages.<system>.agent-plugin-caveman` in the flake comes
from. If the skills you want are not packaged yet,
see [Create an agent-plugin package](create-agent-plugin.md) for more
details on how to add one. A plugin package in your repository is
composed in exactly the same way.

To find either kind of package, search the flake:

```sh
nix search github:agent-stacks/agent-pkgs claude-code
```

That prints matching attribute paths with their versions and
descriptions. It evaluates the whole set, so give it a moment. In a
checkout, `ls pkgs/` is the quicker way to see which plugins exist.

### What the flake says

`mkAgentStack` comes from the `agent-pkgs` input's `lib` output,
exposed per system.

`harness` is a package here, so the agent is pinned: the stack carries
that exact Claude Code in its closure and runs it regardless of what
the machine has installed. The agent CLIs re-exported into this set
are single binaries carrying their own runtimes, so pinning the
package pins everything it runs on. A package is resolved through
`meta.mainProgram`; one without it is rejected, and you pass
`"${claude-code}/bin/claude"` instead.

`plugins` takes packages built by `buildAgentPlugin`: anything under
`pkgs/` in this repo, a plugin package in your own repository, or a
mix of the two. Passing something else fails to
evaluate rather than building a broken stack, as does a missing
`harness`, a duplicate plugin name, or an agent `agent-stacks` cannot
launch.

### The launcher

`bin/caveman-stack` is a very small script, worth reading because it
explains how the launcher works:

```sh
export PATH="/nix/store/…-claude-code-…/bin:$PATH"
exec "${AGENT_STACKS_BIN:-/nix/store/…-agent-stacks-bin-…/bin/agent-stacks}" \
  --dir "/nix/store/…-agent-stack-caveman-stack-0/share" \
  launch claude -- "$@"
```

The pinned harness goes on PATH first, so `launch claude` finds the
stack's Claude Code rather than the machine's. The stack also carries
its own `agent-stacks` in its closure rather than hoping the consumer
has one on PATH, points it at its own `share`, and names the agent.
Arguments you pass reach the agent verbatim — `./result/bin/caveman-stack
--version` prints the pinned agent's version. `AGENT_STACKS_BIN` overrides the
pinned agent-stacks, which is how you run a stack against a local build.

Without a pinned harness that first line is absent.

### What reaches the agent

`agent-stacks launch` stages the stack's plugins into whatever shape the
agent expects, into a per-run directory under `--config-dir`, and then
execs the agent pointed at it. Each adapter does that differently:

| Agent | How the skills arrive |
| ------------ | --------------------- |
| `claude` | `--plugin-dir <staged>/plugins/caveman`, a tree with `.claude-plugin/plugin.json` and `skills/` |
| `pi` | `--skill <staged>/skills/caveman` |
| `codex` | staged to `<staged>/skills/caveman`, reached through the environment rather than a flag |
| `opencode` | staged to `<staged>/skills/caveman`, same shape as codex |
| `agent-deck` | a seeded `config.toml` whose tool command is `agent-stacks launch claude --`, so it inherits claude's staging |

To see what a stack holds without launching anything, run the
`agent-stacks` from this repo against the stack's `share`. The stack
carries its own copy for the launcher but does not put it on your PATH,
so reach for it through `nix run`:

```sh
nix run github:agent-stacks/agent-pkgs#agent-stacks -- \
  --dir ./result/share doctor
```

```text
  Installed plugins: 1
  Skills: 20
```

## Where the details live

| Question | Page |
| -------- | ---- |
| Every `mkAgentStack` argument, and what fails to evaluate | [reference/mk-agent-stack.md](../reference/mk-agent-stack.md) |
| Creating the plugins a stack carries | [create-agent-plugin.md](create-agent-plugin.md) |
| What the builder produces | [reference/build-agent-plugin.md](../reference/build-agent-plugin.md) |
| How staging works per agent | [agent-stacks `docs/architecture/launch.md`](https://github.com/agent-stacks/agent-stacks-cli/blob/main/docs/architecture/launch.md) |
