# 0017. Checks live where the behaviour lives

Date: 2026-09-21

Status: Accepted

## Context

Four of this flake's checks asserted what the `agent-stacks` binary
writes into a plugin tree: `arguments-alone` and
`arguments-alone-no-manifest` (manifests, MCP servers, skill selection
modes), `root-skill-excludes-nested` (ADR 0021, an agent-stacks
record), and `runtimes-failures` (the error text an unmapped runtime
produces).

Every one of those facts is also asserted in agent-stacks' own test
suite, where the code that produces it lives. So the checks here were
a second copy, with nothing keeping the two in sync.

Only the copy can rot, and it did. agent-stacks-cli#106 changed an
`mcp.json` command from the plugin's absolute store path to
`./bin/<tok>`, because Agent Plugins 7.2.1 admits only a bare
executable name or a plugin-relative path and a conforming client was
dropping the server. Its own tests moved with it and passed. The
expectation here did not move, because nothing connects them — and it
did not fail then either. It failed later, when `update-agent-stacks`
bumped `pkgs/agent-stacks` to a binary carrying the fix, in an
unrelated pull request, whose author had to work out that the red
check had nothing to do with their change.

That is the general shape rather than one accident. This repository
consumes the binary as a pinned dependency on its own release
schedule. An assertion here about what that binary produces cannot
fail at the commit that changes the behaviour; it can only fail at the
next bump, attributed to whoever triggered it.

## Decision

We will not assert here what the binary produces.

A check in this flake covers the Nix seam: what `buildAgentPlugin`
does with its arguments, what `meta` it derives, what this repository's
own tables and lists contain, what the flake exposes. Those are facts
this repository owns, and a change to them lands with the check that
covers it.

What the binary writes into a tree is asserted in agent-stacks, in the
same commit as the behaviour. The four checks named above are removed
here, and the assertions they made that agent-stacks did not already
cover were written there first.

One check moves rather than disappears. `runtimes-failures` asserted
two things at once: that an unmapped token fails the build with a
message naming this file, which is the binary's message and is now
asserted there; and that `mappings/runtimes.nix` is consulted at all.
The table is ours — ADR 0006 and the file's own comment record why it
stays here — so `runtime-table-resolves` replaces it, checking that
every row names a nixpkgs attribute that exists. That is stronger than
what it replaces: a row pointing at nothing used to fail only once a
package recorded that token, which can be months later.

## Consequences

- `+` A behaviour change and the check that covers it land in one
  commit, in one review, in one repository.
- `+` A red check here means something in this repository is wrong,
  which is what makes it worth reading.
- `+` The checks that remain are faster and fewer, and every one of
  them is about Nix.
- `-` Nothing verifies the two repositories agree end to end any
  more. A binary could satisfy its own tests and still produce a tree
  `buildAgentPlugin` mishandles. The `installCheckPhase` call to
  `check-plugin` is the remaining integration point, and it validates
  the output rather than comparing it to an expectation.
- `-` The rule needs applying, not just recording. The next Nix-side
  check that reaches for a fact about the binary's output will look
  reasonable at the time.
