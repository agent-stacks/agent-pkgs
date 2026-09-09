# 0002. Optional check phase until the -bin package exists

Date: 2026-08-28

Status: Accepted

## Context

`buildAgentPlugin` should validate every built plugin with
`flox-agent check-plugin --strict` — the single validator both the
importer and the builder share. But the flox-agent binary
distribution (a `-bin` derivation fed from
downloads.agent-stacks.org) does not exist yet, and reimplementing
the validation in pure Nix would create a second validator to keep
in sync — exactly what check-plugin exists to avoid.

## Decision

We will make the check phase conditional on a `floxAgent ? null`
argument. When a package is passed, the install check phase runs
`flox-agent check-plugin --strict` on the output; when null, the
phase is skipped with a visible build warning.

## Consequences

- `+` The builder ships now; the contract is unaffected.
- `+` Turning validation on later is a one-line change in CI.
- `-` Until the -bin package lands, CI builds are not spec-validated;
  the flake `layout` check covers the structural basics meanwhile.

## Update

The binary package now exists and `buildAgentPlugin` binds it by
default, so the check phase runs on every plugin and the `layout`
check has been removed as redundant. The `floxAgent ? null` argument
stays, for consumers using `lib/` without the package. `--strict` is
opt-in rather than the default: skills in the wild carry harness
frontmatter fields the Agent Skills spec does not list, and those are
warnings a correct plugin can legitimately have.
