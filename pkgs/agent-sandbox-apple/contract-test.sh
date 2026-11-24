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
# logged, one line of argv, to $STUB_LOG. The image and the volume exist
# with STUB_IMAGE and STUB_VOLUME, and the volume is filled unless
# STUB_UNFILLED, and its check fails outright, with an error on stderr,
# with STUB_CHECK_FAIL; the
# check sleeps STUB_CHECK_SLEEP seconds instead, its pid in
# $STUB_DIR/check.pid. The agent's run checks the stub proxy is up, runs
# STUB_RUN_HOOK, prints STUB_RUN_ERR on stderr, sleeps STUB_RUN_SLEEP
# seconds and exits STUB_RUN_RC.
{ echo "#!$(command -v bash)"; cat <<'EOF'
case "$*" in
  --version) echo "container CLI version ${STUB_VERSION:-1.7.1} (build: release, commit: a15b460)" ;;
  "system status")
    if [ -n "${STUB_NOT_RUNNING:-}" ]; then
      echo "apiserver is not running and not registered with launchd" >&2
      exit 1
    fi
    printf 'FIELD               VALUE\nstatus              running\nclient.version      1.7.1\n' ;;
  *)
    echo "$*" >>"${STUB_LOG:-/dev/null}"
    case "$1 $2" in
      "image inspect") [ -n "${STUB_IMAGE:-}" ] ;;
      "volume inspect") [ -n "${STUB_VOLUME:-}" ] ;;
      run\ *)
        case "$*" in
          *"test -f /nix-cache/.agent-sandbox-apple-filled;"*)
            echo $$ >"$STUB_DIR/check.pid"
            [ -z "${STUB_CHECK_SLEEP:-}" ] || exec sleep "$STUB_CHECK_SLEEP"
            if [ -n "${STUB_CHECK_FAIL:-}" ]; then
              echo "Error: stub: volume is in use by agent-sandbox-apple-x" >&2
              exit 1
            fi
            if [ -z "${STUB_UNFILLED:-}" ]; then echo filled; else echo empty; fi ;;
          *guest.sh*)
            echo $$ >"$STUB_DIR/run.pid"
            if kill -0 "$(cat "$STUB_DIR/proxy.pid" 2>/dev/null)" 2>/dev/null; then
              echo "proxy up" >>"$STUB_LOG"
            fi
            [ -z "${STUB_RUN_HOOK:-}" ] || bash -c "$STUB_RUN_HOOK"
            [ -z "${STUB_RUN_ERR:-}" ] || echo "$STUB_RUN_ERR" >&2
            [ -z "${STUB_RUN_SLEEP:-}" ] || exec sleep "$STUB_RUN_SLEEP"
            exit "${STUB_RUN_RC:-0}"
            ;;
        esac
        ;;
    esac
    ;;
esac
EOF
} >"$root/bin/container"
# A stub proxy: logs its argv and its lists to $STUB_DIR, says ready,
# and logs TERM when it gets one. STUB_PROXY_DENY_FLOX writes a deny of
# api.flox.dev into its log.
{ echo "#!$(command -v bash)"; cat <<'EOF'
echo "$*" >"$STUB_DIR/proxy.argv"
while [ $# -gt 0 ]; do
  case $1 in
    --allow) cp "$2" "$STUB_DIR/proxy.allow" ;;
    --startup) cp "$2" "$STUB_DIR/proxy.startup" ;;
    --log)
      echo "allow api.anthropic.com:443 -> 160.79.104.10" >>"$2"
      [ -z "${STUB_PROXY_DENY_FLOX:-}" ] || echo "deny api.flox.dev:443 (resolve: failed)" >>"$2"
      echo "latch closed" >>"$2"
      ;;
  esac
  shift 2
done
echo $$ >"$STUB_DIR/proxy.pid"
trap 'echo TERM >>"$STUB_DIR/proxy.signals"; kill "$s" 2>/dev/null; exit 0' TERM
echo ready
sleep 300 &
s=$!
wait "$s"
EOF
} >"$root/bin/proxy"
chmod +x "$root/bin/proxy"
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
# Nothing secret by default: only the switch that keeps claude.ai
# connectors off.
has '.env == ["ENABLE_CLAUDEAI_MCP_SERVERS"]'
grep -q AGENT_SANDBOX_APPLE_UID out err && fail "AGENT_SANDBOX_APPLE_UID still passed: $(cat err)"
for a in --rm --read-only "--network none" "--tmpfs /tmp" "--tmpfs /home/agent" \
  "-l agent-sandbox-apple=1" "-c 4" "-m 4G"; do
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
# The plugins' MCP hosts come from the VM's environment, at the latch:
# the plugins this shell staged add nothing.
has '(.allow | sort) == (["api.anthropic.com", "platform.claude.com", "claude.ai", "console.anthropic.com",
  "github.com"] | sort)'
