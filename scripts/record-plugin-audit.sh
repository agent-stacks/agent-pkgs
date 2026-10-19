#!/usr/bin/env bash
# Audit one built plugin package and record the result beside it, as
# pkgs/<package>/audit.json. Called by .github/workflows/audit-plugins.yml
# once per package; runnable by hand the same way. ADR 0022.
#
#   scripts/record-plugin-audit.sh <package> <built package> [<pkgs dir>]
#
#   <package>        the directory name under pkgs/, agent-plugin-<name>
#   <built package>  its build output: a store path or a ./result link
#   <pkgs dir>       where the package directories are; default pkgs
#
# AGENT_STACKS_BIN names the agent-stacks to run (default: agent-stacks on
# PATH). It needs skillspector on its PATH, which pkgs/agent-stacks
# provides, and network access to api.osv.dev. SKILLSPECTOR_BIN names
# the skillspector whose version an exit-3 record names (default:
# skillspector on PATH; the version is null when there is none).
#
# What is written, each with an `agentStacks.version` field naming the
# CLI that audited (`agent-stacks --version`):
#
#   exit 0 or 1  the `agent-stacks audit --json` document, as printed
#   exit 3       when the reason is the plugin's own (nothing to audit,
#                not an agent plugin, cannot read the plugin), a small
#                document saying it could not be audited, with that
#                reason and the SkillSpector version
#
# The new document is compared with the committed one with the fields
# that change on every run left out: tool.osv.checkedAt (when osv.dev
# answered) and plugins[].dir (the plugin's store path, which moves
# with any rebuild of the package without its content changing). The
# file is written only when something else differs, so a run that
# finds what the last one found touches nothing. A new agent-stacks
# version is a difference.
#
# Prints one line, "<package>: new|changed|unchanged (<score>)", and
# exits 0. Exits 2, writing nothing, on anything that is not the
# plugin's result: a usage error, an interrupted run (exit 130), any
# other exit code, an unreadable document, and every exit-3 reason
# not listed above (a scan that failed or timed out, skillspector
# missing, api.osv.dev unreachable, anything unforeseen). Those leave
# the last good record in place.
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <package> <built package> [<pkgs dir>]" >&2
  exit 2
fi
package=$1
built=$2
pkgs=${3:-pkgs}
agent_stacks=${AGENT_STACKS_BIN:-agent-stacks}

dest="$pkgs/$package/audit.json"
if [ ! -d "$pkgs/$package" ]; then
  echo "$package: no directory $pkgs/$package" >&2
  exit 2
fi
if [ ! -e "$built" ]; then
  echo "$package: built package $built does not exist" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The plugin directory inside the package: share/agent-plugins/<name>,
# the one directory there holding plugin.json. Handed to the CLI as the
# plugin itself rather than as the package, which an agent-stacks
# without package-shaped targets (before agent-stacks-cli #187) reads
# too. Always linked as ./result, so the document's `target` is the
# same on every machine and every run.
plugins=()
for d in "$built"/share/agent-plugins/*/; do
  [ -f "$d/plugin.json" ] && plugins+=("${d%/}")
done
if [ "${#plugins[@]}" -ne 1 ]; then
  echo "$package: $built holds ${#plugins[@]} plugins under share/agent-plugins, expected 1" >&2
  exit 2
fi
plugin=${plugins[0]}
case "$plugin" in
  /*) ;;
  *) plugin="$PWD/$plugin" ;;
esac
ln -s "$plugin" "$work/result"

rc=0
(cd "$work" && "$agent_stacks" audit ./result --json) \
  > "$work/out.json" 2> "$work/err.txt" || rc=$?

case "$rc" in
  0 | 1)
    if ! jq -e 'has("score") and has("tool")' "$work/out.json" > /dev/null 2>&1; then
      echo "$package: agent-stacks audit exited $rc without a readable result" >&2
      cat "$work/err.txt" >&2
      exit 2
    fi
    ;;
  3)
    # "ERROR: cannot audit ./result: <reason>", then hint lines
    # indented by two spaces.
    reason=$(sed -n 's/^ERROR: cannot audit [^:]*: //p' "$work/err.txt" | head -n 1)
    if [ -z "$reason" ]; then
      reason=$(grep -v '^[[:space:]]*$' "$work/err.txt" | head -n 1 || true)
    fi
    # Only what the plugin itself causes is its result: the CLI's
    # reasons from validating and reading it (agent-stacks-cli
    # internal/audit/audit/audit.go). Anything else is the run's.
    case "$reason" in
      "nothing to audit" | "not an agent plugin" | "not an agent plugin: "* | "cannot read the plugin: "*) ;;
      *)
        echo "$package: not the plugin's result: $reason" >&2
        exit 2
        ;;
    esac
    hints=$(sed -n 's/^  //p' "$work/err.txt" | jq -R . | jq -s .)
    version=$("${SKILLSPECTOR_BIN:-skillspector}" --version 2> /dev/null \
      | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n 1 || true)
    jq -n \
      --arg reason "$reason" \
      --argjson hints "$hints" \
      --arg version "$version" \
      '{
        target: "./result",
        audited: false,
        score: null,
        status: "could not audit",
        reason: $reason,
        hints: $hints,
        tool: { name: "skillspector", version: (if $version == "" then null else $version end) }
      }' > "$work/new.json.tmp"
    mv "$work/new.json.tmp" "$work/out.json"
    ;;
  *)
    echo "$package: agent-stacks audit exited $rc" >&2
    cat "$work/err.txt" >&2
    exit 2
    ;;
esac

agent_stacks_version=$("$agent_stacks" --version 2> /dev/null | head -n 1 || true)
if [ -z "$agent_stacks_version" ]; then
  echo "$package: $agent_stacks --version printed nothing" >&2
  exit 2
fi
jq --arg v "$agent_stacks_version" '. + { agentStacks: { version: $v } }' \
  "$work/out.json" > "$work/new.json"

# What a run changes without the result changing.
volatile='del(.tool.osv.checkedAt?) | del(.plugins[]?.dir)'

score=$(jq -r 'if .score == null then .status else "\(.score) \(.status)" end' "$work/new.json")

if [ ! -f "$dest" ]; then
  state=new
elif ! jq -S "$volatile" "$dest" > "$work/old.cmp" 2> /dev/null; then
  # A committed file that is not JSON is replaced.
  state=changed
else
  jq -S "$volatile" "$work/new.json" > "$work/new.cmp"
  if cmp -s "$work/old.cmp" "$work/new.cmp"; then
    state=unchanged
  else
    state=changed
  fi
fi

if [ "$state" != unchanged ]; then
  cp "$work/new.json" "$dest"
fi
echo "$package: $state ($score)"
