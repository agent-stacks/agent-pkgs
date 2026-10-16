# 0020. SkillSpector is packaged here for the plugin audit

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

This repository is also going to audit every plugin it packages in
CI, and that job needs a SkillSpector it can name exactly: the score
depends on the scanner's version, and a result is only comparable
with the next one if both came from the same build.

SkillSpector is a Python application with a few hundred transitive
dependencies, two of them sdists that need a build backend and one
(`yara-python`) that needs libyara. Upstream ships a `uv.lock` at each
release tag. `flox/floxenvs` already builds 2.12.0 with uv2nix, from
a vendored wrapper lock, through three sibling packages that each
fetch one of the uv2nix libraries with `fetchFromGitHub`:
pyproject.nix, uv2nix and build-system-pkgs.

Those three are Nix libraries, evaluated rather than built, and each
upstream ships a flake whose README recommends taking it as an input
that follows the consumer's nixpkgs. This flake's nixpkgs is the Flox
fork, which the catalog requires (see `flake.nix`).

## Decision

We will package SkillSpector as `pkgs/skillspector`, ported from
floxenvs's overrides. Like every directory under `pkgs/`, it is a
flake package and published to the catalog. It is packaged for the
CI job that audits the plugins and for users who run
`agent-stacks audit` themselves. It is not put on any stack's PATH:
a stack has no audit of its own.

We will wrap `pkgs/agent-stacks`, the published agent-stacks binary,
so that this set's `skillspector` is first on its PATH. The CLI looks
`skillspector` up on PATH, so an agent-stacks installed from this set
audits with no separate install, and `nix run .#agent-stacks -- audit`
runs the SkillSpector built here. Only this package is wrapped: the
bare binary on downloads.agent-stacks.org is not, and needs
`skillspector` installed beside it. Plugin builds and stacks run the
bare binary (`passthru.unwrapped`): a plugin build assembles and
checks, and a stack launches an agent, and neither audits. A stack's
launcher passes its environment to the agent, so the wrapper would
otherwise put `skillspector` on every agent's PATH and its closure in
every stack. `update-agent-stacks.yml` builds the bare binary too,
which is where the installCheck that runs it lives, so a CLI pin bump
neither builds SkillSpector nor waits on a SkillSpector break.

We will take SkillSpector's source as a flake input,
`skillspector-src`, pinned to a release tag (`v2.12.0`) with
`flake = false`, and build it from the `uv.lock` upstream ships
there. The package's version is the one that tag's `pyproject.toml`
declares, and `flake.lock` pins the tag's revision. Nothing about
SkillSpector is vendored here, so there is no local lock or version
label to keep in step with it. The tag resolves to revision c7958a3,
not the 2226747 the formerly vendored lock pinned: both declare
2.12.0, but the tree built is different, and so is the package. SkillSpector moves by editing the tag
in `flake.nix` in a reviewed pull request, which also builds the
package.

We will take the uv2nix libraries as flake inputs, `pyproject-nix`,
`uv2nix` and `pyproject-build-systems`, each following this flake's
`nixpkgs` and each other, rather than as in-repo fetchers. They reach
the package through the `pkgs/` scope as arguments, as does
`skillspector-src`. They were first locked at the revisions floxenvs
pinned.

We will keep all four inputs out of the hourly flake.lock update.
`update-flake-lock.yml` names the inputs it moves (`nixpkgs`,
`llm-agents`) instead of updating all of them. The four shape the
SkillSpector build the audit's score depends on, and no workflow
builds packages before landing, so they move only through a reviewed
pull request.

`python313` and `yara` (the libyara that `yara-python` builds against)
come from this flake's nixpkgs, and so move with the hourly nixpkgs
bump. We accept that as a known limit: pinning them apart from nixpkgs
would need an overlay, and the interpreter and libyara do not decide
what SkillSpector reports. The audit result names only the
SkillSpector version.

## Consequences

- `+` The CI audit runs the SkillSpector this set built, at a version
  a reader can find in `flake.nix`.
- `+` `agent-stacks/skillspector` is installable from the catalog, as
  the CLI's message says.
- `+` `agent-stacks` from the catalog audits out of the box, with the
  SkillSpector this set built.
- `-` The `agent-stacks` package carries SkillSpector's Python
  closure, though only `audit` uses it. Stacks and plugin builds do
  not: they bind the bare binary.
- `-` The wrapped package and the bare download behave differently:
  the download still needs `skillspector` installed separately.
- `+` Moving SkillSpector is a one-line tag edit and `nix flake lock`;
  no vendored lock, upgrade script or version label to maintain.
- `+` The libraries evaluate against the nixpkgs the catalog serves,
  so the package's closure is built from one nixpkgs.
- `-` SkillSpector and the libraries do not move on their own.
  Someone has to bump them, and build `skillspector`, in a pull
  request.
- `-` The package builds whatever upstream's lock at the tag holds.
  A release whose lock needs a new override breaks the bump until one
  is added here.
- `-` A new flake input is not updated hourly until it is added to the
  workflow's list.
- `-` The hourly nixpkgs bump still moves `python313` and `yara`, and
  so can rebuild or break SkillSpector unreviewed. Hydra reports a
  break after the lock has landed, and nothing records which
  interpreter or libyara an audit ran with.
- `-` A consumer of this flake fetches four more inputs, read by
  `skillspector` and so by `agent-stacks`.
