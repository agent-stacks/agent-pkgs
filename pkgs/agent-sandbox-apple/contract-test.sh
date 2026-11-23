# The agent-sandbox-apple contract, without a Mac VM: the checks, the
# option refusals and the dry run, against a stub `container`.
#
#   bash contract-test.sh <path to agent-sandbox-apple>
set -euo pipefail
apple=$1

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

root=$PWD
export HOME=$root/home TMPDIR=$root/tmp
mkdir -p "$HOME" "$TMPDIR" "$root/bin"
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_PLUGIN_DIRS FLOX_FLOXHUB_TOKEN

# A stub container: --version and system status answer as 1.7.1 does
# (STUB_VERSION and STUB_NOT_RUNNING change them); anything else is
# logged, one line of argv, to $STUB_LOG.
{ echo "#!$(command -v bash)"; cat <<'EOF'
case "$*" in
  --version) echo "container CLI version ${STUB_VERSION:-1.7.1} (build: release, commit: a15b460)" ;;
  "system status")
    if [ -n "${STUB_NOT_RUNNING:-}" ]; then
      echo "apiserver is not running and not registered with launchd" >&2
      exit 1
    fi
    printf 'FIELD               VALUE\nstatus              running\nclient.version      1.7.1\n' ;;
  *) echo "$*" >>"${STUB_LOG:-/dev/null}" ;;
esac
EOF
} >"$root/bin/container"
# A stub flox: `flox auth token` prints tok.
{ echo "#!$(command -v bash)"; cat <<'EOF'
case "$1 $2" in
  "auth token") echo tok ;;
  *) echo "stub flox: $*" >&2; exit 1 ;;
esac
EOF
} >"$root/bin/flox"
chmod +x "$root/bin/container" "$root/bin/flox"
export PATH=$root/bin:$PATH
export AGENT_SANDBOX_APPLE_CONTAINER=$root/bin/container

# A local Flox environment, with Linux in its lock.
mkenv() { # <dir> <env.json> <lock>
  mkdir -p "$1/.flox/env"
  echo "$2" >"$1/.flox/env.json"
  echo 'version = 1' >"$1/.flox/env/manifest.toml"
  echo "$3" >"$1/.flox/env/manifest.lock"
}
linux_lock='{"lockfile-version":1,"manifest":{"options":{"systems":["aarch64-darwin","aarch64-linux"]}},"packages":[{"install_id":"hello","system":"aarch64-linux"}]}'
darwin_lock='{"lockfile-version":1,"manifest":{"options":{"systems":["aarch64-darwin"]}},"packages":[{"install_id":"hello","system":"aarch64-darwin"}]}'

# The project, with a space in its name, is also the environment.
p="$root/my proj"
mkdir -p "$p/.git/hooks"
echo '[core]' >"$p/.git/config"
mkenv "$p" '{"name":"my proj","version":1}' "$linux_lock"
export FLOX_ENV_PROJECT=$p

dir=$p
dry() { (cd "$dir" && AGENT_SANDBOX_APPLE_DRY_RUN=1 "$apple" "$@"); }
has() { jq -e "$@" out >/dev/null || fail "$1: $(cat out)"; }
mount_of() { jq -c --arg t "$1" '[.mounts[] | select(.target == $t)]' out; }

# --- The VM and its mounts ---------------------------------------------

dry -- claude >out 2>err || fail "dry run: $(cat err)"
has '.network == "none"'
has --arg p "$p" '[.mounts[] | select(.target == $p)] == [{source: $p, target: $p, readonly: false}]'
# One argument, spaces and all.
grep -qF -- "--mount $(printf %q "type=bind,source=$p,target=$p") " err ||
  fail "project mount not one argument: $(cat err)"
grep -q '^would run: container run ' err || fail "no would run: $(cat err)"
# .git is one read-only mount, with nothing inside it: container drops
# a mount that holds another, and only a mount point cannot be renamed.
nothing_inside() { has --arg g "$1" 'all(.mounts[]; .target | startswith($g + "/") | not)'; }
nothing_inside "$p/.git"
grep -qF -- "--mount $(printf %q "type=bind,source=$p/.git,target=$p/.git,readonly") " err ||
  fail ".git not mounted read-only: $(cat err)"
for t in "$p/.git" "$p/.flox"; do
  [ "$(mount_of "$t")" = "$(jq -nc --arg t "$t" '[{source: $t, target: $t, readonly: true}]')" ] ||
    fail "$t not read-only: $(mount_of "$t")"
done
has --arg e "$p/.flox/env" '[.mounts[] | select(.target == "/host-env")] == [{source: $e, target: "/host-env", readonly: true}]'
has --arg h "$HOME" 'all(.mounts[]; .source != $h and (.source | contains(".ssh") | not))'
sock=$(jq -r '.mounts[] | select(.target == "/run/agent-proxy.sock") | .source' out)
case $sock in
  /tmp/asa.??????/proxy.sock) ;;
  *) fail "socket not in a private temp folder: $sock" ;;
