---
name: contributing
description: Use when adding a package to agent-pkgs, when agent-stacks import errors or writes nothing, or when a build fails with "runtime '...' is not provided by a declared dependency".
---

# Contributing a package to agent-pkgs

Packages here are generated, not written. `agent-stacks import` reads an
upstream skills repository and writes `pkgs/agent-plugin-<name>/`, and the
flake discovers it with no central list to edit.

[docs/guides/create-agent-plugin.md](https://github.com/agent-stacks/agent-pkgs/blob/main/docs/guides/create-agent-plugin.md)
walks through the commands. This skill covers what that guide does not: how
to start, how to finish, and what to do when the import or the build refuses.

Never hand-edit a generated `source.json` or `default.nix`. A later re-import
erases the edit, and the hourly replay job is what re-imports.

## Usage

Three situations, in the order you hit them:

1. **Adding a package** that imports cleanly. Section 1.
2. **The import refused it**, or wrote nothing. Section 2.
3. **The build says no package provides a runtime.** Section 3.

Links here are absolute on purpose. This file is copied out of the repository
when a plugin is installed, and a relative path would not resolve there.

## 1. Add a package

1. `git fetch origin && git switch -c import/<upstream> origin/main`

   Start from `origin/main`, never a local `main`. The replay job re-imports
   every recorded package hourly and pushes, so a local `main` is stale within
   the hour and you will branch off something that no longer exists upstream.

   The guide creates the branch at its step 6, after importing. Do it here
   instead. Branching afterwards branches off whatever your local `main` was
   when you started, which is the staleness this step exists to avoid. The
   `import/<upstream>` name is the guide's.

2. Follow [the guide](https://github.com/agent-stacks/agent-pkgs/blob/main/docs/guides/create-agent-plugin.md) for the
   rest: import, read the generated files, stage in git before building, build,
   open the pull request.

   One thing the guide does not say: **read the import's stderr.** Discovery
   drops are printed there and never reach `source.json`. A file not named
   exactly `SKILL.md`, or a skill left out because another directory already
   claimed its name, is a warning on the terminal and nothing else. The
   generated package looks clean in review even though something was dropped.
   Compare the skill count in `source.json` against what you expected from the
   upstream repository before you open the pull request.

   An upstream that declares several plugins writes several packages in one
   run. **They land together or not at all.** The replay job reads
   `.import.input` from every `pkgs/agent-plugin-*/source.json` and re-imports
   that whole upstream, so a sibling left behind is regenerated within the
   hour by any one of the packages you did commit. If it does not build, the
   scheduled run goes red against a repository nobody touched. When one plugin
   of a set is blocked, hold the whole set back and report it.

   Commit as `feat(pkgs): add <upstream> plugin`, which is what all but a
   handful of the packages on main were merged as. The guide's step 6 shows
   `import: <upstream>`; nothing on main uses it.

3. Request review, and do not merge it yourself.

   CI builds every package on `ubuntu-latest` and `macos-latest`. The Linux job
   is the gate: confirm from its log that your new package actually built, since
   a package that only builds on a macOS workstation is not done.

   A maintainer reviews; today that is Rok (`garbas`). Branch protection does
   not enforce this, so a green check and a mergeable state prove nothing about
   whether anyone has looked. Wait for the approval.

## 2. When an import fails

Do not work around it. The importer belongs to another repository, and a
per-repository workaround in a generated file is erased by the next replay.

1. Name the cause. Record the upstream file, the exact error text, the platform
   you ran on, and that you reproduced it against current `main`.
2. Leave that package out of the pull request. Ship the ones that worked.
3. Report it as an issue on agent-pkgs with the command, the commit, the output
   and the named cause.

Errors you will actually see:

* `found no SKILL.md`

  The upstream violates the Agent Skills spec. The line above it names the
  file: `warning: <path> is not named exactly SKILL.md, not a skill`. A
  lowercase `skill.md` is the common case, and it is refused the same way on
  every filesystem. This is an upstream problem, not a local one.

* `agent-plugin-<name> already holds <name> imported from <url>; pass --name to give one of them another name`

  Two upstreams want the same package directory, and a directory belongs to
  one upstream. Choose a different name with `-name`. If the source holds
  several plugins the flag is refused, because it cannot say which one it
  meant; that case needs a decision about which upstream owns the name, so
  report it rather than forcing it.

* A non-GitHub input is refused. Import takes GitHub sources only. This is a
  boundary, not a gap.

## 3. When no package provides a runtime

The build fails with:

```
runtime '<tok>' (wanted by <path>) is not provided by a declared dependency,
a default package, or a package named '<tok>'.
  Re-import with --dependency <nixpkgs attribute> naming the package that
  ships bin/<tok>.
```

The build looks for an executable `bin/<tok>` in the packages the import
declared, then in `bash`, `python3` and `nodejs`, then in the nixpkgs package
named `<tok>`. There is no table to add a row to (ADR
[0023](https://github.com/agent-stacks/agent-pkgs/blob/main/docs/decisions/0023-the-plugin-declares-packages-and-the-build-finds-binaries-in-them.md)).

1. Find the nixpkgs attribute whose `bin/` holds the token. It is often not
   the token: `uvx` ships in `uv`, `pwsh` in `powershell`, `Rscript` in `R`,
   `dnx` in `dotnet-sdk_10`.
2. Re-import with `--dependency <attr>`. The flag is recorded in
   `source.json`, so a replay keeps it, and it applies to every plugin the
   import writes. Do not add `dependencies` to `default.nix` by hand: the next
   re-import erases it.
3. Rebuild. An attribute nixpkgs lacks, or one that does not evaluate on the
   system (unfree, broken, unsupported), fails evaluation with
   `dependency '<attr>' ...; re-import with --dependency naming one that is`.

A version pin is the same flag: `--dependency python312` links `bin/python3`
from `python312` ahead of the default. Two declared packages that both ship
the token are an error; keep one.

If the message instead ends `this builder predates --dependency`, the
agent-stacks binary is newer than this builder. Update agent-pkgs.

## What a passing build looks like

The install check runs the plugin validator and prints one line per package:

```
OK /nix/store/...-agent-plugin-<name>-<version>/share/agent-plugins/<name> (Agent Plugins 1.1.0)
```

That line is `check-plugin` passing. If you do not see it, the package did not
validate, whatever else the log says.
