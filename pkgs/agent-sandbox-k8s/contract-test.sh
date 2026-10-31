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

# --- Manifests ---------------------------------------------------------

# The dry run prints each manifest as JSON on stdout.
sandbox() { jq -s '.[] | select(.kind == "Sandbox")' out; }
secret() { jq -s '.[] | select(.kind == "Secret")' out; }

dry --options "$env_opt" -- /some/store/bin/claude --version >out 2>err || fail "dry run: $(cat err)"
sandbox | jq -e '
  .apiVersion == "agents.x-k8s.io/v1beta1"
  and .metadata.namespace == "agent-sandbox"
  and (.metadata.name | test("^claude-proj-[a-z0-9]{5}$"))
  and .metadata.labels["app.kubernetes.io/managed-by"] == "agent-sandbox-k8s"
  and .metadata.labels["agent-sandbox-k8s/agent"] == "claude"
  and .metadata.labels["agent-sandbox-k8s/project"] == "proj"
  and .spec.service == false
  and .spec.shutdownPolicy == "Delete"
  and .spec.podTemplate.metadata.annotations["flox.dev/environment"] == "garbas/claude-sandbox"
  and (.spec.podTemplate.spec | .runtimeClassName == "flox"
    and .automountServiceAccountToken == false
    and .securityContext == {runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, runAsNonRoot: true})
  and (.spec.podTemplate.spec.containers[0] | .image == "flox/empty:1.0.0"
    and .workingDir == "/workspace"
    and (.env | index({name: "HOME", value: "/home/agent"}) and index({name: "IS_SANDBOX", value: "1"}))
    and (.volumeMounts | index({name: "workspace", mountPath: "/workspace"})
      and index({name: "home", mountPath: "/home/agent"})))
  and (.spec.podTemplate.spec.volumes | index({name: "workspace", emptyDir: {}})
    and index({name: "home", emptyDir: {}}))' >/dev/null || fail "Sandbox: $(sandbox)"
[ -z "$(secret)" ] || fail "a Secret without forwarding"

# shutdownTime is now + ttl.
near() { sandbox | jq -e --argjson want "$(($(date +%s) + $1))" \
  '.spec.shutdownTime | fromdateiso8601 | . - $want | fabs < 60' >/dev/null; }
near 14400 || fail "shutdownTime is not now+4h: $(sandbox | jq .spec.shutdownTime)"
dry --options '{"environment":"garbas/claude-sandbox","ttl":"30m","namespace":"team"}' -- claude >out 2>err ||
  fail "dry run: $(cat err)"
near 1800 || fail "shutdownTime is not now+30m"
sandbox | jq -e '.metadata.namespace == "team"' >/dev/null || fail "namespace option not used"

# Names stay valid whatever the folder is called.
mkdir -p "$root/My Project_2" "$root/$(printf 'a%.0s' {1..100})"
(cd "$root/My Project_2" && dry --options "$env_opt" -- claude) >out 2>err || fail "dry run: $(cat err)"
sandbox | jq -e '.metadata.name | test("^claude-my-project-2-[a-z0-9]{5}$")' >/dev/null ||
  fail "name from 'My Project_2': $(sandbox | jq .metadata.name)"
(cd "$root/$(printf 'a%.0s' {1..100})" && dry --options "$env_opt" -- claude) >out 2>err || fail "dry run: $(cat err)"
sandbox | jq -e '.metadata.name | (length <= 63) and test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")' >/dev/null ||
  fail "long name: $(sandbox | jq .metadata.name)"

# Forwarded credentials go in the Secret, and never in the output.
login='{"environment":"garbas/claude-sandbox","forwardLogin":true}'
ANTHROPIC_API_KEY=sk-test-value-123 dry --options "$login" -- claude >out 2>err || fail "dry run: $(cat err)"
grep -q sk-test-value-123 out err && fail "the API key was printed"
name=$(sandbox | jq -r .metadata.name)
secret | jq -e --arg n "$name" '.metadata.name == $n and .data.ANTHROPIC_API_KEY == "<redacted>"
  and (.data | keys == ["ANTHROPIC_API_KEY"])' >/dev/null || fail "login Secret: $(secret)"
sandbox | jq -e --arg n "$name" '.spec.podTemplate.spec.containers[0].env
  | index({name: "ANTHROPIC_API_KEY", valueFrom: {secretKeyRef: {name: $n, key: "ANTHROPIC_API_KEY"}}})' >/dev/null ||
  fail "API key not read from the Secret"
CLAUDE_CODE_OAUTH_TOKEN=oauth-test-value dry --options "$login" -- claude >out 2>err || fail "dry run: $(cat err)"
grep -q oauth-test-value out err && fail "the OAuth token was printed"
secret | jq -e '.data | keys == ["CLAUDE_CODE_OAUTH_TOKEN"]' >/dev/null || fail "OAuth Secret: $(secret)"
if (unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN; dry --options "$login" -- claude) >/dev/null 2>err; then
  fail "forwardLogin with nothing to forward"
fi
[ -s err ] || fail "no reason for forwardLogin with nothing to forward"
ANTHROPIC_API_KEY=sk-test-value-123 dry --options "$login" -- codex >out 2>err || fail "dry run: $(cat err)"
[ -z "$(secret)" ] || fail "forwarded a Claude login to codex"

hub='{"environment":"garbas/claude-sandbox","forwardFloxhubToken":true}'
dry --options "$hub" -- claude >out 2>err || fail "dry run: $(cat err)"
grep -q floxhub-secret-value out err && fail "the FloxHub token was printed"
name=$(sandbox | jq -r .metadata.name)
secret | jq -e '.data | keys == ["floxhub-token"]' >/dev/null || fail "FloxHub Secret: $(secret)"
sandbox | jq -e --arg n "$name" '.spec.podTemplate.spec
  | (.volumes | index({name: "floxhub-token", secret: {secretName: $n, items: [{key: "floxhub-token", path: "floxhub-token"}]}}))
  and (.containers[0].volumeMounts | index({name: "floxhub-token", mountPath: "/var/run/secrets/flox.dev", readOnly: true}))' \
  >/dev/null || fail "FloxHub token not mounted: $(sandbox | jq .spec.podTemplate.spec)"

echo "agent-sandbox-k8s contract: OK"