has '.startup == ["api.flox.dev", "s3.us-east-1.amazonaws.com", "cache.nixos.org"]'
grep -q 'github.com' err || fail "allowedDomains not named: $(cat err)"

# claude.ai connectors: off by default, and then Claude is told so.
has '.env | index("ENABLE_CLAUDEAI_MCP_SERVERS")'
has '.allow | index("mcp-proxy.anthropic.com") | not'
dry --options '{"claudeConnectors":true}' -- claude >out 2>err || fail "dry run with connectors: $(cat err)"
has '.allow | index("mcp-proxy.anthropic.com")'
has '.env | index("ENABLE_CLAUDEAI_MCP_SERVERS") | not'
grep -q 'claudeConnectors is on' err || fail "claudeConnectors not named: $(cat err)"

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

# --- An environment in a folder of the project ------------------------

# Its .flox runs as root at activation, so it is read-only too.
mkenv "$p/sub" '{"name":"sub","version":1}' "$linux_lock"
FLOX_ENV_PROJECT=$p/sub dry -- claude >out 2>err || fail "dry run with a nested env: $(cat err)"
has --arg f "$p/sub/.flox" '.mounts | index({source: $f, target: $f, readonly: true})'
has --arg f "$p/.flox" '.mounts | index({source: $f, target: $f, readonly: true})'
has --arg e "$p/sub/.flox/env" '.mounts | index({source: $e, target: "/host-env", readonly: true})'
# An environment outside the project adds no mount of its .flox.
mkenv "$root/outside" '{"name":"outside","version":1}' "$linux_lock"
FLOX_ENV_PROJECT=$root/outside dry -- claude >out 2>err || fail "dry run with an outside env: $(cat err)"
has --arg f "$root/outside/.flox" 'all(.mounts[]; .target != $f)'

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
refuse "a non-boolean claudeConnectors" claudeConnectors dry --options '{"claudeConnectors":"yes"}' -- claude
refuse "cpus as a string" cpus dry --options '{"cpus":"4"}' -- claude
for v in false null; do
  refuse "cpus $v" cpus dry --options "{\"cpus\":$v}" -- claude
  refuse "memory $v" memory dry --options "{\"memory\":$v}" -- claude
done
refuse "not an object" "" dry --options '[1]' -- claude
refuse "allowRead ~" "" dry --options '{"allowRead":["~"]}' -- claude
refuse "allowRead of home" "" dry --options "$(jq -nc --arg h "$HOME" '{allowRead: [$h]}')" -- claude
refuse "allowWrite /" "" dry --options '{"allowWrite":["/"]}' -- claude
refuse "allowRead of the project's parent" project \
  dry --options "$(jq -nc --arg r "$root" '{allowRead: [$r]}')" -- claude
refuse "allowRead of the project" project \
  dry --options "$(jq -nc --arg r "$p" '{allowRead: [$r]}')" -- claude
# Inside the project, a mount would sit over .git or .flox, whose
# mounts container then drops.
for inside in "$p/.git/hooks" "$p/.git" "$p/.flox/env"; do
  for kind in allowRead allowWrite; do
    refuse "$kind of $inside" project \
      dry --options "$(jq -nc --arg k "$kind" --arg r "$inside" '{($k): [$r]}')" -- claude
  done
done
refuse "allowRead missing" "" dry --options "$(jq -nc --arg r "$root/missing" '{allowRead: [$r]}')" -- claude
dir=$HOME refuse "run at ~" "project folder" dry -- claude
dir=/ refuse "run at /" "project folder" dry -- claude
dir=$(dirname "$HOME") refuse "run at a folder holding ~" "project folder" dry -- claude
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

# --- A real launch, against the stubs ----------------------------------

# A stand-in container does not skip the platform checks: off the Mac,
# or in the nix build sandbox (no sw_vers), a launch is refused. Only
# AGENT_SANDBOX_APPLE_SKIP_PLATFORM=1, set below, skips them.
if ! { [ "$(uname -s)" = Darwin ] && sw_vers -productVersion >/dev/null 2>&1; }; then
  real() { (cd "$dir" && "$apple" "$@"); }
  refuse "a stand-in container on a system that is not macOS 26" "macOS 26" real -- claude
fi
export AGENT_SANDBOX_APPLE_SKIP_PLATFORM=1