esac
[ ! -e "$(dirname "$sock")" ] || fail "the dry run left $(dirname "$sock") behind"
has '.name | test("^agent-sandbox-apple-my-proj-[a-z0-9]{5}$")'
has '.image | test("^agent-sandbox-apple:[0-9a-f]{12}$")'
has '.volume == "agent-sandbox-apple-nix-" + (.image | split(":")[1])'
has '.startup == ["api.flox.dev", "s3.us-east-1.amazonaws.com", "cache.nixos.org"]'
has '(.allow | sort) == (["api.anthropic.com", "platform.claude.com", "claude.ai", "console.anthropic.com"] | sort)'
has '.env == ["AGENT_SANDBOX_APPLE_UID"]'
for a in --rm --read-only "--network none" "--tmpfs /tmp" "--tmpfs /home/agent" \
  "-l agent-sandbox-apple=1" "-c 4" "-m 4G" "-e AGENT_SANDBOX_APPLE_UID"; do
  grep -qF -- " $a " err || fail "no $a: $(cat err)"
done

# Two launches from one folder: their own names and sockets.
jq -c '[.name, (.mounts[] | select(.target == "/run/agent-proxy.sock") | .source)]' out >first
dry -- claude >out 2>err || fail "dry run: $(cat err)"
jq -c '[.name, (.mounts[] | select(.target == "/run/agent-proxy.sock") | .source)]' out >second
jq -e -s '.[0][0] != .[1][0] and .[0][1] != .[1][1]' first second >/dev/null ||
  fail "two launches share a name or socket: $(cat first second)"

dry --options '{"writableGit":true,"cpus":2,"memory":"8G"}' -- claude >out 2>err ||
  fail "dry run: $(cat err)"
[ "$(mount_of "$p/.git")" = "$(jq -nc --arg t "$p/.git" '[{source: $t, target: $t, readonly: false}]')" ] ||
  fail ".git not read-write with writableGit: $(mount_of "$p/.git")"
nothing_inside "$p/.git"
[ "$(mount_of "$p/.flox" | jq -c 'map(.readonly)')" = "[true]" ] || fail ".flox not kept read-only: $(cat out)"
grep -q 'writableGit is on' err || fail "writableGit not named: $(cat err)"
grep -qF -- " -c 2 -m 8G " err || fail "cpus and memory not passed: $(cat err)"

# --- The allow-list ----------------------------------------------------

mkdir -p "$root/plugin"
echo '{"mcpServers":{"x":{"type":"http","url":"https://user@mcp.example.com:8443/mcp"},"local":{"command":"x"}}}' \
  >"$root/plugin/.mcp.json"
CLAUDE_CODE_PLUGIN_DIRS=$root/plugin dry --options '{"allowedDomains":["github.com"]}' -- claude >out 2>err ||
  fail "dry run: $(cat err)"
has '(.allow | sort) == (["api.anthropic.com", "platform.claude.com", "claude.ai", "console.anthropic.com",
  "mcp.example.com", "github.com"] | sort)'
has '.startup == ["api.flox.dev", "s3.us-east-1.amazonaws.com", "cache.nixos.org"]'
grep -q 'github.com' err || fail "allowedDomains not named: $(cat err)"

# --- Secrets -----------------------------------------------------------

CLAUDE_CODE_OAUTH_TOKEN=s3cret dry --options '{"forwardLogin":true}' -- claude >out 2>err ||
  fail "dry run with login: $(cat err)"
has '.env | index("CLAUDE_CODE_OAUTH_TOKEN")'
grep -q s3cret out err && fail "the OAuth token was printed"
grep -q 'forwardLogin' err && grep -q CLAUDE_CODE_OAUTH_TOKEN err || fail "forwarded login not named: $(cat err)"
grep -qE -- '-e [A-Za-z_]+=' err && fail "an -e with a value: $(cat err)"
dry --options '{"forwardFloxhubToken":true}' -- claude >out 2>err || fail "dry run with FloxHub: $(cat err)"
has '.env | index("FLOX_FLOXHUB_TOKEN")'
grep -qw tok out err && fail "the FloxHub token was printed"
grep -q forwardFloxhubToken err || fail "forwardFloxhubToken not named: $(cat err)"

# --- The command -------------------------------------------------------

CLAUDE_CODE_PLUGIN_DIRS=$root/plugin dry -- /some/store/bin/claude --flag "a b" >out 2>err ||
  fail "dry run: $(cat err)"
has '.command[0] == "/opt/agent-sandbox-apple/guest.sh"'
has '.command[-3:] == ["claude", "--flag", "a b"]'
has '.env | index("CLAUDE_CODE_PLUGIN_DIRS") | not'

