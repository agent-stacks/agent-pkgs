# 0015. What the re-export publishes is a named list, not a rule

Date: 2026-09-16

Status: Proposed

## Context

ADR 0008 re-exports `llm-agents.nix` into this package set so its
helpers are available to whatever this repository builds. What that
flake exposes under `packages.<system>` is a build scope for its own
project, not a curated list of things meant to be published on their
own: alongside real, runnable tools it also carries the nixpkgs
builders and fetchers it patches, the setup hooks its own packages
use, and the toolchains those packages build with. Re-exporting the
whole scope means re-exporting all of that too, unless something
decides which names are packages this set should publish and which
are upstream's own plumbing.

Two automatic tests were measured against the scope before either was
rejected.

**`meta ? mainProgram` as a filter.** Presence of `mainProgram`
partitions the current scope correctly — every attribute this set
wants excluded lacks it, and every attribute it wants published has
it — but that is a fact about the scope today, not a property the
field is meant to guarantee. `mainProgram` is advisory metadata a
packager sets when it is useful, not a marker of "this is a runnable
package." Two names in the current scope prove the point in both
directions at once: `bun-bin` and `go-bin` do ship runnable binaries,
so `mainProgram` would not exclude them even though this set treats
them as build inputs, not agent tooling, by deliberate judgement.
Run the test the other way and the failure mode is worse: a real
agent tool whose packager simply omitted `mainProgram` would be
silently dropped from the catalog, with nothing in a build log to
say so.

**Upstream's own `packages.<system>` flake output.** `llm-agents.nix`
publishes a curated output of its own, which looked like an authority
to defer to instead of building one here. It is not: that output
holds 179 names on aarch64-darwin, and it contains all of the same
infrastructure — builders, fetchers, setup hooks, toolchains — that
made the raw scope unusable in the first place. Deferring to it would
mean applying the same filtering judgement this repository already
has to apply, against a list upstream did not curate for this
question either.

## Decision

**We will publish the re-export as a named list, not as the output of
an automatic test.** `notPackages` in `flake.nix` names every
attribute of the scope that is infrastructure rather than a package —
builders, setup hooks, toolchains, and the two flake-schema output
names `default` and `formatter` — and `keep` excludes exactly those
names. Nothing broader is inferred from `mainProgram`, from
`isDerivation`, or from upstream's own `packages` output.

**`meta ? mainProgram` becomes a tripwire, not a filter.** The
`re-export-is-packages` check asks, for every scope attribute not
already in `notPackages` or `notPackagesExempt`: does this have a
`mainProgram`? A "no" does not exclude the attribute from
publication — it fails the check, by name, and asks a human to
decide which list it belongs in. `notPackages` grows daily as
upstream adds names, so it needs a signal that says "look at this
one," not a rule confident enough to act alone; a name is never
dropped from the catalog without someone seeing it happen.

**`notPackagesExempt` exists for the case `mainProgram` cannot see
through: a real package whose packager omitted the field.** Adding a
name there keeps it published and silences the check for that name
alone, distinct from `notPackages`, which excludes a name from
publication entirely. It is empty today — no name in the current
scope has needed it — but the list exists so that a future real
exception has somewhere to go that is not weakening the check itself.

## Consequences

- `+` The re-export never silently drops a real agent tool merely
  because its packager left `mainProgram` unset — the two rejected
  tests would each have failed in exactly that way, one immediately
  and one the moment upstream added such a package.
- `+` `bun-bin` and `go-bin` are excluded by the same explicit
  judgement that keeps every other build input out, not by an
  incidental property of a field neither package was written to
  satisfy.
- `+` `re-export-is-packages` catches drift the moment upstream adds a
  new builder or hook to the scope, because a missing `mainProgram` is
  exactly what a new piece of infrastructure looks like — the check
  just refuses to act on that signal by itself.
- `-` `notPackages` is a hand-maintained list against a scope that
  changes with every upstream release; keeping it accurate is ongoing
  work that a purely automatic filter would not require.
- `-` A real package that both lacks `mainProgram` and is not yet in
  `notPackagesExempt` fails the flake check until someone classifies
  it, rather than being published immediately with a caveat.
