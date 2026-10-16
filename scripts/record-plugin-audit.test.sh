#!/usr/bin/env bash
# Runs record-plugin-audit.sh against a stub agent-stacks and a stub
# skillspector, so the gate needs no network, no SkillSpector and no
# built plugin. Usage: record-plugin-audit.test.sh <path to the script>
set -uo pipefail

script="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

mkdir -p "$root/bin" "$root/pkgs/agent-plugin-demo" \
  "$root/built/share/agent-plugins/demo"
echo '{}' > "$root/built/share/agent-plugins/demo/plugin.json"

# The shebang is bash's absolute path: the Linux nix sandbox has no
# /usr/bin/env. The stub prints STUB_OUT on stdout, STUB_ERR on
# stderr, and exits STUB_EXIT; --version prints STUB_VERSION.
{ echo "#!$(command -v bash)"; cat <<'STUB'
if [ "${1:-}" = --version ]; then echo "${STUB_VERSION:-1.0.0}"; exit 0; fi
[ -e ./result/plugin.json ] || { echo "stub: ./result is not the plugin" >&2; exit 9; }
printf '%s' "${STUB_OUT:-}"
printf '%s' "${STUB_ERR:-}" >&2
exit "${STUB_EXIT:-0}"
STUB
} > "$root/bin/agent-stacks"
{ echo "#!$(command -v bash)"; echo 'echo "SkillSpector v2.12.0"'; } > "$root/bin/skillspector"
chmod +x "$root/bin/agent-stacks" "$root/bin/skillspector"

failures=0
fail() { echo "FAIL [$case_name]: $*"; failures=$((failures + 1)); }

dest="$root/pkgs/agent-plugin-demo/audit.json"

# run_case <name> [VAR=value ...]. Leaves $out and $rc.
run_case() {
  case_name="$1"; shift
  out=$(cd "$root" && env -u AGENT_STACKS_BIN -u SKILLSPECTOR_BIN PATH="$root/bin:$PATH" "$@" \
    bash "$script" agent-plugin-demo built pkgs 2>&1)
  rc=$?
}

result() { # <score> <checkedAt> <dir>
  printf '{"target":"./result","plugins":[{"name":"demo","dir":"%s","score":%s}],"score":%s,"status":"caution","tool":{"name":"skillspector","version":"2.12.0","mode":"static","osv":{"live":true,"checkedAt":"%s"}}}' \
    "$3" "$1" "$1" "$2"
}

run_case "first run writes" STUB_OUT="$(result 51 2026-10-16T00:00:00Z /nix/store/a)"
[ "$rc" = 0 ] || fail "exit $rc: $out"
[[ "$out" == "agent-plugin-demo: new (51 caution)" ]] || fail "printed: $out"
[ "$(jq .score "$dest")" = 51 ] || fail "score not written"
[ "$(jq -r .agentStacks.version "$dest")" = 1.0.0 ] || fail "agentStacks.version not written"

cp "$dest" "$root/before"
run_case "only run fields differ" STUB_OUT="$(result 51 2026-10-17T03:00:00Z /nix/store/b)"
[[ "$out" == *": unchanged "* ]] || fail "printed: $out"
cmp -s "$dest" "$root/before" || fail "file was rewritten"

run_case "agent-stacks version differs" STUB_VERSION=1.1.0 \
  STUB_OUT="$(result 51 2026-10-17T03:00:00Z /nix/store/b)"
[[ "$out" == *": changed (51 caution)" ]] || fail "printed: $out"
[ "$(jq -r .agentStacks.version "$dest")" = 1.1.0 ] || fail "version not rewritten"

run_case "score differs" STUB_OUT="$(result 18 2026-10-17T03:00:00Z /nix/store/b)" STUB_EXIT=1
[ "$rc" = 0 ] || fail "exit 1 from audit is a result, got $rc"
[[ "$out" == *": changed (18 caution)" ]] || fail "printed: $out"
[ "$(jq -r .tool.osv.checkedAt "$dest")" = 2026-10-17T03:00:00Z ] || fail "not rewritten"

run_case "could not audit" STUB_EXIT=3 \
  STUB_ERR=$'ERROR: cannot audit ./result: nothing to audit\n  a hint\n'
[ "$rc" = 0 ] || fail "exit $rc: $out"
[[ "$out" == *": changed (could not audit)" ]] || fail "printed: $out"
jq -e '.audited == false and .score == null and .reason == "nothing to audit"
  and .hints == ["a hint"] and .tool.version == "2.12.0"' "$dest" > /dev/null \
  || fail "record: $(cat "$dest")"

run_case "not an agent plugin is the plugin's" STUB_EXIT=3 \
  STUB_ERR="ERROR: cannot audit ./result: not an agent plugin: skills: no skill"
[ "$rc" = 0 ] || fail "exit $rc: $out"
jq -e '.audited == false and .reason == "not an agent plugin: skills: no skill"
  and .agentStacks.version == "1.0.0"' "$dest" > /dev/null || fail "record: $(cat "$dest")"

cp "$dest" "$root/before"
for reason in "api.osv.dev is unreachable" "skillspector is not on PATH" \
  "skillspector timed out scanning skills/x" "skillspector could not scan skills/x" \
  "some error nobody foresaw" interrupted; do
  run_case "runner fault: $reason" STUB_EXIT=3 STUB_ERR="ERROR: cannot audit ./result: $reason"
  [ "$rc" = 2 ] || fail "exit $rc, want 2"
  cmp -s "$dest" "$root/before" || fail "file was written"
done

run_case "interrupted" STUB_EXIT=130 STUB_ERR="ERROR: cannot audit ./result: interrupted"
[ "$rc" = 2 ] || fail "exit $rc, want 2"
cmp -s "$dest" "$root/before" || fail "file was written"

run_case "usage error" STUB_EXIT=2 STUB_ERR="ERROR: usage"
[ "$rc" = 2 ] || fail "exit $rc, want 2"

run_case "unreadable result" STUB_OUT="not json"
[ "$rc" = 2 ] || fail "exit $rc, want 2"
cmp -s "$dest" "$root/before" || fail "file was written"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "record-plugin-audit: all cases pass"
