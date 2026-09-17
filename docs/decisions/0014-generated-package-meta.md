# 0014. A generated package's meta asserts only what is known

Date: 2026-09-16

Status: Proposed

## Context

`buildAgentPlugin` computes a `meta` for every plugin it builds,
merged with whatever `meta` the caller passes. Most callers are
generated: `agent-stacks import` records a `source.json`, and
`update-agent-plugins.yml` replays it later with no person watching
the result. Whatever the builder puts in `meta` is what the catalog
sees, so each field has to be something the builder actually knows,
not something it is guessing at to fill the shape.

Four fields raise this in different ways.

**Licence.** Upstream `plugin.json` sometimes names a licence, and
sometimes says nothing, or says something unparseable such as
`SEE LICENSE IN LICENSE`. nixpkgs' `meta.license` is not a free-text
field: it names a `lib.licenses` attribute, and `config.checkMeta`
type-checks it. There is no attribute in `lib.licenses` that means
"unknown" — `licenses.unfree` asserts a specific, usually false,
claim; `licenses.free` asserts the opposite claim with just as little
evidence; and `null` is not how nixpkgs spells absence here, so it
would either be rejected by `checkMeta` or accepted as a value nothing
downstream expects to see.

**Maintainers.** `meta.maintainers` in nixpkgs identifies a person
who watches upstream and is expected to respond about the package.
That description does not fit a generated package: it is refreshed by
`update-agent-plugins.yml` replaying its recorded import, not by
anyone tracking the upstream repository by hand. nixpkgs already
injects `maintainers = []` for any package that does not set the
field, and an empty list already means exactly what is true here —
unmaintained in the nixpkgs sense.

**Platforms.** `meta.platforms` in nixpkgs usually names the systems
a derivation's build output can run on. An Agent Plugin has no
architecture of its own — it is markdown, JSON and scripts, and
whatever interpreter a skill names comes from nixpkgs and carries its
own platform list. Restricting `meta.platforms` to the three systems
this flake happens to build on would describe the flake's CI matrix,
not a property of the plugin.

`meta.category`, introduced below, is not one of nixpkgs' own meta
keys — it is a Flox extension, absent from nixpkgs' `metaTypes`. The
same `config.checkMeta` invoked above to justify `meta.license`
rejects any attrset carrying it: `checkMeta` defaults to `false`, so
this flake, its checks and Hydra never enable it and never hit the
failure, but a consumer who does turn it on gets a hard evaluation
error on every package this set publishes. That is accepted, not
overlooked — the catalog needs the field, and no consumer of this set
enables `checkMeta` — but it means `category` sits outside the
checkMeta-clean reasoning the rest of this ADR relies on, not inside
it.

**Category.** The obvious shape for `meta.category` is the plugin's
subject — "coding", "productivity", "research" — mirrored from
whatever a marketplace's own taxonomy calls it. Two measurements ruled
that out. Of 48 upstream plugins in this set, only 27 declare a
marketplace category at all; of those 27, "productivity" accounts for
14, and two of the remaining names, "engineering" and "development",
are already two spellings of one bucket. A domain axis built from
that data would be sparse, skewed, and inconsistent before this set
adds a single plugin of its own. The website catalog already tried
a domain-shaped field: its `categories` attribute is the literal
value `["ai"]` on all 31 items it lists — a field so fine-grained in
theory that in practice every item collapses to the one value nobody
finds useful. That is the failure a category field has to avoid, not
repeat.

## Decision

**We will compute a `meta.license`, when a licence is known, by
reverse-mapping `manifest.license` through `lib.licenses` on its
`spdxId`.** A declared licence that resolves to a known SPDX
identifier is honoured. A declared licence that does not resolve —
"SEE LICENSE IN LICENSE" and similar upstream text — gets no
`meta.license` attribute at all, and neither does a manifest that
declares nothing. Absent is the honest answer in both cases; a
guessed value is not.

**We will never set `meta.maintainers`.** nixpkgs supplies the empty
list on our behalf, which already says what is true.

**We will set `meta.platforms = lib.platforms.all`.** for every
generated plugin, because the plugin itself has no narrower claim to
make; the systems that matter are the interpreter's, not the plugin's.

**We will give `meta.category` the four values `agent-plugin`,
`agent-stack`, `agent` and `agent-tool`, describing the package's
kind rather than its subject.** Kind is a question this set can
answer for every package it builds or re-exports, unlike domain,
which most upstream plugins never answered for themselves. A package
that cannot be classified — one this set neither builds as a plugin
or stack nor can place with confidence among the re-exported names —
gets no `meta.category` attribute rather than a default. Calling a
setup hook or an unclassified tool an `agent-tool` would assert
something we do not actually know; absence means unclassified, the
same convention the licence field uses.

The consumer of `meta.category` is the Flox catalog, through the
Catalog Meta Attributes project. These four values are what this
repository proposes; whether and how the catalog reads them is that
project's decision, not this one.

## Consequences

- `+` A generated package's `meta` never asserts something the
  builder does not actually know: no licence label pulled from thin
  air, no maintainer who is not watching, no platform list narrower
  than the plugin's real reach.
- `+` `meta.category` gives every published package a classification
  along an axis that is answerable in practice — kind, not subject —
  instead of one that collapses to a single value under real data, as
  the website catalog's `categories` field already has.
- `+` Absence is a real, load-bearing value for both `license` and
  `category`: a reader who sees neither knows the honest state is
  "not asserted," not "checked and found none."
- `-` `meta.license` cannot be set for a plugin whose upstream
  licence text does not map onto an SPDX identifier `lib.licenses`
  recognises, even when a human reader could tell what upstream
  means; the builder does not attempt that inference.
- `-` A domain-shaped category — "coding," "research," and so on — is
  not available from this field. A consumer that wants that axis has
  to build it from upstream's own, sparser, marketplace metadata, or
  wait on a project better positioned to curate it.
