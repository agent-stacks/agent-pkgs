#!/usr/bin/env bash
# Reports an update workflow's run to Sentry. Never fails the run it
# observes: every problem ends in a ::warning:: and exit 0.
#
# Cron mode (SCHEDULE set): a start check-in when RESULTS is empty, a
# closing one when it holds toJSON(needs). Event mode (SCHEDULE empty):
# a failure event only, for a workflow that is dispatched rather than
# scheduled, so a missed check-in cannot mean anything.
#
# Inputs arrive as environment variables: DSN, MONITOR, SCHEDULE,
# RESULTS, FINGERPRINT_EXTRA.
set -uo pipefail

# Sentry upserts the monitor from every check-in, so this is the one
# place the monitors are configured; edits made in the Sentry UI are
# overwritten by the next check-in. Both workflows are hourly.
#
# checkin_margin: GitHub starts a scheduled run late. Recent hourly
# runs started p90 28-33 minutes after the cron time and at most 50-55,
# so a smaller margin reports a missed check-in on a run that is merely
# queued. max_runtime: the longest recent runs took 22 and 42 minutes.
# failure_issue_threshold 2: a single failed or missed run does not
# open an issue.
CHECKIN_MARGIN_MINUTES=60
MAX_RUNTIME_MINUTES=90
FAILURE_ISSUE_THRESHOLD=2
RECOVERY_THRESHOLD=1

warn() { echo "::warning::sentry-checkin: $*"; }

# post <url> <content-type> <body> [header]: never prints the url,
# which carries the DSN key.
post() {
  local headers=(-H "Content-Type: $2")
  [ -n "${4:-}" ] && headers+=(-H "$4")
  if ! printf '%s' "$3" | curl --fail --silent --show-error --retry 2 \
    --max-time 20 -X POST "${headers[@]}" --data-binary @- "$1" >/dev/null; then
    warn "could not reach Sentry; nothing was recorded for this call"
  fi
}

# DSN is https://KEY@HOST/PROJECT
dsn_rest="${DSN#*://}"
key="${dsn_rest%%@*}"
key="${key%%:*}"
hostpath="${dsn_rest#*@}"
host="${hostpath%%/*}"
project="${hostpath##*/}"
base="https://$host/api/$project"
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"

# One Sentry event: the fingerprint groups it, so a failure that repeats
# for the same cause stays one issue. The event id is derived from the
# fingerprint and run so a retried post cannot create a second event.
send_event() {
  local fingerprint="$1" message="$2" event_id
  event_id="$(printf '%s' "$fingerprint$GITHUB_RUN_ID" | sha256sum | cut -c1-32)"
  local event
  event="$(jq -nc --arg id "$event_id" --arg msg "$message" \
    --arg wf "$GITHUB_WORKFLOW" --arg url "$run_url" \
    --argjson fp "$fingerprint" --argjson ts "$(date +%s)" \
    '{event_id: $id, timestamp: $ts, platform: "other", level: "error",
      message: $msg, fingerprint: $fp, tags: {workflow: $wf},
      extra: {run_url: $url}}')" || return
  post "$base/envelope/" application/x-sentry-envelope \
    "$(printf '{"event_id":"%s"}\n{"type":"event"}\n%s' "$event_id" "$event")" \
    "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=$key"
}

# A rerun is a different attempt of a run already reported.
[ "$GITHUB_RUN_ATTEMPT" = 1 ] || exit 0

main() {
  local failed_run=false
  if [ -n "$RESULTS" ]; then
    [ "$(printf '%s' "$RESULTS" | jq -r '[.[].result] | any(. == "failure" or . == "cancelled")')" = true ] \
      && failed_run=true
  fi

  if [ -z "$SCHEDULE" ]; then
    # Event mode. A dispatch from another branch is a trial, not a release.
    [ -n "$RESULTS" ] && $failed_run && [ "$GITHUB_REF" = refs/heads/main ] || return 0
    send_event "$(jq -nc --arg x "$FINGERPRINT_EXTRA" \
      '["agent-pkgs", "update-agent-stacks", "failed", $x]')" \
      "$GITHUB_WORKFLOW failed"
    return 0
  fi

  # Cron mode. Dispatches and dry runs must not touch the production monitor.
  [ "$GITHUB_EVENT_NAME" = schedule ] || return 0

  local status=in_progress
  if [ -n "$RESULTS" ]; then
    status=ok
    $failed_run && status=error
  fi
  # The start step and the closing job run on different runners, so each
  # derives the same id from the run: run id and attempt as 32 digits.
  local check_in_id
  check_in_id="$(printf '%020d%012d' "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT")"
  post "$base/cron/$MONITOR/$key/" application/json "$(jq -nc \
    --arg id "$check_in_id" --arg status "$status" --arg sched "$SCHEDULE" \
    --argjson margin "$CHECKIN_MARGIN_MINUTES" --argjson runtime "$MAX_RUNTIME_MINUTES" \
    --argjson fthreshold "$FAILURE_ISSUE_THRESHOLD" --argjson rthreshold "$RECOVERY_THRESHOLD" \
    '{check_in_id: $id, status: $status, monitor_config: {
        schedule: {type: "crontab", value: $sched}, timezone: "UTC",
        checkin_margin: $margin, max_runtime: $runtime,
        failure_issue_threshold: $fthreshold, recovery_threshold: $rthreshold}}')"

  # A dead upstream does not fail the run (the plugins report job is left
  # out of RESULTS on purpose), so it alerts here, once per upstream. A
  # line of `failed` is the upstream, optionally followed by a note.
  [ -n "$RESULTS" ] || return 0
  local upstream
  while IFS= read -r upstream; do
    [ -n "$upstream" ] || continue
    send_event "$(jq -nc --arg u "$upstream" '["agent-pkgs", "plugin-import-failed", $u]')" \
      "import of $upstream failed"
  done < <(printf '%s' "$RESULTS" | jq -r \
    '(.prepare.outputs.failed // "") | split("\n") | map(split(" ")[0]) | map(select(. != "")) | unique[]')
}

if [ -z "$DSN" ]; then
  exit 0
fi
main || warn "unexpected error; nothing further was recorded"
exit 0
