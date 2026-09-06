# Overview

## The pipeline

```text
upstream repo ──(flox-agent import, impure)──▶ pkgs/<name>/default.nix
                                                     │  committed, pinned
                                                     ▼
                                    buildAgentPlugin (pure Nix)
                                                     │
                                                     ▼
                            $out/share/agent-plugins/<name>/
                                                     │
                                    mkAgentStack (composition)
                                                     ▼
                                              an Agent Stack
```

`flox-agent import` is the impure generator (nvfetcher model): it
discovers skills in a source repo, pins everything (commit +
hashes), and writes one generated `default.nix` per plugin into
`pkgs/`. The generated file's shape is the
[import→builder contract](../reference/import-contract.md); how the
generator reaches it is documented where the generator lives, in the
flox-agent repo (`docs/reference/import-command.md` and the decision
records beside it).

`buildAgentPlugin` is pure: no network at build time. It assembles
the canonical Agent Plugins layout from the pinned src, rewrites
shebangs and `mcp.json` commands to plugin-local store-path symlinks
so the interpreters land in the closure
([ADR 0006](../decisions/0006-runtime-substitution.md)), and
validates the result with `flox-agent check-plugin` when the binary
is available ([ADR 0002](../decisions/0002-optional-check-phase.md)).

## Composition

`mkAgentStack` composes plugins and one harness into a stack: the
neutral plugin layout, a launcher named after the stack, and an audit
output. It bakes no per-harness trees, because `flox-agent launch`
adapts plugins to the agent just in time; how that staging works is
described in the flox-agent repo, `docs/architecture/launch.md`.

## Package discovery

Every subdirectory of `pkgs/` with a `default.nix` becomes a flake
package. `mkPackages` builds them with `pkgs.newScope` over a
self-referential scope, not plain `callPackage` — no central list,
and a package in `pkgs/` may take another package in `pkgs/` as an
argument, which is how a stack names its plugins. `flake.nix` also
exposes `lib.buildAgentPlugin` and `lib.mkAgentStack` per system, and
`checks` covering every package plus the `layout`, `override-hook`,
`mcp-spec-version`, `runtimes-closure`, `runtimes-two-pythons`,
`runtimes-failures`, `stack-layout`, `stack-launcher`, `stack-audit`,
and `stack-assertions` assertions.

## CI

GitHub Actions (ubuntu + macos) with `flox/install-flox-action` and
`flox/configure-nix-action`; `nix flake check` builds every package.
The binary cache is populated separately by Hydra (Distribution
project); CI stays plain and forkable.
