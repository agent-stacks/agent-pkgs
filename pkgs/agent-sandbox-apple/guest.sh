#!/usr/bin/env bash
# The VM's side of agent-sandbox-apple, run as root by `container run`:
#
#   guest.sh <agent> [args]
#
# It bridges 127.0.0.1:3128 to the Mac's proxy, activates the Flox
# environment as root (which may fill /nix), closes the proxy's start-up
# hosts, and runs the agent as uid 1000 with no capabilities.
set -euo pipefail

proxy=http://127.0.0.1:3128

# Inside the activated environment: close the start-up hosts, go back
# to the project, then drop.
if [ "${1:-}" = --activated ]; then
  project=$2 agent=$3
  shift 3
  # The hosts the MCP servers of the environment's plugins name: the
  # plugins the inner launch stages. Read here, as root and before the
  # agent runs, and handed to the proxy with the latch, which takes them
  # only on the first latch. Only plain host names pass the filter, so
  # nothing can break the request's header.
  hosts=""
  for f in "${FLOX_ENV:-/nonexistent}"/share/agent-plugins/*/mcp.json \
    "${FLOX_ENV:-/nonexistent}"/share/agent-plugins/*/.mcp.json; do
    [ -f "$f" ] || continue
    h=$(jq -r '(.mcpServers // {})[] | .url? // empty | strings
        | sub("^[a-zA-Z][a-zA-Z0-9+.-]*://"; "") | split("/")[0]
        | split("@")[-1] | split(":")[0] | select(test("^[A-Za-z0-9.-]+$"))' "$f") || {
      echo "agent-sandbox-apple: cannot read MCP servers in $f" >&2
      continue
    }
    hosts+=" ${h//$'\n'/ }"
  done
  # -t 10: wait up to 10 s for the reply after sending, not socat's
  # default half a second.
  reply=$(printf 'CONNECT agent-sandbox-apple.start-done:0 HTTP/1.1\r\nHost: agent-sandbox-apple.start-done:0\r\nX-Allow-Hosts: %s\r\n\r\n' "$hosts" |
    socat -t 10 - TCP:127.0.0.1:3128) || reply=""
  if [[ $reply != "HTTP/1.1 200"* ]]; then
    echo "agent-sandbox-apple: the proxy did not close its start-up hosts" >&2
    exit 1
  fi
  cd "$project"
  exec setpriv --reuid=1000 --regid=1000 --clear-groups \
    --inh-caps=-all --bounding-set=-all --no-new-privs \
    env HOME=/home/agent USER=agent LOGNAME=agent flox-agent --config-dir /tmp/agent-stacks \
    launch "$agent" -- "$@"
fi

[ $# -gt 0 ] || {
  echo "usage: guest.sh <agent> [args]" >&2
  exit 2
}

export PATH=/usr/local/bin:$PATH FLOX_DISABLE_METRICS=true

# The bridge to the proxy, the VM's only way out. Its errors (a reset
# for every refused connection) would land on the agent's terminal; the
# proxy's log on the Mac already names each refusal.
socat TCP-LISTEN:3128,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/run/agent-proxy.sock 2>/dev/null &
for _ in $(seq 50); do
  if (: </dev/tcp/127.0.0.1/3128) 2>/dev/null; then break; fi
  sleep 0.1
done
(: </dev/tcp/127.0.0.1/3128) 2>/dev/null || {
  echo "agent-sandbox-apple: the proxy bridge did not start" >&2
  exit 1
}
export HTTPS_PROXY=$proxy HTTP_PROXY=$proxy https_proxy=$proxy http_proxy=$proxy

# The rootfs is read-only and /home/agent a root-owned tmpfs: the agent
# gets its home, and activation a home of its own on /tmp.
chown 1000:1000 /home/agent
mkdir -p /tmp/root-home /tmp/env/.flox/env
# Flox writes logs under .flox, so it cannot be the read-only mount. The
# copies are readable by the agent, for `flox list` and the like.
cp /host-env/manifest.toml /host-env/manifest.lock /tmp/env/.flox/env/
chmod 0644 /tmp/env/.flox/env/manifest.toml /tmp/env/.flox/env/manifest.lock
echo '{"name":"agent-sandbox-apple","version":1}' >/tmp/env/.flox/env.json

# The project, where `container run -w` starts this. Activation runs the
# environment's hooks as root, with the start-up hosts open, so it runs
# in /tmp/env: in the project, which the agent can write, a hook's
# relative path would run what the last session left there.
project=$PWD
cd /tmp/env
HOME=/tmp/root-home exec flox activate -d /tmp/env -- "$0" --activated "$project" "$@"
