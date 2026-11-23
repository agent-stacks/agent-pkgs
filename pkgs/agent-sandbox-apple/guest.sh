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

# Inside the activated environment: close the start-up hosts, then drop.
if [ "${1:-}" = --activated ]; then
  shift
  agent=$1
  shift
  reply=$(printf 'CONNECT agent-sandbox-apple.start-done:0 HTTP/1.1\r\nHost: agent-sandbox-apple.start-done:0\r\n\r\n' |
    socat - TCP:127.0.0.1:3128) || reply=""
  if [[ $reply != "HTTP/1.1 200"* ]]; then
    echo "agent-sandbox-apple: the proxy did not close its start-up hosts" >&2
    exit 1
  fi
  exec setpriv --reuid=1000 --regid=1000 --clear-groups \
    --inh-caps=-all --bounding-set=-all --no-new-privs \
    env HOME=/home/agent flox-agent --config-dir /tmp/agent-stacks \
    launch "$agent" -- "$@"
fi

[ $# -gt 0 ] || {
  echo "usage: guest.sh <agent> [args]" >&2
  exit 2
}

export PATH=/usr/local/bin:$PATH FLOX_DISABLE_METRICS=true

# The bridge to the proxy, the VM's only way out.
socat TCP-LISTEN:3128,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/run/agent-proxy.sock &
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
# Flox writes logs under .flox, so it cannot be the read-only mount.
cp /host-env/manifest.toml /host-env/manifest.lock /tmp/env/.flox/env/
echo '{"name":"agent-sandbox-apple","version":1}' >/tmp/env/.flox/env.json

HOME=/tmp/root-home exec flox activate -d /tmp/env -- "$0" --activated "$@"
