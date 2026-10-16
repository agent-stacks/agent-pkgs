# 0020. SkillSpector is packaged here and is every stack's audit tool

Date: 2026-10-16

Status: Proposed

## Context

`agent-stacks audit` is becoming a security audit by NVIDIA
SkillSpector alone. It runs `skillspector` from PATH and scores a
plugin from its findings; with no `skillspector` it cannot score, and
says so with exit 3. Its error message tells the user to add
`agent-stacks/skillspector` to the environment, so the package has to
exist in the `agent-stacks` catalog, which is fed from this flake's
`packages.*`.

A stack's audit script puts `mappings/audit-tools.nix` on PATH. That
list was empty: none of the tools the old audit probed for were
packaged here, so a stack audited with whatever the consumer had.

SkillSpector is a Python application with a few hundred transitive
dependencies, two of them sdists that need a build backend and one
(`yara-python`) that needs libyara. `flox/floxenvs` already builds
2.12.0 from a `uv.lock` with uv2nix, through three sibling packages
that each fetch one of the uv2nix libraries with `fetchFromGitHub`:
pyproject.nix, uv2nix and build-system-pkgs.

Those three are Nix libraries, evaluated rather than built, and each
upstream ships a flake whose README recommends taking it as an input
that follows the consumer's nixpkgs. This flake's nixpkgs is the Flox
fork, which the catalog requires (see `flake.nix`).

## Decision

We will package SkillSpector as `pkgs/skillspector`, ported from
floxenvs with its `pyproject.toml`, `uv.lock`, `hashes.json`,
`upgrade.sh` and overrides unchanged. Like every directory under
`pkgs/`, it is a flake package and published to the catalog.

We will take the uv2nix libraries as flake inputs, `pyproject-nix`,
`uv2nix` and `pyproject-build-systems`, each following this flake's
`nixpkgs` and each other, rather than as in-repo fetchers. They reach
the package through the `pkgs/` scope as arguments. They were first
locked at the revisions floxenvs pinned.

We will make `[ skillspector ]` the default in
`mappings/audit-tools.nix`, so every stack's audit carries
SkillSpector in its closure. `audit.tools` still replaces the list.

## Consequences

- `+` A stack's audit works with nothing installed beyond the stack,
  and runs the SkillSpector this set built and tested.
- `+` `agent-stacks/skillspector` is installable from the catalog, as
  the CLI's message says.
- `+` The hourly `nix flake update` moves the uv2nix libraries; no
  `hashes.json` or upgrade script per library to maintain.
- `+` The libraries evaluate against the nixpkgs the catalog serves,
  so the package's closure is built from one nixpkgs.
- `-` The hourly update can move the libraries to a revision that no
  longer builds SkillSpector. CI evaluates `packages.*`, so an
  evaluation break is caught there; a build break is caught by Hydra,
  after the lock has landed.
- `-` SkillSpector itself and its Python dependencies do not move with
  the flake: `pkgs/skillspector/upgrade.sh` moves them, run by hand.
  No workflow runs it yet.
- `-` A consumer of this flake fetches three more inputs, though only
  evaluating `skillspector`, or a stack's audit, reads them.
