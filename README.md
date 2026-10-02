# agent-pkgs

An agent is a stack of interchangeable components: a harness, skills,
MCP servers, configuration, and runtimes. These stacks are traditionally
assembled by hand, so no two machines run quite the same agent.

`agent-pkgs` packages those pieces with Nix. We use the
[Agent Plugins](https://agent-plugins.org) standard to package your
skills and MCP server configurations, then compose these packages with an
agent harness into an [Agent Stack](https://agent-stacks.org). Once an
agent stack is defined, it is fully reproducible and can run anywhere.

## Prerequisites

You need [Nix](https://nixos.org/download/) installed, with flakes enabled.
If you see `experimental Nix feature 'nix-command' is disabled` errors,
enable flakes with:

```sh
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

## Quick start

Most people already have a harness installed. Let's create an agent stack
which adds the [caveman](https://github.com/JuliusBrussee/caveman) plugin
to a machine that already has Claude Code installed:

```sh
mkdir agent-stacks-demo && cd agent-stacks-demo
nix build github:agent-stacks/agent-pkgs#agent-plugin-caveman
```

NOTE: The first time you run this command, Nix asks four y/N questions
about `cache.numtide.com`. This flake offers that cache as an optional
source of prebuilt agent CLIs, and Nix asks before trusting it. Nothing 
here depends on that cache, so you can safely answer `N` to the two `do
you want to allow` questions. Each is followed by `do you want to
permanently mark this value as untrusted`; answer `y` if you would rather
not be asked again.

The build leaves a `result` link to the plugin, in the canonical Agent
Plugins layout:

```text
result/share/agent-plugins/<name>/
├── plugin.json
├── skills/
└── mcp.json        # optional
```

Now start Claude Code with it:

```sh
nix run github:agent-stacks/agent-pkgs#agent-stacks -- \
  --dir ./result/share launch claude
```

That is your own `claude`, with the caveman added for this one session.
Type `/caveman:` to see its skills. If you want to stop using the agent
stack, run `claude` as you normally do, it won't have caveman installed.

NOTE: You will see a warning because `claude` isn't part of the agent
stack. In the
[Create an agent-stack package](docs/guides/create-agent-stack.md)
guide, we'll show how to add a harness to your stack as well.

### Clean up

```sh
cd .. && rm -rf agent-stacks-demo
```

The packages stay in the Nix store with nothing referring to them. To
reclaim the space, run `nix store gc`.

NOTE: `nix store gc` removes every unreferenced path in your Nix store,
not only what this demo built.

## Binary cache

Hydra builds every package in this repo for `x86_64-linux`,
`aarch64-linux` and `aarch64-darwin`, and publishes them to
`cache.agent-stacks.org`. Point Nix at it to skip the builds.

NOTE: A binary cache is optional, but speeds things up by letting you
install pre-built packages instead of building them from source every
time.

```sh
sudo tee -a /etc/nix/nix.conf <<'EOF'
extra-substituters = https://cache.agent-stacks.org
extra-trusted-public-keys = agent-stacks-1:RWT4eI3clOY7jhOzIQNTyXL1Z8yQpN3KlNvvPMfFCRk=
EOF
```

Restart the Nix daemon to read the configuration updates:

```sh
sudo launchctl kickstart -k system/org.nixos.nix-daemon   # macOS
sudo systemctl restart nix-daemon                         # Linux
```

NOTE: If you're using Determinate Nix, add the configuration to
`/etc/nix/nix.custom.conf` instead. On macOS, the daemon to restart is
`systems.determinate.nix-daemon`:

```sh
sudo launchctl kickstart -k system/systems.determinate.nix-daemon
```

The Linux command is the same as above.

To confirm that the cache is working, see if you can fetch a package
without building it:

```sh
nix build github:agent-stacks/agent-pkgs#opencode --dry-run
```

If the output lists `opencode` under `will be fetched`, the cache is
in use. If it lists `opencode` under `will be built`, it is not.

The cache advertises priority 41, below `cache.nixos.org` at 40, so
anything already in the upstream cache still comes from there.

### Configuration for trusted users

If your user is listed in `trusted-users`, the system file is not
needed: put the same two lines in `~/.config/nix/nix.conf`.

If you do not want to make the configuration permanent, you can pass
configuration per invocation:

```sh
nix build github:agent-stacks/agent-pkgs#agent-plugin-caveman \
  --extra-substituters https://cache.agent-stacks.org \
  --extra-trusted-public-keys agent-stacks-1:RWT4eI3clOY7jhOzIQNTyXL1Z8yQpN3KlNvvPMfFCRk=
```

For any other user Nix ignores both, with `warning: ignoring untrusted
substituter`.

## File layout

| Path | Contents |
| ---------------------------- | -------- |
| `lib/build-agent-plugin.nix` | `buildAgentPlugin` — one plugin per upstream repo |
| `lib/mk-agent-stack.nix` | `mkAgentStack` — compose plugins into a stack |
| `pkgs/<name>/` | One package per plugin; auto-discovered, no central list |
| `mappings/runtimes.nix` | Ecosystem runtime names to nixpkgs attributes |

Add a package by dropping a directory into `pkgs/`. You can accomplish
this by running `agent-stacks import <repo> --out pkgs`. In this
example, `--out` is the output root and the importer appends
`agent-plugin-<name>/` to it. See
[Create an agent-plugin package](docs/guides/create-agent-plugin.md)
for more details.

A package's closure includes an interpreter only when a file names it
where the build can rewrite it:

- a script's shebang
- a bare `command` in `mcp.json`
- a hook in `hooks/hooks.json`

Everything else still comes from the machine the plugin runs on. For
example, assume you have a `SKILL.md` that tells the agent to run a
script like `python3 script.py`. If `script.py` doesn't have a shebang
that defines the interpreter, `python3` will not be in the closure.
The same is true for any libraries a script imports, the tools it
shells out to (like `ffmpeg`), and any packages in a dependency manifest.

## Stacks

`mkAgentStack` composes plugins and one harness into a stack with a
launcher. The launcher runs `agent-stacks launch`, which coerces the
stack's plugins into the form that a given harness expects:

- `--plugin-dir` for claude
- `--skill` for pi
- a `skills/` directory for codex and opencode
- a seeded config for agent-deck

This ensures that the harness can access its skills without the stack
needing to define harness-specific configuration.

See [Create an agent-stack package](docs/guides/create-agent-stack.md)
for a worked example, and
[mkAgentStack](docs/reference/mk-agent-stack.md) for the full API.

## Fork it

An organization using Nix can fork this repo as an internal plugin
marketplace: keep `lib/`, replace `pkgs/` with your own set, and CI
(plain GitHub Actions) builds every package on every PR.

## Documentation

Start at [docs/index.md](docs/index.md): architecture, the
[import→builder contract](docs/reference/import-contract.md), and
decision records.

## License

MIT. Individual packaged plugins carry their upstream licenses,
recorded in each package's `meta`.
