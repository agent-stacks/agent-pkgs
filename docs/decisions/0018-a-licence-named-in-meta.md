# 0018. A meta.license given as a string names a licence

Date: 2026-10-05

Status: Proposed

## Context

[ADR 0014](0014-generated-package-meta.md) has `buildAgentPlugin` set
`meta.license` only when the manifest's `license` is an SPDX
identifier `lib.licenses` knows, and accepted that a licence spelled
any other way gets none. A study on 2026-09-18 imported 293
repositories and found two where that cost is paid for a licence
nobody doubts: `apple/game-porting-toolkit` declares `Apache 2.0`,
and `obra/the-elements-of-style` declares `Public Domain`, which has
no SPDX identifier to spell (AI-776). A manifest saying `mit` is a
third case: SPDX matches identifiers without regard to case, and the
lookup here is exact.

The licence is more than metadata. nixpkgs refuses to evaluate a
package whose `meta.license` is not free unless the consumer allows
it. A package with no `meta.license` passes that unexamined.

Recognising what upstream wrote is `agent-stacks import`'s job.
agent-stacks ADR 0044 puts the table of spellings there, with the
SPDX identifier list that tells `mit` from a word that is no licence.
Import cannot finish the job alone: `source.json` is JSON and cannot
hold a `lib.licenses` value. It can hold a string.

nixpkgs does accept a plain string as `meta.license`, but its unfree
check counts every string as free. A string passed through untouched
would type-check and mean nothing.

## Decision

**We will read a `meta.license` given as a string as naming a
licence, and replace it with that licence.** The string is an SPDX
identifier, `"Apache-2.0"`, or, for a licence SPDX has no identifier
for, a `lib.licenses` attribute name, `"publicDomain"`. An identifier
is tried first. This is the arrangement `src` already has: a
generated file records a pin as data and the builder makes the
derivation.

**The builder decides nothing about spelling.** It keeps no table,
and it does not fold case: the SPDX lookup stays exact, on the
manifest and on the recorded string alike. Which string means which
licence is decided in agent-stacks, which records the identifier as
SPDX spells it.

**A string this nixpkgs has no licence for is dropped, not an
error.** `lib` is the caller's nixpkgs, which need not be the one
this repository pins. With the string gone, the manifest's own
licence applies if it resolved, and otherwise the package makes no
licence claim, as ADR 0014 decided.

**The builder reports a dropped string, and this flake fails on
one.** `passthru.agentPlugin.unresolvedLicense` carries it, and the
`license-names-resolve` check fails for any package under `pkgs/`
that has one. Here a string that does not resolve is a mistyped row
in the importer's table, an identifier nixpkgs has no licence for, or
an attribute a `flake.lock` update renamed, and each should stop a
merge.

A caller that passes a `lib.licenses` value in `meta.license` is
unaffected.

## Consequences

- `+` A plugin whose upstream wrote its licence plainly, but not as
  SPDX spells it, carries the right `meta.license`, and nixpkgs'
  unfree check can see it.
- `+` The builder infers nothing. It looks up an identifier or a
  name it was handed, so ADR 0014's "no guess" still holds.
- `+` This can merge before the importer that writes these strings
  is released, so none is ever published as a bare string.
- `-` A string in `meta.license` no longer reaches nixpkgs as free
  text. A hand-written call relying on that gets no licence where it
  had a string nixpkgs ignored.
- `-` A hand-written call whose manifest says `mit` gets no licence.
  Only import knows the identifier it stands for.
- `-` A new spelling reaches a package only after an agent-stacks
  release, the binary bump here, and a re-import.
- `-` The two packages this arrives with, `game-porting-skills` and
  `elements-of-style`, have no licence until that bump: the importer
  pinned here does not record one yet, and the replay adds it when
  it does.
- `-` SPDX expressions, such as the `Apache-2.0 AND CC-BY-4.0` one
  package declares, remain unresolved.
