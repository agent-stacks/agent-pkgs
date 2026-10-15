#!/usr/bin/env bash
# Runs checkin.sh against a stub curl that records each call, so the
# gate needs no network and no Sentry. Usage: test.sh <path to checkin.sh>
set -uo pipefail

script="$1"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

mkdir -p "$root/bin"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Records one file pair per call: args, and the request body from stdin
# or from a --data-binary @- argument.
n=$(( $(ls "$STUB_LOG" | wc -l) / 2 + 1 ))
printf '%s\n' "$@" > "$STUB_LOG/$n.args"
cat > "$STUB_LOG/$n.body"
exit "${STUB_CURL_EXIT:-0}"
STUB
chmod +x "$root/bin/curl"

failures=0
fail() { echo "FAIL [$case_name]: $*"; failures=$((failures + 1)); }

# run_case <name> [VAR=value ...]: runs the script from a clean base
# environment with the overrides applied. Leaves $out, $rc and $log.
run_case() {
  case_name="$1"; shift
  log="$root/log-$case_name"
  rm -rf "$log"; mkdir -p "$log"
  out="$(env -i PATH="$root/bin:$PATH" STUB_LOG="$log" \
    DSN="https://abc123key@sentry.example.test/4242" \
    MONITOR="my-monitor" SCHEDULE="37 * * * *" RESULTS="" FINGERPRINT_EXTRA="" \
    GITHUB_RUN_ID=1234567890 GITHUB_RUN_ATTEMPT=1 \
    GITHUB_EVENT_NAME=schedule GITHUB_REF=refs/heads/main \
    GITHUB_REPOSITORY=agent-stacks/agent-pkgs GITHUB_SERVER_URL=https://github.com \
    GITHUB_WORKFLOW="Update flake.lock" \
    "$@" bash "$script" 2>&1)"
  rc=$?
}

calls() { ls "$log" | grep -c '\.args$'; }
expect_exit_zero() { [ "$rc" -eq 0 ] || fail "exit $rc, wanted 0"; }
expect_calls() { [ "$(calls)" -eq "$1" ] || fail "$(calls) curl calls, wanted $1"; }
# expect_jq <call> <jq filter> <wanted>: the filter runs on the call's body.
expect_jq() {
  local got
  got="$(jq -c "$2" "$log/$1.body" 2>&1)"
  [ "$got" = "$3" ] || fail "call $1 body $2 = $got, wanted $3"
}
expect_arg() { grep -qxF -- "$2" "$log/$1.args" || fail "call $1 args lack: $2"; }

needs_ok='{"prepare":{"result":"success","outputs":{}},"verify":{"result":"skipped","outputs":{}},"land":{"result":"success","outputs":{}}}'
needs_failed='{"prepare":{"result":"success","outputs":{}},"verify":{"result":"failure","outputs":{}},"land":{"result":"skipped","outputs":{}}}'
needs_cancelled='{"prepare":{"result":"success","outputs":{}},"verify":{"result":"cancelled","outputs":{}},"land":{"result":"skipped","outputs":{}}}'

run_case empty-dsn DSN="" RESULTS="$needs_failed"
expect_exit_zero; expect_calls 0

run_case dispatch-sends-no-checkin GITHUB_EVENT_NAME=workflow_dispatch
expect_exit_zero; expect_calls 0

run_case dispatch-sends-no-finish GITHUB_EVENT_NAME=workflow_dispatch RESULTS="$needs_failed"
expect_exit_zero; expect_calls 0

run_case rerun-sends-nothing GITHUB_RUN_ATTEMPT=2 RESULTS="$needs_failed"
expect_exit_zero; expect_calls 0

run_case start
expect_exit_zero; expect_calls 1
expect_arg 1 "https://sentry.example.test/api/4242/cron/my-monitor/abc123key/"
expect_jq 1 .status '"in_progress"'
expect_jq 1 .check_in_id '"00000000001234567890000000000001"'
expect_jq 1 .monitor_config '{"schedule":{"type":"crontab","value":"37 * * * *"},"timezone":"UTC","checkin_margin":60,"max_runtime":90,"failure_issue_threshold":2,"recovery_threshold":1}'

run_case success-and-skipped-is-ok RESULTS="$needs_ok"
expect_exit_zero; expect_calls 1
expect_jq 1 .status '"ok"'
expect_jq 1 .check_in_id '"00000000001234567890000000000001"'
expect_jq 1 .monitor_config.schedule.value '"37 * * * *"'

run_case failure-is-error RESULTS="$needs_failed"
expect_exit_zero; expect_calls 1
expect_jq 1 .status '"error"'

run_case cancelled-is-error RESULTS="$needs_cancelled"
expect_exit_zero; expect_calls 1
expect_jq 1 .status '"error"'

fail_rev=0123456789abcdef0123456789abcdef01234567
run_case event-failure-posts-envelope SCHEDULE="" RESULTS="$needs_failed" \
  FINGERPRINT_EXTRA="$fail_rev" GITHUB_EVENT_NAME=workflow_dispatch \
  GITHUB_WORKFLOW="Update agent-stacks"
expect_exit_zero; expect_calls 1
expect_arg 1 "https://sentry.example.test/api/4242/envelope/"
expect_arg 1 "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=abc123key"
envelope="$log/1.body"
[ "$(grep -c "" "$envelope")" -eq 3 ] || fail "envelope is not three lines"
got="$(sed -n 3p "$envelope" | jq -c '[.fingerprint, .tags.workflow, .extra.run_url, .level]')"
want='[["agent-pkgs","update-agent-stacks","failed","'"$fail_rev"'"],"Update agent-stacks","https://github.com/agent-stacks/agent-pkgs/actions/runs/1234567890","error"]'
[ "$got" = "$want" ] || fail "event payload $got, wanted $want"

run_case event-success-sends-nothing SCHEDULE="" RESULTS="$needs_ok" \
  FINGERPRINT_EXTRA="$fail_rev" GITHUB_EVENT_NAME=workflow_dispatch
expect_exit_zero; expect_calls 0

run_case event-start-sends-nothing SCHEDULE="" GITHUB_EVENT_NAME=workflow_dispatch
expect_exit_zero; expect_calls 0

run_case event-off-main-sends-nothing SCHEDULE="" RESULTS="$needs_failed" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/some-branch
expect_exit_zero; expect_calls 0

needs_dead_upstreams='{"prepare":{"result":"success","outputs":{"failed":"owner-a/repo-a\nowner-b/repo-b (not staged: its shard collided with another)\nowner-a/repo-a"}},"verify":{"result":"success","outputs":{}},"land":{"result":"success","outputs":{}}}'
run_case dead-upstreams-one-event-each RESULTS="$needs_dead_upstreams"
expect_exit_zero; expect_calls 3
expect_jq 1 .status '"ok"'
expect_arg 2 "https://sentry.example.test/api/4242/envelope/"
got="$(for i in 2 3; do sed -n 3p "$log/$i.body" | jq -c .fingerprint; done)"
want='["agent-pkgs","plugin-import-failed","owner-a/repo-a"]
["agent-pkgs","plugin-import-failed","owner-b/repo-b"]'
[ "$got" = "$want" ] || fail "import-failure fingerprints $got, wanted $want"

run_case curl-failure-still-exits-zero STUB_CURL_EXIT=22 RESULTS="$needs_failed"
expect_exit_zero
case "$out" in *"::warning::"*) ;; *) fail "no ::warning:: on curl failure: $out" ;; esac
case "$out" in *abc123key*) fail "the DSN key leaked into the output" ;; esac

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "sentry-checkin: all cases passed"