export STUB_DIR=$root/stub STUB_LOG=$root/stub/container.log AGENT_SANDBOX_APPLE_PROXY=$root/bin/proxy
# <stub env...> -- <sandbox args...>: runs in $dir with fresh stub logs;
# its exit code is in $rc, its stdout and stderr in out and err.
launch() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  rm -rf "$STUB_DIR" && mkdir -p "$STUB_DIR" && : >"$STUB_LOG"
  rc=0
  (cd "$dir" && env "${envs[@]}" "$apple" "$@") >out 2>err || rc=$?
}
# The stub's log holds lines matching each pattern, in this order.
in_order() {
  local pat line
  exec 3<"$STUB_LOG"
  for pat in "$@"; do
    while IFS= read -r line <&3; do [[ $line =~ $pat ]] && continue 2; done
    exec 3<&-
    fail "no '$pat' in order in: $(cat "$STUB_LOG")"
  done
  exec 3<&-
}
dir=$p
dry -- claude >out 2>err || fail "dry run: $(cat err)"
image=$(jq -r .image out) volume=$(jq -r .volume out)
dry --options '{"allowedDomains":["github.com"]}' -- claude >out 2>err || fail "dry run: $(cat err)"
want_allow=$(jq -r '.allow[]' out) want_startup=$(jq -r '.startup[]' out)
q() { printf '%s' "$1" | sed 's/[][\.*^$()+?{}|]/\\&/g'; }

# A first launch: it builds the image, creates and fills the volume,
# then runs the agent with the proxy up.
launch -- --options '{"allowedDomains":["github.com"]}' -- claude --version
[ "$rc" = 0 ] || fail "first launch: exit $rc: $(cat err)"
in_order "^image inspect $(q "$image")\$" "^build -t $(q "$image") /" \
  "^volume inspect $(q "$volume")\$" "^volume create $(q "$volume")\$" \
  "^run --rm .*-v $(q "$volume"):/nix-cache .*cp -a /nix/\. /nix-cache/.*touch /nix-cache/\.agent-sandbox-apple-filled\$" \
  "^run --rm .*--network none .* $(q "$image") /opt/agent-sandbox-apple/guest\.sh claude --version\$" \
  "^proxy up\$"
ctx=$(sed -n "s|^build -t $(q "$image") ||p" "$STUB_LOG")
[ -f "$ctx/Containerfile" ] && [ -f "$ctx/guest.sh" ] || fail "build context $ctx is not the share dir"
[ "${image#*:}" = "$(cat "$ctx/Containerfile" "$ctx/guest.sh" | sha256sum | cut -c1-12)" ] ||
  fail "tag ${image#*:} is not the hash of the Containerfile and guest.sh"
for s in image volume fill; do
  grep -qi "^agent-sandbox-apple: .*$s" err || fail "no line before the $s step: $(cat err)"
done
[ "$(cat "$STUB_DIR/proxy.allow")" = "$want_allow" ] || fail "proxy --allow: $(cat "$STUB_DIR/proxy.allow")"
[ "$(cat "$STUB_DIR/proxy.startup")" = "$want_startup" ] || fail "proxy --startup: $(cat "$STUB_DIR/proxy.startup")"
grep -q TERM "$STUB_DIR/proxy.signals" || fail "the proxy got no SIGTERM"
sock=$(sed -n 's/.*--socket \([^ ]*\).*/\1/p' "$STUB_DIR/proxy.argv")
case $sock in /tmp/asa.??????/proxy.sock) ;; *) fail "proxy socket: $sock" ;; esac
[ ! -e "$(dirname "$sock")" ] || fail "$(dirname "$sock") left behind"
name=$(sed -n '/guest\.sh/s/.*--name \([^ ]*\).*/\1/p' "$STUB_LOG")
plog=$TMPDIR/$name.log
grep -qx 'latch closed' "$plog" || fail "proxy log not kept at $plog"
grep -qF "$plog" err || fail "proxy log path not printed: $(cat err)"
grep -qi floxhub err && fail "FloxHub hint on a clean run: $(cat err)"

# The image and a filled volume exist: straight to the run.
launch STUB_IMAGE=1 STUB_VOLUME=1 -- -- claude --version
[ "$rc" = 0 ] || fail "warm launch: exit $rc: $(cat err)"
grep -qE '^(build|volume create)|cp -a' "$STUB_LOG" && fail "warm launch built or filled: $(cat "$STUB_LOG")"
in_order "^image inspect " "^volume inspect " "test -f /nix-cache/\.agent-sandbox-apple-filled;" \
  "guest\.sh claude --version\$"
grep -qE '^agent-sandbox-apple: .*(image|volume|fill)' err && fail "warm launch announced slow work: $(cat err)"
# Each finished run removed its own VM (--rm): nothing to delete.
grep -q '^delete' "$STUB_LOG" && fail "a clean launch deleted VMs: $(cat "$STUB_LOG")"
# The check and fill VMs are named, so clean-up can find them.
grep -qE '^run --rm --name agent-sandbox-apple-check-[a-z0-9]{5} .*test -f ' "$STUB_LOG" ||
  fail "the check run has no name: $(cat "$STUB_LOG")"

