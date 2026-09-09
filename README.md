# agent-pkgs

A Nix package set for [Agent Plugins](https://agent-plugins.org):
skills and MCP server configurations packaged as reproducible,
closure-complete Nix packages, and composed into Agent Stacks.

Packages here are generated and validated by
[`flox-agent`](https://github.com/flox/flox-agent), but the repo
builds with plain Nix — no Flox required.

## Use it

```sh
nix build github:agent-stacks/agent-pkgs#agent-plugin-superpowers
```

Every package produces the canonical Agent Plugins layout:

```text
result/share/agent-plugins/<name>/
├── plugin.json
├── skills/
└── mcp.json        # optional
```

## Binary cache

Hydra builds every package in this repo for `x86_64-linux`,
`aarch64-linux` and `aarch64-darwin`, and publishes them to
`cache.agent-stacks.org`. Point Nix at it to skip the builds:

```conf
# /etc/nix/nix.conf, or ~/.config/nix/nix.conf for a single user
extra-substituters = https://cache.agent-stacks.org
extra-trusted-public-keys = agent-stacks-1:RWT4eI3clOY7jhOzIQNTyXL1Z8yQpN3KlNvvPMfFCRk=
```

Or per invocation, without touching the config:

```sh
nix build github:agent-stacks/agent-pkgs#agent-plugin-superpowers \
  --extra-substituters https://cache.agent-stacks.org \
  --extra-trusted-public-keys agent-stacks-1:RWT4eI3clOY7jhOzIQNTyXL1Z8yQpN3KlNvvPMfFCRk=
```

The cache advertises priority 41, below `cache.nixos.org` at 40, so
anything already in the upstream cache still comes from there.

## Layout

| Path | Contents |
| ---------------------------- | -------- |
| `lib/build-agent-plugin.nix` | `buildAgentPlugin` — one plugin per upstream repo |
| `lib/mk-agent-stack.nix` | `mkAgentStack` — compose plugins into a stack |
| `pkgs/<name>/` | One package per plugin; auto-discovered, no central list |
| `mappings/runtimes.nix` | Ecosystem runtime names to nixpkgs attributes |

Add a package by dropping a directory into `pkgs/` — typically via
`flox-agent import <repo> --out pkgs/<name>`.

## Stacks

`mkAgentStack` composes plugins into a stack with a launcher for the
harness. The launcher starts the harness, but skills aren't wired in
yet: every adapter in `flox-agent` still reads the old
`share/flox/<agent>/` layout, so the agent starts with none of the
stack's skills until a separate launch rework lands.

See [docs/reference/mk-agent-stack.md](docs/reference/mk-agent-stack.md).

## Fork it

An organization using Nix (with or without Flox) can fork this repo
as an internal plugin marketplace: keep `lib/`, replace `pkgs/` with
your own set, and CI (plain GitHub Actions) builds every package on
every PR.

## Documentation

Start at [docs/index.md](docs/index.md): architecture, the
[import→builder contract](docs/reference/import-contract.md), and
decision records.

## License

MIT. Individual packaged plugins carry their upstream licenses,
recorded in each package's `meta`.
