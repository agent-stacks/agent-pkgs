# agent-pkgs documentation

`agent-pkgs` is the Nix package set for Agent Plugins and Agent
Stacks: skills and MCP server configurations packaged as reproducible
Nix packages. A package is closure-complete for the interpreters its
files name — a skill whose scripts are invoked from prose, or whose
scripts need language-level libraries (a Python package, `ffmpeg`),
is not, and its `source.json`'s `import.warnings` says which.

| Tree | Start here | What it answers |
| ------------ | ---------------------------------------------- | --------------- |
| Guides | [guides/index.md](guides/index.md) | How to do a thing (adding a plugin to `pkgs/`) |
| Architecture | [architecture/index.md](architecture/index.md) | How the package set is built (builders, discovery, CI) |
| Reference | [reference/index.md](reference/index.md) | Precise contracts (the import→builder contract, builder arguments) |
| Decisions | [decisions/README.md](decisions/README.md) | Why things are the way they are (ADRs) |

## What lives elsewhere

`agent-stacks import`, `agent-stacks check-plugin` and
`agent-stacks launch` are documented in the agent-stacks repo, under
`docs/reference/` and `docs/decisions/`. This repo documents the Nix
side: what
`buildAgentPlugin` and `mkAgentStack` accept, what they produce, and
the contract the two repos meet at. Where a decision belongs to the
tool, these pages link to it rather than restate it, so the two do not
drift apart.