# A volume whose fill never finished is filled again.
launch STUB_IMAGE=1 STUB_VOLUME=1 STUB_UNFILLED=1 -- -- claude
[ "$rc" = 0 ] || fail "unfilled launch: exit $rc: $(cat err)"
grep -q '^volume create' "$STUB_LOG" && fail "an existing volume created again"
in_order "test -f /nix-cache/\.agent-sandbox-apple-filled;" "cp -a /nix/\. /nix-cache/" "guest\.sh claude\$"

# A check that fails outright (the volume in use by another launch)
# does not fill: a fill over a used volume undoes its Nix database.
launch STUB_IMAGE=1 STUB_VOLUME=1 STUB_CHECK_FAIL=1 -- -- claude
[ "$rc" = 2 ] || fail "a failed check gave exit $rc: $(cat err)"
grep -q 'another running' err || fail "no reason for a failed check: $(cat err)"
# A VM left stopped (the launcher killed before its clean-up) holds the
# volume too, and only `container list -a` shows it.
grep -qF "'container list -a'" err || fail "the refusal does not point at container list -a: $(cat err)"
grep -qF 'container delete' err || fail "the refusal does not say how to delete a stopped VM: $(cat err)"
grep -qF 'stub: volume is in use by agent-sandbox-apple-x' err ||
  fail "the refusal does not show container's error: $(cat err)"
grep -qE 'cp -a|guest\.sh' "$STUB_LOG" && fail "a failed check filled or ran: $(cat "$STUB_LOG")"

# The agent's exit code is the sandbox's, and the clean-up still runs.
launch STUB_IMAGE=1 STUB_VOLUME=1 STUB_RUN_RC=3 -- -- claude
[ "$rc" = 3 ] || fail "agent exit 3 gave $rc: $(cat err)"
grep -q TERM "$STUB_DIR/proxy.signals" || fail "the proxy got no SIGTERM after exit 3"
sock=$(sed -n 's/.*--socket \([^ ]*\).*/\1/p' "$STUB_DIR/proxy.argv")
[ ! -e "$(dirname "$sock")" ] || fail "$(dirname "$sock") left behind after exit 3"

# A signal mid-run: the same clean-up.
rm -rf "$STUB_DIR" && mkdir -p "$STUB_DIR" && : >"$STUB_LOG"
(cd "$dir" && STUB_IMAGE=1 STUB_VOLUME=1 STUB_RUN_SLEEP=30 exec "$apple" -- claude) >out 2>err &
bg=$!
for _ in $(seq 100); do grep -q '^proxy up' "$STUB_LOG" && break; sleep 0.1; done
grep -q '^proxy up' "$STUB_LOG" || fail "the run never started: $(cat err)"
kill -TERM "$bg"
rc=0
wait "$bg" || rc=$?
[ "$rc" = 143 ] || fail "SIGTERM gave exit $rc: $(cat err)"
name=$(sed -n '/guest\.sh/s/.*--name \([^ ]*\).*/\1/p' "$STUB_LOG")
in_order "guest\.sh claude\$" "^stop $name\$" "^delete -f $name\$"
! kill -0 "$(cat "$STUB_DIR/run.pid")" 2>/dev/null || fail "container run still running after a signal"
grep -q TERM "$STUB_DIR/proxy.signals" || fail "the proxy got no SIGTERM after a signal"
sock=$(sed -n 's/.*--socket \([^ ]*\).*/\1/p' "$STUB_DIR/proxy.argv")
[ ! -e "$(dirname "$sock")" ] || fail "$(dirname "$sock") left behind after a signal"

# A signal while the check of the fill runs: its VM is deleted, as its
# `container run`, cut short, never removes it, and a VM left holding
# the volume stops every later launch.
rm -rf "$STUB_DIR" && mkdir -p "$STUB_DIR" && : >"$STUB_LOG"
(cd "$dir" && STUB_IMAGE=1 STUB_VOLUME=1 STUB_CHECK_SLEEP=30 exec "$apple" -- claude) >out 2>err &
bg=$!
for _ in $(seq 100); do [ -s "$STUB_DIR/check.pid" ] && break; sleep 0.1; done
[ -s "$STUB_DIR/check.pid" ] || fail "the check never started: $(cat err)"
kill -TERM "$bg"
kill -TERM "$(cat "$STUB_DIR/check.pid")"
rc=0
wait "$bg" || rc=$?
[ "$rc" = 143 ] || fail "SIGTERM during the check gave exit $rc: $(cat err)"
check=$(sed -n '/test -f/s/.*--name \([^ ]*\).*/\1/p' "$STUB_LOG")
[ -n "$check" ] || fail "no named check run: $(cat "$STUB_LOG")"
in_order "test -f /nix-cache/" "^delete -f $check\$"
grep -q 'guest\.sh' "$STUB_LOG" && fail "the agent ran after a signal: $(cat "$STUB_LOG")"