# --- allowRead and allowWrite ------------------------------------------

mkdir -p "$root/data" "$root/writable"
dry --options "$(jq -nc --arg r "$root/data" --arg w "$root/writable" '{allowRead: [$r], allowWrite: [$w]}')" \
  -- claude >out 2>err || fail "dry run: $(cat err)"
has --arg r "$root/data" '.mounts | index({source: $r, target: $r, readonly: true})'
has --arg w "$root/writable" '.mounts | index({source: $w, target: $w, readonly: false})'
grep -q "$root/writable" err || fail "allowWrite not named: $(cat err)"

# --- A worktree, its gitdir relative -----------------------------------

git -c init.defaultBranch=main init -q "$root/main"
wt=$root/main/.git/worktrees/w
mkdir -p "$wt" "$root/w"
echo 'ref: refs/heads/w' >"$wt/HEAD"
echo ../.. >"$wt/commondir"
echo "$root/w/.git" >"$wt/gitdir"
echo 'gitdir: ../main/.git/worktrees/w' >"$root/w/.git"
dir=$root/w dry -- claude >out 2>err || fail "dry run in a worktree: $(cat err)"
g=$root/main/.git
for ro in true false; do
  has --arg w "$root/w/.git" --argjson ro "$ro" '.mounts | index({source: $w, target: $w, readonly: $ro})'
  has --arg g "$g" --argjson ro "$ro" '.mounts | index({source: $g, target: $g, readonly: $ro})'
  nothing_inside "$g"
  # The .git file, by -v as container takes a file.
  want=$(printf %q "$root/w/.git:$root/w/.git")
  [ "$ro" = false ] || want=$want:ro
  grep -qF -- " -v $want " err || fail ".git file not mounted: $(cat err)"
  dir=$root/w dry --options '{"writableGit":true}' -- claude >out 2>err || fail "dry run in a worktree: $(cat err)"
done

# --- Refusals ----------------------------------------------------------

refuse() { # <what> <message pattern> <command...>
  local what=$1 want=$2 rc=0
  shift 2
  "$@" >/dev/null 2>err || rc=$?
  [ "$rc" = 2 ] || fail "$what: exit $rc, not 2: $(cat err)"
  grep -q "^agent-sandbox-apple: " err || fail "$what: no reason: $(cat err)"
  [ -z "$want" ] || grep -q -- "$want" err || fail "$what: no '$want': $(cat err)"
}

refuse "unknown key" nope dry --options '{"nope":1}' -- claude
refuse "the old writableGitHooks" writableGitHooks dry --options '{"writableGitHooks":true}' -- claude
refuse "cpus as a string" cpus dry --options '{"cpus":"4"}' -- claude
refuse "not an object" "" dry --options '[1]' -- claude
refuse "allowRead ~" "" dry --options '{"allowRead":["~"]}' -- claude
refuse "allowRead of home" "" dry --options "$(jq -nc --arg h "$HOME" '{allowRead: [$h]}')" -- claude
refuse "allowWrite /" "" dry --options '{"allowWrite":["/"]}' -- claude
refuse "allowRead of the project's parent" project \
  dry --options "$(jq -nc --arg r "$root" '{allowRead: [$r]}')" -- claude
refuse "allowRead of the project" project \
  dry --options "$(jq -nc --arg r "$p" '{allowRead: [$r]}')" -- claude
refuse "allowRead missing" "" dry --options "$(jq -nc --arg r "$root/missing" '{allowRead: [$r]}')" -- claude
dir=$HOME refuse "run at ~" "project folder" dry -- claude
dir=/ refuse "run at /" "project folder" dry -- claude
refuse "forwardLogin with nothing to forward" "claude setup-token" dry --options '{"forwardLogin":true}' -- claude
(unset FLOX_ENV_PROJECT; refuse "no FLOX_ENV_PROJECT" "activated Flox environment" dry -- claude)
mkenv "$root/hub" '{"owner":"garbas","name":"demo","version":1}' "$linux_lock"
FLOX_ENV_PROJECT=$root/hub refuse "a FloxHub environment" FloxHub dry -- claude
mkenv "$root/mac" '{"name":"mac","version":1}' "$darwin_lock"
FLOX_ENV_PROJECT=$root/mac refuse "a lock without Linux" aarch64-linux dry -- claude
STUB_VERSION=1.5.0 refuse "container 1.5.0" 1.6.0 dry -- claude
grep -q 1.5.0 err || fail "installed version not named: $(cat err)"
STUB_NOT_RUNNING=1 refuse "system not running" "container system start" dry -- claude
AGENT_SANDBOX_APPLE_CONTAINER=$root/missing refuse "no container" 1.6.0 dry -- claude
refuse "nothing after --" "no command" dry --
refuse "no --" "" dry claude

echo "agent-sandbox-apple contract: OK"
