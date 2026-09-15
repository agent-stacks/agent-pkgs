# 0006. Runtime substitution: plugin-local bin/, deterministic scope

Date: 2026-09-01

Status: Accepted

Note: `allowEnvShebangs`, mentioned below, is removed as of
[0013](0013-assembly-lives-in-flox-agent.md); the rest of this
decision stands.

## Context

Skills ship scripts with `#!/usr/bin/env python3` shebangs and
`mcp.json` entries whose `command` is a bare token like `node`. Both
assume the consumer machine has the right interpreter on PATH, which
is the reproducibility hole this project exists to close. Nix's
reference scanner can carry the interpreters in the plugin's closure,
but only if the built files reference their store paths.

Interpreter mentions also appear inside script bodies and SKILL.md
prose. Rewriting those generically is guesswork: a regex that catches
`python3 -m scripts` also catches documentation and examples. The
skills-caveman package in floxenvs, the prior art here, handled that
case with a hand-written substitution.

## Decision

The pass rewrites only what is deterministic: shebangs
(`/usr/bin/env <name>` and `/usr/bin/<name>` forms, outside
`assets/`) and bare `mcp.json` commands. Everything fuzzy goes
through the per-package `extraSubstitutions` argument.

Rewritten references point at a plugin-local `bin/` directory of
symlinks into the store, not at raw store paths, following
skills-caveman. That gives one visible place listing a plugin's
runtimes, keeps `${CLAUDE_PLUGIN_ROOT}/bin/<name>` usable in harness
configs, and still captures the closure through the symlink targets.

Names resolve through `mappings/runtimes.nix` (name to nixpkgs
attribute), overridden per plugin by `runtimes` (name to package,
which is also the version pin). An unmapped name fails the build with
the file that wanted it and a pointer to the table. Bare mcp commands
that intentionally come from the consumer environment are listed in
`allowPathCommands`. After the pass, an executable that still has a
`/usr/bin/env` shebang fails the build unless listed in
`allowEnvShebangs`.

## Consequences

- `+` `nix copy` of a plugin carries its interpreters; the offline
  demo claim holds.
- `+` Two plugins pin conflicting interpreter versions and coexist in
  one stack, proven by the `runtimes-two-pythons` flake check.
- `+` Failures are loud and name the fix.
- `-` Every mapped runtime a plugin mentions becomes a build input of
  that plugin, so the table stays lean.
- `-` Body-text and SKILL.md rewrites need per-package attention via
  `extraSubstitutions`; the pass will not guess.