# --- writableGit: hooks and config are checked at exit -----------------

git -c init.defaultBranch=main init -q "$p"
echo 'echo hi' >"$p/.git/hooks/pre-commit"
launch STUB_IMAGE=1 STUB_VOLUME=1 -- --options '{"writableGit":true}' -- claude
[ "$rc" = 0 ] || fail "writableGit, nothing changed: exit $rc: $(cat err)"
grep -q 'changed during the session' err && fail "writableGit warned with nothing changed: $(cat err)"
hook=$p/.git/hooks/pre-commit
launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=echo evil >>$(printf %q "$hook")" -- --options '{"writableGit":true}' -- claude
[ "$rc" = 3 ] || fail "a changed hook gave exit $rc: $(cat err)"
grep -qF "$hook" err || fail "the changed hook not named: $(cat err)"
grep -q 'git hooks or config changed during the session; review them before running git here' err ||
  fail "no warning for a changed hook: $(cat err)"
echo 'echo hi' >"$hook"
new=$p/.git/hooks/post-checkout
launch STUB_IMAGE=1 STUB_VOLUME=1 STUB_RUN_RC=5 "STUB_RUN_HOOK=echo evil >$(printf %q "$new")" \
  -- --options '{"writableGit":true}' -- claude
[ "$rc" = 5 ] || fail "a new hook after exit 5 gave exit $rc: $(cat err)"
grep -qF "$new" err || fail "the new hook not named: $(cat err)"
rm -f "$new"
launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=git -C $(printf %q "$p") config core.hooksPath /tmp/h" \
  -- --options '{"writableGit":true}' -- claude
[ "$rc" = 3 ] || fail "a changed core.hooksPath gave exit $rc: $(cat err)"
grep -qF "$p/.git/config" err || fail "the changed config not named: $(cat err)"
git -C "$p" config --unset core.hooksPath
# A commondir file sends git to another folder's hooks and config.
launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=echo ../evil >$(printf %q "$p/.git/commondir")" \
  -- --options '{"writableGit":true}' -- claude
[ "$rc" = 3 ] || fail "a new .git/commondir gave exit $rc: $(cat err)"
grep -qF "$p/.git/commondir" err || fail "the new commondir not named: $(cat err)"
rm -f "$p/.git/commondir"
# A worktree: its .git file's gitdir: line rewritten in place (same
# inode), and its git dir's commondir changed.
dir=$root/w
wtfile=$root/w/.git
launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=echo 'gitdir: /tmp/evil' >$(printf %q "$wtfile")" \
  -- --options '{"writableGit":true}' -- claude
[ "$rc" = 3 ] || fail "a rewritten worktree .git file gave exit $rc: $(cat err)"
grep -qF "changed: $wtfile" err || fail "the rewritten .git file not named: $(cat err)"
echo 'gitdir: ../main/.git/worktrees/w' >"$wtfile"
launch STUB_IMAGE=1 STUB_VOLUME=1 -- --options '{"writableGit":true}' -- claude
[ "$rc" = 0 ] || fail "worktree, nothing changed: exit $rc: $(cat err)"
grep -q 'changed during the session' err && fail "worktree warned with nothing changed: $(cat err)"
launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=echo ../../evil >$(printf %q "$wt/commondir")" \
  -- --options '{"writableGit":true}' -- claude
[ "$rc" = 3 ] || fail "a changed worktree commondir gave exit $rc: $(cat err)"
grep -qF "$wt/commondir" err || fail "the worktree commondir not named: $(cat err)"
echo ../.. >"$wt/commondir"
dir=$p
# Deeper config and hooks: a submodule's, a linked worktree's.
for f in "$p/.git/modules/m/hooks/post-checkout" "$p/.git/modules/m/config" \
  "$p/.git/worktrees/x/config.worktree"; do
  launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=mkdir -p $(printf %q "${f%/*}") && echo evil >$(printf %q "$f")" \
    -- --options '{"writableGit":true}' -- claude
  [ "$rc" = 3 ] || fail "a new $f gave exit $rc: $(cat err)"
  grep -qF "changed: $f" err || fail "$f not named: $(cat err)"
done
rm -r "$p/.git/modules" "$p/.git/worktrees"
# The paths are the agent's to name: printed inert.
f=$p/.git/hooks/$'y\e[2Jz'
launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=echo evil >$(printf %q "$f")" -- --options '{"writableGit":true}' -- claude
[ "$rc" = 3 ] || fail "a hook with an escape in its name gave exit $rc: $(cat -v err)"
grep -q $'\e' err && fail "an escape printed: $(cat -v err)"
grep -qF "changed: $p/.git/hooks/y?[2Jz" err || fail "the hook with an escape not named: $(cat -v err)"
rm "$f"

