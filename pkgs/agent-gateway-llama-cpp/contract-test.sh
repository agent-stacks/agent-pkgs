# The agent-gateway contract (agent-stacks spec proposal 0002, section
# 7), run in the package's own build against the llama-server it pins:
# describe, check on every kind of model directory, serve with a real
# (tiny) GGUF, every protocol it names, status, and stopping cleanly.
#
#   bash contract-test.sh <path to agent-gateway-llama-cpp> <a small GGUF>
#
# Needs jq, curl, python3 and coreutils on PATH, and a loopback interface.
set -euo pipefail
gw=$1
gguf=$2
cd "$(mktemp -d)"
root=$PWD
export HOME=$root/home TMPDIR=$root/tmp
# Nothing borrowed: the HF cache is empty, so only carried models show.
export HF_HOME=$root/hf HF_HUB_CACHE=$root/hf/hub LLAMA_CACHE=$root/hf/llama
mkdir -p "$HOME" "$TMPDIR" "$HF_HUB_CACHE" "$LLAMA_CACHE"
unset AGENT_STACKS_MODELS_DIR FLOX_ENV || true

fail() {
  echo "contract: $*" >&2
  exit 1
}

# --- describe --------------------------------------------------------
"$gw" describe >d.json
jq -e '.formats == ["gguf"]' d.json >/dev/null || fail "formats"
jq -e '.defaultPort == 9931' d.json >/dev/null || fail "defaultPort"
jq -e '.protocols | sort == ["anthropic-messages", "open-responses", "openai-chat-completions"]' d.json >/dev/null ||
  fail "protocols"
jq -e '.platforms | index("aarch64-darwin") and index("x86_64-linux") and index("aarch64-linux")' d.json >/dev/null ||
  fail "platforms"
jq -e '.version | type == "string" and length > 0' d.json >/dev/null || fail "version"

# --- a models dir with one of each kind -------------------------------
m=$root/env/share/agent-models
size=$(stat -L -c %s "$gguf" 2>/dev/null || stat -L -f %z "$gguf")
mk() { # <dir> <json>
  mkdir -p "$m/$1"
  printf '%s\n' "$2" >"$m/$1/model.json"
}
weights='[{"path":"stories.gguf","role":"weights","size":'"$size"'}]'
mk tiny '{"schemaVersion":1,"id":"tiny","layout":"plain","format":"gguf","entry":"files/stories.gguf","config":{"contextLength":128},"files":'"$weights"'}'
mkdir -p "$m/tiny/files" && ln -s "$gguf" "$m/tiny/files/stories.gguf"
# The HF cache layout, as a carried model: snapshot file -> blob.
mk tiny-hf '{"schemaVersion":1,"id":"tiny-hf","layout":"hf-cache","format":"gguf","entry":"files/models--o--r/snapshots/abc/stories.gguf","files":'"$weights"'}'
mkdir -p "$m/tiny-hf/files/models--o--r/"{blobs,refs,snapshots/abc}
ln -s "$gguf" "$m/tiny-hf/files/models--o--r/blobs/deadbeef"
ln -s ../../blobs/deadbeef "$m/tiny-hf/files/models--o--r/snapshots/abc/stories.gguf"
echo abc >"$m/tiny-hf/files/models--o--r/refs/main"
mk mlx '{"schemaVersion":1,"id":"mlx","layout":"plain","format":"mlx","entry":"files/"}'
mk remote '{"schemaVersion":1,"id":"remote","endpoint":{"url":"https://models.example.com/v1","model":"x","protocols":["anthropic-messages"]}}'
mkdir -p "$m/legacy-remote" && echo '{"url":"https://models.example.com/v1","model":"x","protocols":[]}' >"$m/legacy-remote/endpoint.json"
mk gone '{"schemaVersion":1,"id":"gone","layout":"plain","format":"gguf","entry":"files/x.gguf"}'
mkdir -p "$m/gone/files" && ln -s "$root/nowhere.gguf" "$m/gone/files/x.gguf"
mk short '{"schemaVersion":1,"id":"short","layout":"plain","format":"gguf","entry":"files/stories.gguf","files":[{"path":"stories.gguf","role":"weights","size":1}]}'
mkdir -p "$m/short/files" && ln -s "$gguf" "$m/short/files/stories.gguf"
mk odd '{"schemaVersion":1,"id":"odd","layout":"tarball","format":"gguf","entry":"files/stories.gguf"}'
mk bad-id '{"schemaVersion":1,"id":"a/b","layout":"plain","format":"gguf","entry":"files/stories.gguf"}'
mkdir -p "$m/broken" && echo '{nope' >"$m/broken/model.json"

