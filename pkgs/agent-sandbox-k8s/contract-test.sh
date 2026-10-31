# The agent-sandbox-k8s contract, without a cluster: option checks and
# the dry-run manifests, then the live run against a stub kubectl.
#
#   bash contract-test.sh <path to agent-sandbox-k8s>
set -euo pipefail
k8s=$1

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

root=$PWD
export HOME=$root/home TMPDIR=$root/tmp
mkdir -p "$HOME" "$TMPDIR" "$root/proj"
cd "$root/proj"

env_opt='{"environment":"garbas/claude-sandbox"}'

# --- Options -----------------------------------------------------------

AGENT_SANDBOX_K8S_DRY_RUN=1 "$k8s" --options "$env_opt" -- claude --version >out 2>err ||
  fail "dry run with a valid environment: $(cat err)"

for bad in '[1]' '{nope' '{"other":1}' '{"copyWorkspace":"yes"}' '{"ttl":5}' \
  '{"environment":""}' '{"ttl":"4 hours"}' \
  '{"environment":"garbas/claude-sandbox","copyWorkspace":false,"copyWorkspaceBack":true}'; do
  if AGENT_SANDBOX_K8S_DRY_RUN=1 "$k8s" --options "$bad" -- true >/dev/null 2>err; then
    fail "accepted $bad"
  fi
  [ -s err ] || fail "no reason for $bad"
done
if AGENT_SANDBOX_K8S_DRY_RUN=1 "$k8s" --options "$env_opt" echo no-separator >/dev/null 2>&1; then
  fail "ran without --"
fi

# --- Choosing the environment ------------------------------------------

dry() { AGENT_SANDBOX_K8S_DRY_RUN=1 "$k8s" "$@"; }

dry --options "$env_opt" -- claude >out 2>err || fail "dry run: $(cat err)"
grep -q 'garbas/claude-sandbox"' out || fail "environment option not used: $(cat out)"
dry --options '{"environment":"garbas/claude-sandbox:7"}' -- claude >out 2>err ||
  fail "dry run with a generation: $(cat err)"
grep -q 'garbas/claude-sandbox:7"' out || fail "generation not kept: $(cat out)"

# A stub flox: `flox list -a` prints what FLOX_STUB_LIST names.
mkdir -p "$root/bin"
cat >"$root/bin/flox" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "list -a") cat "$FLOX_STUB_LIST" ;;
  "auth token") echo "floxhub-secret-value" ;;
  *) echo "stub flox: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$root/bin/flox"
export PATH=$root/bin:$PATH

mkdir -p "$root/local/.flox" "$root/pushed/.flox"
echo '{"name":"x","version":1}' >"$root/local/.flox/env.json"
echo '{"owner":"garbas","name":"demo","floxhub_url":"https://hub.flox.dev/","version":1}' \
  >"$root/pushed/.flox/env.json"

if FLOX_ENV_PROJECT=$root/local dry -- claude >/dev/null 2>err; then fail "ran a local environment"; fi
grep -q 'flox push' err && grep -q 'environment' err || fail "no advice for a local environment: $(cat err)"

printf 'Environment:          garbas/demo\nGeneration:           12 (live)\nFloxHub:              generation 12\n' >"$root/list-live"
FLOX_STUB_LIST=$root/list-live FLOX_ENV_PROJECT=$root/pushed dry -- claude >out 2>err ||
  fail "pushed environment refused: $(cat err)"
grep -q 'garbas/demo:12"' out || fail "pushed generation not pinned: $(cat out)"

printf 'Generation:           12 with local changes\nFloxHub:              generation 12\n' >"$root/list-changed"
if FLOX_STUB_LIST=$root/list-changed FLOX_ENV_PROJECT=$root/pushed dry -- claude >/dev/null 2>err; then
  fail "ran an environment with local changes"
fi
grep -q 'flox push' err || fail "no advice for local changes: $(cat err)"

printf 'Generation:           13 (live)\nFloxHub:              generation 12 (local has unpushed history)\n' >"$root/list-ahead"
if FLOX_STUB_LIST=$root/list-ahead FLOX_ENV_PROJECT=$root/pushed dry -- claude >/dev/null 2>err; then
  fail "ran an unpushed generation"
fi

if (unset FLOX_ENV_PROJECT; dry -- claude) >/dev/null 2>err; then fail "ran with no environment"; fi
[ -s err ] || fail "no reason with no environment"

echo "agent-sandbox-k8s contract: OK"
