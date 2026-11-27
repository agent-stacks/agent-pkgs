# Create an agent stack with Flox

[Create an agent-stack package](create-agent-stack.md) builds an agent
stack as a Nix flake. The Flox CLI makes the same kind of stack with
no flake to write: a Flox environment that installs a harness, its
plugins, and the launcher that wires them together. You push it to
FloxHub, and anyone with access runs it on their own machine with a
single `flox activate`.

This guide builds the following agent stack from scratch:

- Claude Code as the harness
- The `caveman` plugin and its skills

By the end, you'll have a stack on FloxHub that starts Claude Code
with those skills wired in, in whatever project folder you run it
from.

## Prerequisites

You need Flox 1.17 or later and a FloxHub account. 1.17 is the first
release that reads the `description` in step 3. Install Flox from
<https://flox.dev/docs/install-flox/install/>, then log in:

```sh
flox auth login
```

You do _not_ need Nix, a clone of this repository, or Claude Code
pre-installed.

## 1. Create an environment

Let's create a new directory and initialize a Flox environment in it:

```sh
mkdir caveman-stack && cd caveman-stack
flox init
```

`flox init` writes the environment to a `.flox` directory and names it
after the directory you ran it in, so this stack is `caveman-stack`.
That name is how you'll refer to the stack once it's on FloxHub.

## 2. Install the packages

```sh
flox install flox/flox-agent agent-stacks/claude-code agent-stacks/agent-plugin-caveman
```

```text
✔ 'flox-agent', 'claude-code', 'agent-plugin-caveman' installed to environment 'caveman-stack'
```

All three come from the Flox catalog, and each is one part of the
stack:

| Part | Package | Notes |
| ---- | ------- | ----- |
| The launcher | `flox/flox-agent` | Required. Its `flox-agent launch` starts the harness with the stack's plugins wired in. |
| The harness | `agent-stacks/claude-code` | The agent the stack runs. See [Another harness](#another-harness) for the others. |
| Plugins | `agent-stacks/agent-plugin-<name>` | Any number. `flox search agent-plugin --all` lists them. |

The plugins are the `agent-plugin-<name>` packages under this repo's
`pkgs/`, published to the catalog under `agent-stacks/`. A plugin that
isn't in the catalog can be installed from a flake instead, the way
[the sandbox](#run-the-agent-in-a-sandbox) is.

To see what you installed, and at which versions:

```sh
flox list
```

```text
agent-plugin-caveman: agent-stacks/agent-plugin-caveman (4.0.1)
claude-code: agent-stacks/claude-code (2.1.300)
flox-agent: flox/flox-agent (0.9.0-293-g8764bc5)
```

NOTE: The versions are whatever the catalog had when you ran `flox
install`. The environment's lock file, `.flox/env/manifest.lock`,
records them, so every machine that activates the stack gets the same
ones. It does the job that `flake.lock` does for a Nix stack.

## 3. Describe it

A `description` tells people what the stack is for. Run `flox edit` to
open the manifest in your editor, and add one at the top, under
`schema-version`:

```toml
schema-version = "1.19.0"
description = "Claude Code with the caveman skills"
```

Leave `schema-version` as `flox init` wrote it. Flox 1.19 writes
`1.19.0`; `description` needs `1.17.0` or later. When you save and
close the editor, Flox checks the manifest and applies it.

The first line of the description is the summary that `flox envs`
shows under the environment's name:

```text
  caveman-stack    /home/you/caveman-stack
    Claude Code with the caveman skills
```

FloxHub shows the description too, and an interactive `flox activate`
prints all of it, rendered as Markdown.

## 4. Try it

Before you push anything, check the stack on your own machine.
`flox-agent list` shows what the launcher will give each harness,
without starting one:

```sh
flox activate -- flox-agent list
```

```text
Agent stack
1 harness · 1 plugin · 22 skills · 0 MCP servers

Harnesses
 ✔ claude    claude-code 2.1.300 · skills, MCP, hooks

Plugins
 ✔ caveman   agent-plugin-caveman 4.0.1 · 22 skills
```

`flox activate -- <command>` runs one command inside the environment.
Now start Claude Code with the stack:

```sh
flox activate -- flox-agent launch claude
```

`flox-agent launch claude` stages the stack's plugins and starts
Claude Code with them. Before the agent starts, the launcher prints a
`note:` line for each hook a plugin asks Claude Code to run, so you can
see what will execute. caveman has four.

Type `/caveman:` at the prompt to see the skills from your stack.

Arguments after a second `--` reach the agent verbatim, which is a
quick way to check the stack without starting a session:

```sh
flox activate -- flox-agent launch claude -- plugin list
```

```text
Session-only plugins (--plugin-dir / --plugin-url):

  ❯ caveman@inline
    Version: unknown
    Path: …/caveman-stack/.flox/cache/agent-stacks/launch/claude/…/plugins/caveman
    Status: ✔ loaded
```

```sh
flox activate -- flox-agent launch claude -- --version
```

```text
2.1.300 (Claude Code)
```

The agent works in the folder you start it from. To try the stack on
a project, start from that project and point `-d` at the stack's
directory:

```sh
cd /path/to/your/project
flox activate -d /path/to/caveman-stack -- flox-agent launch claude
```

## 5. Push it to FloxHub

From the stack's directory:

```sh
flox push
```

The first push creates the stack on FloxHub as
`<owner>/caveman-stack`, where `<owner>` is your FloxHub username, and
links this directory to it. FloxHub keeps each push as a new
generation of the stack.

Whether a pushed stack is public or private depends on the FloxHub
account's default. Anyone can activate a public stack by name, so keep
secrets such as API keys out of the manifest.

To share the stack with a team, push it to a FloxHub
[organization](https://flox.dev/docs/concepts/organizations/) instead.
Its members can then activate `<org>/caveman-stack`:

```sh
flox push --owner <org>
```

`--owner` only works on a stack's first push.

## 6. Run it from FloxHub

On any machine with Flox (macOS on Apple silicon, or Linux), start
the stack from the project folder you want the agent to work in:

```sh
cd /path/to/your/project
flox activate -r <owner>/caveman-stack -- flox-agent launch claude
```

`-r` activates a FloxHub environment by name. There is nothing to
clone or install first. The first activation fetches the stack's
packages, at the versions its lock file records, and later activations
reuse them. A private stack needs `flox auth login` first.

Arguments after a second `--` reach the agent here too:

```sh
flox activate -r <owner>/caveman-stack -- flox-agent launch claude -- --version
```

Flox always trusts the environments you own. The first time you
activate a stack someone else owns, Flox asks whether to trust it,
because activating an environment can run its hook. Where there is
nobody to answer, as in a script, the activation fails with `The
environment <owner>/caveman-stack is not trusted`. Pass `--trust` to
trust the stack for that one activation:

```sh
flox activate -r <owner>/caveman-stack --trust -- flox-agent launch claude
```

NOTE: The launcher stages the plugins under `.flox/cache/agent-stacks`
in the folder you start from. In a folder with no Flox environment of
its own, that `.flox` directory makes a later `flox init` there fail.
Remove it when you're done (see [Clean up](#clean-up)), or pass
`--config-dir` to stage somewhere else:
`flox-agent --config-dir ~/.cache/agent-stacks launch claude`.

## 7. Update the stack

A stack stays on the versions its lock file records until you move it.
That is what makes it reproducible, but it also means a stack needs
updating now and then to keep up with its harness and plugins. From
the stack's directory:

```sh
flox upgrade
flox list
flox push
```

`flox upgrade` moves every package to the newest version in the
catalog, and `flox list` shows the versions you have now. Any other
change works the same way: `flox install agent-stacks/agent-plugin-<name>`
adds a plugin, `flox uninstall` removes one, and `flox edit` changes
the manifest. Each `flox push` publishes the change as a new
generation.

`flox activate -r` runs the copy of the stack that Flox cached on that
machine, which can be behind FloxHub. To run the newest generation,
pull it first:

```sh
flox pull -r <owner>/caveman-stack
```

## Clean up

When you're done with the local stack, delete its environment and the
directory:

```sh
cd .. && flox delete -d caveman-stack && rmdir caveman-stack
```

Once the stack is pushed, `flox delete` only removes the directory's
link to it, and the stack stays on FloxHub. Delete it from its page on
[FloxHub](https://hub.flox.dev/) to remove it there.

In each project folder you started the stack from with `-r`, remove
the launcher's staging directory:

```sh
rm -rf .flox/cache/agent-stacks
```

If the project has no Flox environment of its own, also remove the
empty directories that are left with `rmdir .flox/cache .flox`.

The stack's packages stay in the Nix store that Flox manages, and
`flox gc` reclaims the ones that deleted environments no longer use.

## Variations

### Run the agent in a sandbox

[`agent-sandbox-nono`](../../pkgs/agent-sandbox-nono/default.nix) runs
the agent inside [nono](https://github.com/nolabs-ai/nono): Seatbelt
on macOS, Landlock on Linux. The project folder is writable,
credentials such as `~/.ssh` are hidden, and the network stays open.
It isn't in the Flox catalog, so install it from this repository's
flake:

```sh
flox install 'github:agent-stacks/agent-pkgs#agent-sandbox-nono'
```

Then name it at launch. `--sandbox` goes between `launch` and the
agent's name:

```sh
flox activate -- flox-agent launch --sandbox nono claude
```

```text
agent-sandbox-nono: running claude inside nono
```

The sandbox refuses to start in `/` or your home directory, where the
writable project folder would be everything. `--sandbox-options`
passes it a JSON object, also before the agent's name. For example,
`allowedDomains` closes the network to all but Claude's hosts, the
hosts of the plugins' MCP servers, and the domains you list:

```sh
flox activate -- flox-agent launch --sandbox nono \
  --sandbox-options '{"allowedDomains": ["example.com"]}' claude
```

The top of its [`default.nix`](../../pkgs/agent-sandbox-nono/default.nix)
describes every option.

### Another harness

The catalog carries these harnesses, each launched by its own name:

| Package | Launch it with |
| ------- | -------------- |
| `agent-stacks/claude-code` | `flox-agent launch claude` |
| `agent-stacks/codex` | `flox-agent launch codex` |
| `agent-stacks/opencode` | `flox-agent launch opencode` |
| `agent-stacks/pi` | `flox-agent launch pi` |

Unlike a Nix stack, an environment can install more than one harness;
you name the one to start. Run `flox-agent list` after installing one,
because it says what each harness gets. Claude Code gets skills, MCP
servers and hooks, while codex, opencode and pi get skills only. A
harness that can't take the plugins at all is flagged:

```text
 ⚠ codex      codex 0.162.1 · skills only
              codex is not the flox-patched build; skills will not be injected
```

### Using a pre-installed harness

Leave the harness package out of the stack:

```sh
flox install flox/flox-agent agent-stacks/agent-plugin-caveman
```

`flox-agent launch claude` then runs the `claude` on your PATH, and
`flox-agent list` says the stack has no harness of its own:

```text
Harnesses
 No harness in this environment. Install one: flox install agent-stacks/claude-code
```

This approach is not as reproducible: the stack runs whatever Claude
Code each machine has installed. It can make sense when you want the
stack to use an agent you update yourself. Prefer the harness package
for anything that has to run the same way on every machine.

## How it works

Each plugin package installs its plugin under
`share/agent-plugins/<name>/`, in the Agent Plugins spec layout, so in
an activated environment every plugin sits under
`$FLOX_ENV/share/agent-plugins/`. The harness package puts the agent on
PATH. `flox-agent launch claude` reads `$FLOX_ENV/share`, stages the
plugins in the shape the agent expects, and starts the agent pointed
at them. It stages under `.flox/cache/agent-stacks` in the
environment's project directory, `$FLOX_ENV_PROJECT`. That is the
stack's own directory for a local stack, and the folder you start from
with `-r`.

`flox-agent` is the catalog name for `agent-stacks`, the same program
a Nix stack's launcher execs, so a Flox stack and a Nix stack stage
their plugins the same way
([ADR 0010](../decisions/0010-stack-launcher-reuses-flox-agent-launch.md)).
[What reaches the agent](create-agent-stack.md#what-reaches-the-agent)
shows how each harness receives them. What differs is how the stack
is made and shared: here the Flox catalog supplies the packages and
FloxHub carries the stack; there a flake pins the packages and a Git
repository carries it.

## Where the details live

| Question | Page |
| -------- | ---- |
| Making a stack with a Nix flake instead | [create-agent-stack.md](create-agent-stack.md) |
| Creating the plugins a stack carries | [create-agent-plugin.md](create-agent-plugin.md) |
| Every manifest field, including `description` | [Flox manifest reference](https://flox.dev/docs/reference/command-reference/manifest.toml/) |
| How FloxHub copies, pulls and activations relate | [FloxHub environments](https://flox.dev/docs/concepts/floxhub-environments/) |
