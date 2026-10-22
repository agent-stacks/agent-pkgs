# Overview

## The pipeline

```text
upstream repo ──(agent-stacks import, impure)──▶ pkgs/<name>/default.nix
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

`agent-stacks import` is the impure generator (nvfetcher model): it
discovers skills in a source repo, pins everything (commit +
hashes), and writes one generated `default.nix` per plugin into
`pkgs/`. The generated file's shape is the
[import→builder contract](../reference/import-contract.md); how the
generator reaches it is documented where the generator lives, in the
agent-stacks repo (`docs/reference/import-command.md` and the decision
records beside it).

`buildAgentPlugin` is pure: no network at build time. It assembles
the canonical Agent Plugins layout from the pinned src, rewrites
shebangs and `mcp.json` commands to plugin-local store-path symlinks
so the interpreters land in the closure
([ADR 0006](../decisions/0006-runtime-substitution.md)), and
validates the result with `agent-stacks check-plugin` when the binary
is available ([ADR 0002](../decisions/0002-optional-check-phase.md)).

## Composition

`mkAgentStack` composes plugins and one harness into a stack: the
neutral plugin layout and a launcher named after the stack. It bakes
no per-harness trees, because `agent-stacks launch` adapts plugins to
the agent just in time; how that staging works is described in the
agent-stacks repo, `docs/architecture/launch.md`.

Auditing is not part of a stack
([ADR 0021](../decisions/0021-a-stack-has-no-audit-output.md)). A
built stack is audited with the CLI, `agent-stacks audit ./result`
(agent-stacks-cli #187), or one plugin at a time,
`agent-stacks audit ./result/share/agent-plugins/<name>` (#186).

## Package discovery

Every subdirectory of `pkgs/` with a `default.nix` becomes a flake
package. `mkPackages` builds them with `pkgs.newScope` over a
self-referential scope, not plain `callPackage` — no central list,
and a package in `pkgs/` may take another package in `pkgs/` as an
argument, which is how a stack names its plugins. `flake.nix` also
exposes `lib.buildAgentPlugin` and `lib.mkAgentStack` per system, and
`checks` covering every package in `pkgs/` plus assertions on the
builder itself, such as `runtime-candidates`.

Not everything in `pkgs/` is a plugin. `agent-stacks`, the
`agent-sandbox-*` launchers and `skillspector`, the scanner
`agent-stacks audit` runs, are discovered the same way. `skillspector`
is built with uv2nix from the `uv.lock` upstream ships at the release
tag the `skillspector-src` input names. The uv2nix libraries are
flake inputs (`pyproject-nix`, `uv2nix`, `pyproject-build-systems`)
that follow this flake's nixpkgs, and they and the source reach the
package through the same scope
([ADR 0020](../decisions/0020-skillspector-is-packaged-for-the-plugin-audit.md)).
`agent-stacks` is the published binary wrapped with `skillspector` on
its PATH, so it audits with nothing else installed; plugin builds and
stacks run the bare binary, its `passthru.unwrapped`.
`impeccable-engine` is the Rust binary impeccable's skill runs, built
from the commit `agent-plugin-impeccable` pins, which ships it so the
skill never downloads one
([ADR 0025](../decisions/0025-a-skills-own-engine-is-built-from-the-skills-source.md)).

`packages` is wider than `pkgs/`. Every agent CLI packaged by
`numtide/llm-agents.nix` is re-exported into it, rebuilt against the
nixpkgs this set pins via that flake's `overlays.shared-nixpkgs`, and
filtered to derivations that are available on the platform and not
broken. A name defined in both places resolves to the one in `pkgs/`
and warns. The re-exported packages are not in `checks`, only in
`packages` and `hydraJobs.packages`; the reasoning is in
[decisions/0008](../decisions/0008-re-export-llm-agents-nix.md).

Packages named in `overrides/default.nix` are published with that
change. Today that is only codex, patched so `agent-stacks launch`
can pass it skills
([decisions/0024](../decisions/0024-a-re-exported-package-can-carry-a-patch.md)).

Spec conformance is not a separate check. `buildAgentPlugin` runs
`agent-stacks check-plugin` on every plugin it builds, so a tree that
violates the Agent Plugins or Agent Skills spec fails its own build.

## CI

GitHub Actions (ubuntu, ubuntu arm and macos) with
`flox/install-flox-action` and `flox/configure-nix-action`, bundled
into the `nix-setup` composite action. CI runs `nix flake check -L` on
every runner, and `--all-systems` once on one of them, for any
declared system no runner covers. `systems` is the three the runners
cover, so that step finds nothing today; it is there so that declaring
a fourth does not go unevaluated until Hydra.

`checks` is the gates — the non-package checks — so that builds the
gates and evaluates every output, and builds no package. A package is
Hydra's, from `packages.*` across every system. It was `checks =
mkChecks` until 2026-10-13, which meant every push built all 315
packages twice; AI-915 records the reasoning.

So a pull request proves that everything evaluates and that the gates
pass, and not that a package builds. Hydra proves that, continuously.
`summary` is the one check branch protection requires.

The replay and lock workflows verify a staged commit by calling
`ci.yml` on that commit, so what a check means is decided in one place
and a staged commit gets exactly what a pull request gets. They built
every plugin package for three systems until 2026-10-13, which spent
about an hour of runner time a cycle to reach Hydra's conclusion later
than Hydra does.

`update-agent-stacks` keeps a matrix of its own instead. It builds one
package and runs the binary in an installCheck, which is the thing
`ci.yml` no longer does for any package.

The binary cache is populated separately by Hydra (Distribution
project); CI stays plain and forkable.

The three update workflows report to Sentry through the
`sentry-checkin` action. The two hourly ones send a cron check-in when
they start and another when a closing `monitor` job sees how the run
ended; `update-agent-stacks`, which is dispatched, sends a failure
event only. The monitor configuration (schedule, margins, thresholds)
lives in `.github/actions/sentry-checkin/checkin.sh` and is upserted on
every check-in. The DSN arrives as the organization secret
`MANAGED_PIPELINE_SENTRY_DSN`, which deltaops syncs from 1Password;
without it the action sends nothing, so a fork runs the same
workflows unchanged. `workflows-lint`
in `ci.yml` checks that each `monitor` job waits for every other job.