# --- A .git planted anywhere in the project is named at exit -----------

# Git on the Mac runs the hooks and core.fsmonitor of any repository it
# lands in, so every .git and bare repository in the project is checked,
# on every launch, writableGit or not.
warned() { grep -q 'changed during the session' err; }
git -c init.defaultBranch=main init -q "$p/vendor/lib"
echo 'echo hi' >"$p/vendor/lib/.git/hooks/pre-commit"
mkdir -p "$p/wt2" "$p/gd"
echo 'gitdir: ../gd' >"$p/wt2/.git"
echo '[core]' >"$p/gd/config"
launch STUB_IMAGE=1 STUB_VOLUME=1 -- -- claude
[ "$rc" = 0 ] || fail "nested repos, nothing changed: exit $rc: $(cat err)"
warned && fail "warned with nothing changed: $(cat err)"
# A new .git with an fsmonitor, in a sub-folder.
f=$p/sub2/.git/config
launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=mkdir -p $(printf %q "${f%/*}") && printf '[core]\\n\\tfsmonitor = evil\\n' >$(printf %q "$f")" \
  -- -- claude
[ "$rc" = 3 ] || fail "a new sub2/.git/config gave exit $rc: $(cat err)"
grep -qF "changed: $f" err || fail "the new sub2/.git/config not named: $(cat err)"
warned || fail "no warning for a planted .git: $(cat err)"
rm -r "$p/sub2"
# A hook changed in an existing nested repository; the agent's own
# failure is kept.
f=$p/vendor/lib/.git/hooks/pre-commit
launch STUB_IMAGE=1 STUB_VOLUME=1 STUB_RUN_RC=5 "STUB_RUN_HOOK=echo evil >>$(printf %q "$f")" -- -- claude
[ "$rc" = 5 ] || fail "a changed nested hook after exit 5 gave exit $rc: $(cat err)"
grep -qF "changed: $f" err || fail "the changed nested hook not named: $(cat err)"
echo 'echo hi' >"$f"
# A bare repository.
launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=git init -q --bare $(printf %q "$p/bare")" -- -- claude
[ "$rc" = 3 ] || fail "a new bare repository gave exit $rc: $(cat err)"
grep -qF "changed: $p/bare/config" err || fail "the bare repository not named: $(cat err)"
rm -r "$p/bare"
# The git dir a .git file points at, inside the project.
launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=echo evil >>$(printf %q "$p/gd/config")" -- -- claude
[ "$rc" = 3 ] || fail "a changed gitdir config gave exit $rc: $(cat err)"
grep -qF "changed: $p/gd/config" err || fail "the gitdir's config not named: $(cat err)"
echo '[core]' >"$p/gd/config"
# A file name that would drive the terminal is printed inert.
esc=$p/sub3/.git/hooks/$'x\e]0;pwned\ay'
launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=mkdir -p $(printf %q "${esc%/*}") && echo evil >$(printf %q "$esc")" -- -- claude
[ "$rc" = 3 ] || fail "a hook with escapes in its name gave exit $rc: $(cat err)"
grep -q $'[\e\a]' err && fail "control characters printed: $(cat -v err)"
grep -qF "changed: $p/sub3/.git/hooks/x?]0;pwned?y" err || fail "the hook with escapes not named: $(cat -v err)"
rm -r "$p/sub3"
# Names in any case: on the Mac's case-insensitive disk git finds .GIT,
# HEAD as head, CONFIG and HOOKS. Made literally, so the case also holds
# on a case-sensitive disk.
planted() { # <path named at exit> <hook>
  launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=$2" -- -- claude
  [ "$rc" = 3 ] || fail "$1: exit $rc: $(cat err)"
  grep -qF "changed: $1" err || fail "$1 not named: $(cat err)"
}
fsm="printf '[core]\\n\\tfsmonitor = evil\\n'"
f=$p/sub4/.GIT/config
planted "$f" "mkdir -p $(printf %q "${f%/*}") && $fsm >$(printf %q "$f")"
rm -r "$p/sub4"
f=$p/vendor/lib/.git/modules/m/CONFIG
planted "$f" "mkdir -p $(printf %q "${f%/*}") && $fsm >$(printf %q "$f")"
f=$p/vendor/lib/.git/modules/n/HOOKS/post-checkout
planted "$f" "mkdir -p $(printf %q "${f%/*}") && echo evil >$(printf %q "$f")"
# A folder named objects is pruned only as the git dir's own.
f=$p/vendor/lib/.git/modules/objects/config
planted "$f" "mkdir -p $(printf %q "${f%/*}") && $fsm >$(printf %q "$f")"
rm -r "$p/vendor/lib/.git/modules"
# A bare repository whose HEAD is a symlink.
d=$p/sym
planted "$d/config" "mkdir -p $(printf %q "$d/objects") $(printf %q "$d/refs/heads") &&
  ln -s refs/heads/main $(printf %q "$d/HEAD") && $fsm >$(printf %q "$d/config")"
rm -r "$d"
# A git dir with only HEAD and a commondir: the folder commondir names
# holds the config, and has no HEAD of its own.
planted "$p/b/config" "mkdir -p $(printf %q "$p/wtd") $(printf %q "$p/b/objects") $(printf %q "$p/b/refs") &&
  echo 'ref: refs/heads/main' >$(printf %q "$p/wtd/HEAD") && echo ../b >$(printf %q "$p/wtd/commondir") &&
  $fsm >$(printf %q "$p/b/config")"
rm -r "$p/wtd" "$p/b"
# A folder the scan cannot read hides nothing: it counts as a change.
f=$p/hid/.git/config
launch STUB_IMAGE=1 STUB_VOLUME=1 \
  "STUB_RUN_HOOK=mkdir -p $(printf %q "${f%/*}") && echo evil >$(printf %q "$f") && chmod 000 $(printf %q "$p/hid")" \
  -- -- claude
[ "$rc" = 3 ] || fail "a planted .git in an unreadable folder gave exit $rc: $(cat err)"
grep -qF "changed: $p/<unreadable>" err || fail "the unreadable folder not reported: $(cat err)"
chmod 755 "$p/hid" && rm -r "$p/hid"
# A .git in a project that had none.
mkdir -p "$root/nogit"
dir=$root/nogit
launch STUB_IMAGE=1 STUB_VOLUME=1 "STUB_RUN_HOOK=git init -q $(printf %q "$root/nogit")" -- -- claude
[ "$rc" = 3 ] || fail "a new top-level .git gave exit $rc: $(cat err)"
grep -qF "changed: $root/nogit/.git/config" err || fail "the new top-level .git not named: $(cat err)"
[ ! -e "$root/nogit/.git" ] || rm -r "$root/nogit/.git"
launch STUB_IMAGE=1 STUB_VOLUME=1 -- -- claude
[ "$rc" = 0 ] || fail "a project with no .git, nothing changed: exit $rc: $(cat err)"
[ ! -e "$root/nogit/.git" ] || fail "the launch left a .git in a project that had none"
dir=$p

# --- Hooks and config a repository's config points into the project ---

# core.hooksPath (husky's .husky, lefthook) and include.path /
# includeIf.*.path can name files in the writable project: the Mac runs
# those hooks and reads that config at the next git command. Checked on
# every launch, mode included.
mkdir -p "$p/.husky" "$p/hooks-v"
echo 'npx lint-staged' >"$p/.husky/pre-commit"
echo 'echo checkout' >"$p/.husky/post-checkout"
chmod 644 "$p/.husky/post-checkout"
git -C "$p" config core.hooksPath .husky
git -C "$p" config include.path ../shared.gitconfig
printf '[include]\n\tpath = deep.gitconfig\n' >"$p/shared.gitconfig"
echo '[user]' >"$p/deep.gitconfig"
git -C "$p" config 'includeIf.gitdir:**.path' ../cond.gitconfig
echo '[user]' >"$p/cond.gitconfig"
git -C "$p/vendor/lib" config core.hooksPath ../../hooks-v
echo 'echo hi' >"$p/hooks-v/pre-commit"
launch STUB_IMAGE=1 STUB_VOLUME=1 -- -- claude
[ "$rc" = 0 ] || fail "hooksPath and includes, nothing changed: exit $rc: $(cat err)"
warned && fail "hooksPath and includes: warned with nothing changed: $(cat err)"
f=$p/.husky/pre-commit
planted "$f" "echo evil >>$(printf %q "$f")"
echo 'npx lint-staged' >"$f"
f=$p/.husky/post-checkout
planted "$f" "chmod +x $(printf %q "$f")"
chmod 644 "$f"
for f in "$p/shared.gitconfig" "$p/deep.gitconfig" "$p/cond.gitconfig"; do
  cp "$f" "$f.keep"
  planted "$f" "$fsm >>$(printf %q "$f")"
  mv "$f.keep" "$f"
done
f=$p/hooks-v/pre-commit
planted "$f" "echo evil >>$(printf %q "$f")"
echo 'echo hi' >"$f"
f=$p/.husky/pre-push
planted "$f" "echo evil >$(printf %q "$f")"
rm "$f"
# husky v9: core.hooksPath is .husky/_, whose stubs source .husky/_/h,
# which runs the user's hook one folder up.
mkdir -p "$p/.husky/_"
printf '#!/usr/bin/env sh\nsh -e "$(dirname "$(dirname "$0")")/$(basename "$0")"\n' >"$p/.husky/_/h"
printf '#!/usr/bin/env sh\n. "$(dirname "$0")/h"\n' >"$p/.husky/_/pre-commit"
git -C "$p" config core.hooksPath .husky/_
f=$p/.husky/pre-commit
planted "$f" "echo evil >>$(printf %q "$f")"
echo 'npx lint-staged' >"$f"
f=$p/.husky/pre-push
planted "$f" "echo evil >$(printf %q "$f")"
rm "$f"
# A submodule's config under the top-level .git, its hooks in its work
# tree; and a linked worktree's config.worktree.
mkdir -p "$p/.git/modules/sub5" "$p/sub5/.husky/_" "$p/.git/worktrees/w3" "$p/wt3/hk"
printf '[core]\n\thooksPath = .husky/_\n' >"$p/.git/modules/sub5/config"
echo 'gitdir: ../.git/modules/sub5' >"$p/sub5/.git"
cp "$p/.husky/_/h" "$p/sub5/.husky/_/h"
echo 'echo sub' >"$p/sub5/.husky/pre-commit"
echo "$p/wt3/.git" >"$p/.git/worktrees/w3/gitdir"
printf '[core]\n\thooksPath = hk\n' >"$p/.git/worktrees/w3/config.worktree"
echo 'gitdir: ../.git/worktrees/w3' >"$p/wt3/.git"
echo 'echo wt' >"$p/wt3/hk/pre-commit"
launch STUB_IMAGE=1 STUB_VOLUME=1 -- -- claude
[ "$rc" = 0 ] || fail "submodule and worktree hooks, nothing changed: exit $rc: $(cat err)"
f=$p/sub5/.husky/pre-commit
planted "$f" "echo evil >>$(printf %q "$f")"
echo 'echo sub' >"$f"
f=$p/wt3/hk/pre-commit
planted "$f" "echo evil >>$(printf %q "$f")"
echo 'echo wt' >"$f"
rm -r "$p/.git/modules" "$p/.git/worktrees" "$p/sub5" "$p/wt3"
# An include given from ~, which here holds the project's folder too.
echo '[user]' >"$p/x.gitconfig"
git -C "$p" config --add include.path "~/../${p##*/}/x.gitconfig"
f=$p/x.gitconfig
planted "$f" "$fsm >>$(printf %q "$f")"
git -C "$p" config --unset-all include.path
rm "$f"
git -C "$p" config include.path ../shared.gitconfig
git -C "$p" config --unset core.hooksPath
git -C "$p" config --unset include.path
git -C "$p" config --unset 'includeIf.gitdir:**.path'
git -C "$p/vendor/lib" config --unset core.hooksPath
rm -r "$p/.husky" "$p/hooks-v" "$p/shared.gitconfig" "$p/deep.gitconfig" "$p/cond.gitconfig"