# --- check -----------------------------------------------------------
line() { # <model> -> the one line check prints for it
  grep "^$1 " check.out || fail "check printed nothing for $1: $(cat check.out)"
}
"$gw" check "$m"/* >check.out 2>check.err
[ "$(wc -l <check.out)" -eq "$(ls "$m" | wc -l)" ] || fail "check: one line per model: $(cat check.out)"
[ "$(line tiny)" = "tiny ok" ] || fail "tiny: $(line tiny)"
[ "$(line tiny-hf)" = "tiny-hf ok" ] || fail "tiny-hf: $(line tiny-hf)"
line mlx | grep -q '^mlx skip format ' || fail "mlx: $(line mlx)"
line remote | grep -q '^remote skip endpoint ' || fail "remote: $(line remote)"
line legacy-remote | grep -q '^legacy-remote skip endpoint ' || fail "legacy-remote: $(line legacy-remote)"
line gone | grep -q '^gone skip weights ' || fail "gone: $(line gone)"
line short | grep -q '^short skip weights ' || fail "short: $(line short)"
line odd | grep -q '^odd skip weights ' || fail "odd: $(line odd)"
line bad-id | grep -q '^bad-id skip other ' || fail "bad-id: $(line bad-id)"
line broken | grep -q '^broken skip other ' || fail "broken: $(line broken)"
# A model.json path is the same as its directory.
[ "$("$gw" check "$m/tiny/model.json")" = "tiny ok" ] || fail "check by model.json"
# Too big for this host, and a host it does not run on.
AGENT_GATEWAY_MEMORY_BYTES=1000 "$gw" check "$m/tiny" | grep -q '^tiny skip memory ' || fail "memory"
AGENT_GATEWAY_PLATFORM=riscv64-linux "$gw" check "$m/tiny" | grep -q '^tiny skip platform ' || fail "platform"
if "$gw" check 2>/dev/null; then fail "check with no model accepted"; fi

# --- serve -----------------------------------------------------------
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
url=http://127.0.0.1:$port
# The models dir from the environment; CPU only, which also shows the
# server arguments are passed through.
AGENT_STACKS_MODELS_DIR=$m "$gw" serve --listen "127.0.0.1:$port" -- --device none -c 512 >serve.out 2>serve.err &
pid=$!
stop() { kill "$pid" 2>/dev/null || true; }
trap stop EXIT
for _ in $(seq 600); do
  [ -s serve.out ] && break
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
[ "$(cat serve.out)" = ready ] || fail "serve did not print ready: $(cat serve.out) $(tail -20 serve.err)"
grep -q 'skip format' serve.err || fail "serve did not warn about the skipped mlx model"

curl -fsS "$url/v1/models" >models.json
jq -e '.object == "list"' models.json >/dev/null || fail "/v1/models is not a list"
[ "$(jq -c '[.data[].id] | sort' models.json)" = '["tiny","tiny-hf"]' ] || fail "served $(jq -c '[.data[].id]' models.json)"

# Every protocol describe names, at its path, loading the model on the
# first request.
curl -fsS "$url/v1/chat/completions" -H 'content-type: application/json' \
  -d '{"model":"tiny","messages":[{"role":"user","content":"Once upon a time"}],"max_tokens":8}' >chat.json ||
  fail "chat: $(tail -20 serve.err)"
jq -e '.choices[0].message | has("content")' chat.json >/dev/null || fail "chat: $(cat chat.json)"
curl -fsS "$url/v1/messages" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"tiny","max_tokens":8,"messages":[{"role":"user","content":"Once upon a time"}]}' >msg.json ||
  fail "messages: $(tail -20 serve.err)"
jq -e '.type == "message" and (.content | type == "array")' msg.json >/dev/null || fail "messages: $(cat msg.json)"
curl -fsS "$url/v1/responses" -H 'content-type: application/json' \
  -d '{"model":"tiny","input":"Once upon a time","max_output_tokens":8}' >resp.json ||
  fail "responses: $(tail -20 serve.err)"
jq -e '.object == "response"' resp.json >/dev/null || fail "responses: $(cat resp.json)"

# --- status ----------------------------------------------------------
"$gw" status --url "$url/v1" >status.json
jq -e '.models | length == 2' status.json >/dev/null || fail "status: $(cat status.json)"
jq -e '.models[] | select(.id == "tiny") | .loaded == true and .contextLength == 512' status.json >/dev/null ||
  fail "status of the loaded model: $(cat status.json)"
jq -e '.models[] | select(.id == "tiny-hf") | .loaded == false' status.json >/dev/null ||
  fail "status of the unloaded model: $(cat status.json)"
jq -e '[.models[] | keys] | all(. == ["contextLength", "id", "loaded"])' status.json >/dev/null ||
  fail "status shape: $(cat status.json)"
# Without /v1 too.
"$gw" status --url "$url" | jq -e '.models | length == 2' >/dev/null || fail "status without /v1"

# --- a taken address -------------------------------------------------
if "$gw" serve --listen "127.0.0.1:$port" "$m" >taken.out 2>/dev/null; then fail "served on a taken port"; fi
grep -q '^error address ' taken.out || fail "taken port: $(cat taken.out)"
[ "$(wc -l <taken.out)" -eq 1 ] || fail "taken port: more than one line"

# --- SIGTERM stops everything ----------------------------------------
kill -TERM "$pid"
for _ in $(seq 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then fail "serve still running after SIGTERM"; fi
trap - EXIT
[ "$(cat serve.out)" = ready ] || fail "stdout holds more than ready: $(cat serve.out)"
if curl -fsS "$url/health" >/dev/null 2>&1; then fail "llama-server still answering after SIGTERM"; fi
# The state it wrote (links, preset) is gone.
if grep -rl "$m" "$TMPDIR" 2>/dev/null | grep -q .; then fail "state left in $TMPDIR"; fi
echo "agent-gateway-llama-cpp: contract OK"
