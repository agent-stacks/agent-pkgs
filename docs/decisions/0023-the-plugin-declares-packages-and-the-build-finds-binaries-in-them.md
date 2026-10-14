# 0020. The plugin declares packages, and the build finds binaries in them

Date: 2026-10-14

Status: Proposed

## Context

ADR 0006 resolved an interpreter name through `mappings/runtimes.nix`,
a table from the name a script writes to a nixpkgs attribute, with a
per-plugin `runtimes` argument to override it. A row could land only
with a package that used it, in one pull request, so the table stayed
small and every row was proven.

Adding `ruby`, `Rscript`, `dotnet` and `dnx` for a batch of vendor
plugins (AI-772) showed where that stops working. The table grows by
one reviewed row per new name, and half its rows map a name to
itself. A version choice has nowhere to go but the table: `dnx` ships
only in `dotnet-sdk_10`, so the `dotnet` row had to say so, in a
shared file whose header says versions do not belong there. The
`runtimes` argument meant for that had no users, and the
specification put it on the stack where the builder put it on the
plugin.

What a build actually needs is not a map. It needs, for each name, a
package whose `bin/` holds that name. The package can be looked in.

## Decision

**A plugin's import declares the packages its runtimes come from, and
the build finds each binary by name inside them.**

`source.json` carries `dependencies`, the nixpkgs attributes
`agent-stacks import --dependency` recorded, omitted when none was
given. `buildAgentPlugin` hands `assemble-plugin` an ordered list of
candidate packages, and the binary searches them for an executable
`bin/<name>`:

1. the declared packages — two of them shipping one name is an error;
2. three defaults, `bash`, `python3` and `nodejs`, handed over only
   when the package records a runtime at all;
3. the package of the name's own spelling, when nixpkgs has one, for
   each name the package records.

`mappings/runtimes.nix` is deleted and the `runtimes` argument
removed. A version pin is a declaration: `--dependency python312`.

The defaults are a list of packages, not a map of names, and do not
grow. Anything they do not ship is a flag on the import that needs it.

## Consequences

- `+` A new runtime is one flag on one import, recorded with that
  package and replayed by CI; this repository changes for none of
  them.
- `+` A version pin and a new runtime are the same declaration.
- `+` Nothing in this repository has to know what a package ships.
  The binary looks, and the search is tested in agent-stacks
  (ADR 0017); this flake asserts only the order it hands over
  (`runtime-candidates`) and that the defaults exist
  (`runtime-defaults-resolve`).
- `+` Every package recorded here resolved by a default or its own
  name except six, which declare `uv` or `powershell`.
- `-` Every package that records a runtime now has all three defaults
  as build inputs, whether it uses them or not. A Markdown-only
  package has none, which is what AI-710 fixed, and that holds.
- `-` A wrong attribute fails at build time with the flag named, not
  at import.
- `-` `assemble-plugin` reads the candidate list; a binary older
  than this record reads the old map and cannot build against this
  builder. The pin is already past it.