# --- The FloxHub hint --------------------------------------------------

hint='forwardFloxhubToken'
launch STUB_IMAGE=1 STUB_VOLUME=1 STUB_RUN_RC=1 STUB_PROXY_DENY_FLOX=1 -- -- claude
[ "$rc" = 1 ] || fail "exit $rc"
grep -q "$hint" err || fail "no hint after a deny of api.flox.dev: $(cat err)"
# What flox 1.x prints for a private package without the token.
auth_err="You may not be authenticated or package may have been deleted."
launch STUB_IMAGE=1 STUB_VOLUME=1 STUB_RUN_RC=1 "STUB_RUN_ERR=$auth_err" -- -- claude
grep -q "$hint" err || fail "no hint after a FloxHub auth error: $(cat err)"
launch STUB_IMAGE=1 STUB_VOLUME=1 STUB_RUN_RC=1 "STUB_RUN_ERR=$auth_err" \
  -- --options '{"forwardFloxhubToken":true}' -- claude
grep -q "set $hint" err && fail "hint with the token already forwarded: $(cat err)"
launch STUB_IMAGE=1 STUB_VOLUME=1 STUB_RUN_RC=1 -- -- claude
grep -q "$hint" err && fail "hint for an unrelated failure: $(cat err)"
# flox suggests signing in on many failures that have nothing to do
# with FloxHub.
launch STUB_IMAGE=1 STUB_VOLUME=1 STUB_RUN_RC=1 "STUB_RUN_ERR=Run 'flox auth login' and try again." -- -- claude
grep -q "$hint" err && fail "hint for flox's generic sign-in line: $(cat err)"

echo "agent-sandbox-apple contract: OK"
