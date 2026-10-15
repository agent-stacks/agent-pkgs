#!/usr/bin/env bash
# Lints the workflows: actionlint (with shellcheck on every run: step,
# and with the local actions' inputs checked), then the one rule
# actionlint cannot know. Run from anywhere; needs actionlint,
# the shellcheck program and yq on PATH.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Bare, from the repository root: actionlint finds .github/workflows
# itself, and that is what makes it read ./.github/actions/* to check
# the `with:` inputs of each step that uses one.
actionlint

# The scripts the workflows call, which actionlint does not read.
shellcheck .github/actions/*/*.sh .github/scripts/*.sh

# The monitor job reports the run's result to Sentry, so a job missing
# from its `needs` is a job whose failure goes unreported. A job added
# later would otherwise be left out without anything failing.
#
# update-agent-plugins's `report` job is excluded on purpose: it fails
# the run whenever an upstream import failed, and a dead upstream is
# reported per upstream by the monitor instead, so counting it would
# page on every dead upstream hourly.
declare -A not_monitored=( ["update-agent-plugins.yml:report"]=1 )
status=0
for workflow in update-flake-lock update-agent-plugins update-agent-stacks; do
  file=".github/workflows/$workflow.yml"
  if [ "$(yq '.jobs.monitor | tag' "$file")" = '!!null' ]; then
    echo "$file has no monitor job" >&2
    status=1
    continue
  fi
  expected=""
  while IFS= read -r job; do
    [ "$job" = monitor ] && continue
    [ -n "${not_monitored["$workflow.yml:$job"]:-}" ] && continue
    expected+="$job"$'\n'
  done < <(yq '.jobs | keys | .[]' "$file")
  expected="$(printf '%s' "$expected" | sort)"
  actual="$(yq '.jobs.monitor.needs | (select(tag == "!!seq") | .[]), (select(tag == "!!str"))' "$file" | sort)"
  if [ "$expected" != "$actual" ]; then
    {
      echo "$file: the monitor job's needs must be every other job."
      echo "  expected: $(echo "$expected" | paste -sd, -)"
      echo "  actual:   $(echo "$actual" | paste -sd, -)"
    } >&2
    status=1
  fi
done
exit "$status"
