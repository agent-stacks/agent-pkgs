# `mkAgentStack`

Composes agent plugins and one harness into a runnable stack.

```nix
mkAgentStack {
  name = "my-stack";
  harness = "claude";
  plugins = [ agent-plugin-foo agent-plugin-bar ];
}
```

Building that produces `bin/my-stack`. Running it starts the agent
through `flox-agent launch`, which reads the stack's
`share/agent-plugins` layout and stages the plugins in whatever shape
the agent expects. That staging is documented in the flox-agent repo,
`docs/architecture/launch.md`.

## Arguments

| Argument | Default | Meaning |
| ----------------- | -------- | ------- |
| `name` | required | Stack name, and the launcher's name. |
| `harness` | required | The agent to run. See below. |
| `plugins` | `[ ]` | Packages built by `buildAgentPlugin`. |
| `audit.tools` | defaults | Packages put on PATH by the audit script. |
| `audit.threshold` | `null` | Score below which the audit script fails. |
| `floxAgent` | this set's | The flox-agent the launcher and audit script run. |

## flox-agent

The launcher and the audit script run the `flox-agent` package the
stack was built against, so a stack carries its own agent in its
closure instead of requiring one on the consumer's PATH. Stacks built
from this repo get `pkgs/flox-agent`; pass `floxAgent` to bind a
different one.

`FLOX_AGENT_BIN` still overrides both scripts at run time, for running
a stack against a local build:

```sh
FLOX_AGENT_BIN=./flox-agent ./result/bin/my-stack
```

## The harness

A stack runs exactly one agent. Three ways to name it:

| Form | Example | Behaviour |
| ------- | ------- | --------- |
| String | `harness = "claude";` | Resolved from the consumer's PATH at run time. |
| Binary path (string) | `harness = "${claude-code}/bin/claude";` | Pinned; the launcher puts that directory first on PATH. |
| Package | `harness = claude-code;` | Pinned, using `meta.mainProgram` for the agent name. |

"Pinned" only guarantees a closure when the path is a Nix store
path, as `${claude-code}/bin/claude` is. An arbitrary filesystem
path, such as `harness = "/usr/local/bin/claude"`, is accepted the
same way but is not reproducible: nothing ties the launcher to a
particular closure at that location.

The agent is identified by the binary's basename, matched against
`knownAdapters` in `lib/mk-agent-stack.nix`, which mirrors the agents
`flox-agent launch` registers (`launch.RegisteredNames`, listed in the
flox-agent repo's `docs/architecture/launch.md`). Adding an agent
there means adding it here too. There is no table mapping package
names to agent names.

A package without `meta.mainProgram` is rejected: pass the binary
path instead. Reading the package's `bin/` during evaluation would
force it to build, which the repo does not do.

For several agents over the same plugins, build several stacks and
install them into one environment.

### The harness's runtime

A pinned harness brings its own runtime. The agent CLIs in this set
are single binaries — `claude-code` and `agent-deck` are compiled,
`codex` is Rust, `opencode` and `pi` carry the tools they shell out to
(`ripgrep`, `fzf`, `fd`) in their own closures — so pinning the
package pins everything it runs on. Nothing here has to name an
interpreter, and a stack built on one machine runs the same runtime on
a machine that has never seen one.

That is a property of the harness package, not of `mkAgentStack`,
which cannot see a closure at evaluation time. It is checked where it
can be: the launcher execs `flox-agent launch`, and that command warns
when the agent it resolved came from outside the Nix store. A pinned
stack is silent; an unpinned one says so on every run, naming the path
it found.

Two limits are deliberate:

- **An unpinned harness promises nothing.** `harness = "claude";` adds
  no PATH entry and puts no agent in the closure. The consumer's own
  `claude` runs, at whatever version they have. This is the
  convenient form, not the reproducible one, and is the wrong form
  for anything that has to run the same way twice.
- **PATH is prepended, not scrubbed.** The launcher puts the pinned
  harness first and leaves the rest of the consumer's PATH intact, so
  an agent that shells out to `git` — or to anything not in its own
  closure — gets the host's copy. That is the point of an agent: it
  works on the user's toolchain. It also means a stack's closure
  bounds the agent, not everything the agent can reach.

## Outputs

| Output | Contents |
| ------- | -------- |
| `out` | `share/agent-plugins/<plugin>/` for each plugin, plus `bin/<name>`. |
| `audit` | `bin/<name>-audit`. |

The stack carries no per-harness directories. Adapting plugins to
whatever the agent expects happens at launch, in `flox-agent launch`,
so a stack does not need rebuilding when that wiring changes.

The `audit` output is not built by default. Ask for it explicitly:

```sh
nix build .#my-stack^audit
./result-audit/bin/my-stack-audit
```

## What fails to evaluate

An invalid stack never builds:

- no `harness`
- a harness whose binary is not an agent flox-agent can launch
- a `plugins` entry that did not come from `buildAgentPlugin`
- two plugins with the same name
- a harness package without `meta.mainProgram`
- a `harness` that is a Nix path literal, a list, or a number rather than
  a name, a binary path written as a string, or a package

## Passthru

```nix
passthru.agentStack = {
  name;      # the stack's name
  adapter;   # the agent flox-agent will launch
  harness;   # the harness as given: a name, a binary path, or a package
  floxAgent; # the flox-agent package the scripts run, or null
  plugins;   # the plugin names in the stack
};
```

## Meta

```nix
meta = {
  description = "Agent stack ${name} (${adapter})";
  mainProgram = name;
  category = "agent-stack";
  platforms = lib.platforms.all;
};
```

`description` and `mainProgram` are derived from the stack's own
`name` and its resolved `adapter`, so they need no argument.
`category = "agent-stack"` marks the composed environment as its own
kind, distinct from `agent-plugin`, `agent` and `agent-tool` — a
stack is neither a plugin nor an agent, it is the two of them wired
together ([ADR 0014](../decisions/0014-generated-package-meta.md)).
`platforms = lib.platforms.all` for the same reason a plugin's does:
the stack's own files carry no architecture, and the harness and
plugins it composes bring their own platform lists.

## Stability

This is a public API. Nix users write it into their own repositories.
Argument names and meanings, and the output layout, do not change
without a deprecation period. New optional arguments may be added.
