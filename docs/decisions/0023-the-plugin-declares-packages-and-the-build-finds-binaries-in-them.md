# 0023. The plugin declares packages, and the build finds binaries in them

Date: 2026-10-14

Status: Proposed

## Context

ADR 0006 resolved an interpreter name through `mappings/runtimes.nix`,
name to nixpkgs attribute, with a per-plugin `runtimes` override; a
row landed with the package that used it.

Adding `ruby`, `Rscript`, `dotnet` and `dnx` (AI-772) showed the shape
wrong: every new name is a shared-file change, half the rows map a
name to itself, a version choice (`dnx` only in `dotnet-sdk_10`) had
nowhere else to go, and `runtimes` had no users. What a build needs is
a package whose `bin/` holds the name, and a package can be looked in.

## Decision

`source.json` carries `dependencies`, the nixpkgs attributes
`agent-stacks import --dependency` recorded, omitted when none.
`buildAgentPlugin` hands `assemble-plugin` an ordered candidate list,
searched for an executable `bin/<name>`: the declared packages (two
shipping one name is an error), then `bash`, `python3` and `nodejs`,
then the package named like the name when nixpkgs has one, with its
main program as a fallback.

`mappings/runtimes.nix` and `runtimes` go. A version pin is
`--dependency python312`. The defaults are a list, not a map, and do
not grow. A generated package recording no runtime gets no defaults
(AI-710); a hand-written call, which records nothing, gets them.

## Consequences

- `+` A new runtime is one flag on one import; this repository changes
  for none.
- `+` Nothing here knows what a package ships. The search is tested in
  agent-stacks (ADR 0017); `runtime-candidates` asserts the order
  handed over and `runtime-defaults-resolve` that the defaults exist.
- `+` Every package here resolved by a default or its own name except
  six, which declare `uv` or `powershell`.
- `-` Every package recording a runtime has the three defaults as
  build inputs.
- `-` A wrong attribute fails at build time, naming the flag.
- `-` A binary older than this record cannot build against this
  builder; the pin is past it.
- `-` The named tier lets upstream content pick a package: a bare
  `mcp.json` `command` resolves to `pkgs.<name>` on the next replay,
  and a server running `docker` links nixpkgs' docker where it used to
  fail — a pin ADR 0011 declined for the tools a skill drives. A
  declared package shipping a default's binary takes it. The binary
  prints every link; `dependencies` or `allowPathCommands` overrides.
