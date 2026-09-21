---
name: contributing
description: Use when adding a package to agent-pkgs, when agent-stacks import errors or writes nothing, or when a build fails with "runtime '...' is not mapped".
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
3. **The build says a runtime is not mapped.** Section 3.

Links here are absolute on purpose. This file is copied out of the repository
when a plugin is installed, and a relative path would not resolve there.

## 1. Add a package

1. `git fetch origin && git switch -c <branch> origin/main`

   Start from `origin/main`, never a local `main`. The replay job re-imports
   every recorded package hourly and pushes, so a local `main` is stale within
   the hour and you will branch off something that no longer exists upstream.

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

## 3. When a runtime is unmapped

The build fails with:

```
runtime '<tok>' (wanted by <path>) is not mapped.
  Add it to mappings/runtimes.nix, or pass runtimes.<tok> = <package>;
```

Take the first suggestion. The second one does not apply to a generated
package: `source.json` has no field for a runtime pin, and a pin added by hand
to `default.nix` is erased by the next re-import.

1. Add a row to [mappings/runtimes.nix](https://github.com/agent-stacks/agent-pkgs/blob/main/mappings/runtimes.nix):
   `<tok> = "<nixpkgs attribute>";`. The key is the token as skills write it,
   in a shebang or an `mcp.json` command. The value is the nixpkgs attribute
   name, which is often different: `pwsh` maps to `powershell`, `npx` and
   `node` both map to `nodejs`.
2. Put the row in the same pull request as the package that needs it, never on
   its own. A row nothing exercises cannot be shown to work.
3. Rebuild. A wrong attribute fails with
   `mappings/runtimes.nix maps '<tok>' to unknown nixpkgs attribute '<attr>'`.

If a skill needs a specific interpreter version rather than a name, the table
cannot express it. Treat that as section 2 and report it.

## What a passing build looks like

The install check runs the plugin validator and prints one line per package:

```
OK /nix/store/...-agent-plugin-<name>-<version>/share/agent-plugins/<name> (Agent Plugins 1.1.0)
```

That line is `check-plugin` passing. If you do not see it, the package did not
validate, whatever else the log says.
