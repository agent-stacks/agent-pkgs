# 0024. A re-exported package can carry a patch, named in `overrides/`

Date: 2026-10-22

Status: Proposed

## Context

ADR 0008 re-exports `llm-agents.nix` into this set as upstream builds
it. The only thing done to a re-exported package since is a
`meta.category` (ADR 0014), and that changes no store path.

`codex` needs more than that. agent-stacks launches it with skills
staged outside `~/.codex` and the working tree, and passes their
location in `CODEX_FLOX_SKILL_ROOTS`, an env var upstream codex does
not read. agent-stacks ADR 0011 settled on a downstream patch,
`flox-fragments.patch`, that adds it and a second one,
`CODEX_FLOX_INSTRUCTIONS_FILE`. `agent-stacks doctor` checks for the
patch by grepping the binary for the first name, and reports a codex
without it as "degraded … skills will not be injected". floxenvs
builds its own codex with the patch, and cannot drop that recipe until
the codex published here has it too.

Three places could carry the patch:

- **A package under `pkgs/codex`.** The name would clash with the
  re-export, and the warning in `mkAllPackages` exists to flag exactly
  that. `pkgs/` is also in `checks`, so `nix flake check` would build
  codex, a large Rust build, on GitHub runners. And we would own upstream's
  whole recipe — the V8 archive pins, the vendor hash, the daemon
  patch — and every version bump with it.
- **Upstream.** The env vars are a seam for agent-stacks, not a fix to
  codex, so neither openai/codex nor `llm-agents.nix` has a reason to
  carry them on our schedule. codex 0.163.0 does have a seam of its
  own for extra skill roots, though: `SkillsHostService::set_extra_roots`,
  set by the app-server's `SkillsExtraRootsSet` request. It is reachable
  only over the app-server protocol, not from the interactive CLI
  agent-stacks launches. An upstream change exposing it through an env
  var or a `-c` key would be small, and would let this set drop the
  patch. That is the way out of this record, not something to wait on.
- **`overrideAttrs` on the re-exported package.** Upstream's recipe
  and version still arrive with `flake.lock`; the patch is the only
  thing owned here.

The `llm-agents.nix` scope the packages are called from is not exposed:
`mkPackagesFor` returns a plain attribute set. An override can
therefore change the package this set publishes, but not the copy
upstream passes to the packages that take `codex` as an input
(`codex-acp`, `t3code`, `oh-my-codex`, `kandev`).

## Decision

We will patch a re-exported package with `overrideAttrs`, applied in
`llmAgentsFor`, from a list of exceptions in `overrides/default.nix`.
Each entry is keyed by the re-exported name, and its value is the
function handed to that package's `overrideAttrs`. Patch files live
beside it, under `overrides/<name>/`. The override is applied before
the category, so the published derivation is the patched one.

`codex` is the first entry. It appends `flox-fragments.patch`, copied
verbatim from floxenvs, to upstream's `patches`.

Two checks guard the list, and both run in `nix flake check`:

- `overrides-name-packages` fails, by name, on an entry
  `llm-agents.nix` no longer defines. A rename upstream should not
  quietly drop a patch, which a lookup that skipped missing names
  would do. It is a check rather than an evaluation error, so a stale
  entry leaves `packages.*` evaluable and unrelated updates unblocked.
- `<name>-patches-apply` unpacks the overridden package's source and
  applies its `patches`, the same list in the same order, then stops.
  The re-export is not built in `checks` (ADR 0008), so without this a
  bump that breaks a patch would merge with `flake.lock` and surface
  only as a red Hydra job.

A patch is referenced through `builtins.path`, which copies the one
file into a store path of its own. A bare `./codex/…` path resolves
inside this flake's source, so every commit to the repository would
change codex's derivation and rebuild it.

The list is for changes agent-stacks needs in order to work with a
package. A fix that any user of the package would want goes upstream.

## Consequences

- `+` The codex published here passes `agent-stacks doctor`, so
  floxenvs can delete its own codex recipe.
- `+` codex's version, V8 pins and build still come from upstream with
  `flake.lock`. Only the patch is maintained here.
- `+` A second override is one entry and, if it needs one, a patch
  file. No new mechanism.
- `-` codex no longer substitutes from `cache.numtide.com`. Before
  this record, the codex this set published on aarch64-darwin had the
  same output path as upstream's cached build (the other two systems
  were not checked). Now Hydra builds it for all three systems on
  every codex bump, and it is a large Rust build.
- `-` A codex bump that breaks the patch fails `codex-patches-apply`,
  and with it the hourly lock update, until someone rebases the patch.
  Every other package's update waits behind it. That is the price of
  hearing about it before the merge rather than from Hydra after.
- `-` The patched codex keeps upstream's version, 0.163.0, and an
  unpatched agent-stacks/codex 0.163.0 is already in the catalog. That
  the catalog serves the newer build of a version it already has is
  not verified. Until it is, floxenvs should not delete its own codex
  on the strength of this record alone: check what
  `flox install agent-stacks/codex` resolves to, or wait for the next
  codex bump.
- `-` `codex-acp`, `t3code`, `oh-my-codex` and `kandev` keep upstream's
  unpatched codex, so the catalog carries two codex builds. agent-stacks
  never launches them through its codex adapter, so `doctor`'s verdict
  on `codex` is unaffected.
- `-` A stack that follows `llm-agents` to a newer revision than this
  set pins (as the agent-stack guide describes) gets the patch applied
  to that codex too, where it may not apply. `codex-patches-apply`
  only covers the revision this set pins.

---

Extends [0008](0008-re-export-llm-agents-nix.md), which does not
address changing a re-exported package. The env vars and the patch are
agent-stacks ADR 0011's.
