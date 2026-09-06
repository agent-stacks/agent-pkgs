# agent-pkgs documentation

`agent-pkgs` is the Nix package set for Agent Plugins and Agent
Stacks: skills and MCP server configurations packaged as
reproducible, closure-complete Nix packages.

| Tree | Start here | What it answers |
| ------------ | ---------------------------------------------- | --------------- |
| Architecture | [architecture/index.md](architecture/index.md) | How the package set is built (builders, discovery, CI) |
| Reference | [reference/index.md](reference/index.md) | Precise contracts (the import→builder contract, builder arguments) |
| Decisions | [decisions/README.md](decisions/README.md) | Why things are the way they are (ADRs) |

## What lives elsewhere

`flox-agent import`, `flox-agent check-plugin` and `flox-agent launch`
are documented in the flox-agent repo, under `docs/reference/` and
`docs/decisions/`. This repo documents the Nix side: what
`buildAgentPlugin` and `mkAgentStack` accept, what they produce, and
the contract the two repos meet at. Where a decision belongs to the
tool, these pages link to it rather than restate it, so the two do not
drift apart.
