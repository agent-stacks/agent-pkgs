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
  plugins;   # the plugin names in the stack
};
```

## Stability

This is a public API. Nix users write it into their own repositories.
Argument names and meanings, and the output layout, do not change
without a deprecation period. New optional arguments may be added.
