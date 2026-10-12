# 0019. An upstream bin/ ships beside the interpreter links

Date: 2026-10-12

Status: Proposed

Supersedes the `bin/` ownership in [0006](0006-runtime-substitution.md)
and the "never ships `bin/`" clause of
[0016](0016-plugin-root-code-ships-when-skills-reference-it.md). The
rest of both records stands.

## Context

[0006](0006-runtime-substitution.md) made `bin/` the directory of
interpreter symlinks the runtime pass points shebangs at, and
[0016](0016-plugin-root-code-ships-when-skills-reference-it.md) drew
the consequence: a package never carries an upstream `bin/`. Since
[0013](0013-assembly-lives-in-flox-agent.md) the pass runs inside
`agent-stacks assemble-plugin`, and `buildAgentPlugin` does not write
`bin/` itself.

Claude Code puts a plugin's `bin/` on the Bash tool's `PATH`, after the
user's own entries, and the Agent Plugins spec gives `./bin/server` as
its example server command. Three packages here, `agent-plugin-chisle`,
`agent-plugin-agent-browser` and `agent-plugin-agent-deck`, come from
repositories with such a `bin/`, and each lost what Claude's own install
puts on `PATH`, with nothing in `import.warnings` to say so. None of the
three files works on its own: an `npx` installer, a diagnostic bound to
its author's machines, and the npm wrapper of a native binary the
repository does not hold. agent-stacks ADR 0052 has the analysis and
the alternative it rejected.

## Decision

An upstream `bin/` ships at the plugin root, beside the interpreter
links. `skills/` is the only plugin-root entry assembly owns.

- `pluginRootPaths` may name `bin`. The builder copies it like any
  entry, before the runtime pass, so its scripts are rewritten, pinned
  and guarded, and its interpreters appear in `requiredRuntimes`.
- An entry already under an interpreter's name fails the build, naming
  both paths. Import refuses the same collision first and prints the
  `--path-ignore` path that keeps the directory out. A passed-through
  tree's own `bin/<interpreter>`, which the pass used to take for the
  link, is the same failure.
- [0011](0011-skill-and-tool-are-separate-packages.md) stands.
  agent-browser's `bin/agent-browser.js` is the tool's npm wrapper,
  which Claude's install also carries, not the tool. A `bin/` holding
  nothing the package can run may be kept out with `--path-ignore` in
  that package's import flags.
- Import lists a shipped `bin/`'s files in `import.warnings`, as it
  lists hook handlers, so the hourly replay's diff names each command a
  package adds to `PATH`.

## Consequences

- `+` The three packages carry what Claude's install puts on `PATH`,
  under the same names.
- `+` `./bin/server` resolves in a package.
- `+` No change to `buildAgentPlugin` or to any check here
  ([0017](0017-checks-live-where-the-behaviour-lives.md)). Packages
  change when `pkgs/agent-stacks` moves to a binary carrying
  agent-stacks ADR 0052.
- `-` A `bin/` naming an interpreter its scripts use cannot be imported
  until the directory is ignored or upstream renames the file.
- `-` A `bin/` added upstream reaches its package through the hourly
  replay and lands on Claude's `PATH`; the listing shows each file in
  the diff.

---

Records AI-1004 on this side. The decision is agent-stacks ADR 0052.
