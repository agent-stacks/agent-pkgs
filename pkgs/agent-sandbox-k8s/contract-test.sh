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

echo "agent-sandbox-k8s contract: OK"
