# The agent-gateway contract (agent-stacks spec proposal 0002, section
# 7), run in the package's own build against the oMLX it pins:
# describe, check on every kind of model directory, serve with a real
# (tiny) MLX-loadable model, every protocol it names, status, reload,
# and stopping cleanly.
#
#   bash contract-test.sh <path to agent-gateway-omlx> <a tiny model dir>
#
# The model dir holds a Hugging Face snapshot mlx-lm loads: config.json,
# *.safetensors, the tokenizer and a chat template. Needs jq, curl,
# python3 and coreutils on PATH, a loopback interface, and Metal.
set -euo pipefail
gw=$1
tiny=$2
cd "$(mktemp -d)"
root=$PWD
export HOME=$root/home TMPDIR=$root/tmp
# Nothing borrowed: the HF cache is empty, so only carried models show.
export HF_HOME=$root/hf
mkdir -p "$HOME" "$TMPDIR" "$HF_HOME/hub"
unset AGENT_STACKS_MODELS_DIR FLOX_ENV HF_HUB_CACHE OMLX_BASE_PATH OMLX_API_KEY || true

fail() {
  echo "contract: $*" >&2
  exit 1
}

# --- describe --------------------------------------------------------
"$gw" describe >d.json
jq -e '.formats == ["mlx"]' d.json >/dev/null || fail "formats"
jq -e '.defaultPort == 8000' d.json >/dev/null || fail "defaultPort"
jq -e '.protocols | sort == ["anthropic-messages", "open-responses", "openai-chat-completions"]' d.json >/dev/null ||
  fail "protocols"
jq -e '.platforms == ["aarch64-darwin"]' d.json >/dev/null || fail "platforms"
jq -e '.minimumMacOS == "15.0"' d.json >/dev/null || fail "minimumMacOS"
jq -e '.version | type == "string" and length > 0' d.json >/dev/null || fail "version"

# --- a models dir with one of each kind -------------------------------
m=$root/env/share/agent-models
sz() { stat -L -c %s "$1" 2>/dev/null || stat -L -f %z "$1"; }
wsize=$(sz "$tiny/model.safetensors")
csize=$(sz "$tiny/config.json")
files='[{"path":"config.json","role":"config","size":'"$csize"'},{"path":"model.safetensors","role":"weights","size":'"$wsize"'}]'
mk() { # <dir> <json>
  mkdir -p "$m/$1"
  printf '%s\n' "$2" >"$m/$1/model.json"
}
snapshot() { # <dir>: links to every file of the tiny model
  mkdir -p "$1"
  for f in "$tiny"/*; do ln -s "$f" "$1/$(basename "$f")"; done
}
mk tiny '{"schemaVersion":1,"id":"tiny","layout":"plain","format":"mlx","entry":"files/","files":'"$files"'}'
snapshot "$m/tiny/files"
# The HF cache layout, as a carried model: snapshot files -> blobs.
mk tiny-hf '{"schemaVersion":1,"id":"tiny-hf","layout":"hf-cache","format":"mlx","entry":"files/models--o--r/snapshots/abc/","files":'"$files"'}'
c=$m/tiny-hf/files/models--o--r
mkdir -p "$c/blobs" "$c/refs" "$c/snapshots/abc"
for f in "$tiny"/*; do
  ln -s "$f" "$c/blobs/$(basename "$f").blob"
  ln -s "../../blobs/$(basename "$f").blob" "$c/snapshots/abc/$(basename "$f")"
done
echo abc >"$c/refs/main"
mk gguf '{"schemaVersion":1,"id":"gguf","layout":"plain","format":"gguf","entry":"files/x.gguf"}'
mk remote '{"schemaVersion":1,"id":"remote","endpoint":{"url":"https://models.example.com/v1","model":"x","protocols":["anthropic-messages"]}}'
mkdir -p "$m/legacy-remote" && echo '{"url":"https://models.example.com/v1","model":"x","protocols":[]}' >"$m/legacy-remote/endpoint.json"
mk gone '{"schemaVersion":1,"id":"gone","layout":"plain","format":"mlx","entry":"files/"}'
ln -s "$root/nowhere" "$m/gone/files"
mk short '{"schemaVersion":1,"id":"short","layout":"plain","format":"mlx","entry":"files/","files":[{"path":"model.safetensors","role":"weights","size":1}]}'
snapshot "$m/short/files"
mk odd '{"schemaVersion":1,"id":"odd","layout":"tarball","format":"mlx","entry":"files/"}'
mk noconfig '{"schemaVersion":1,"id":"noconfig","layout":"plain","format":"mlx","entry":"files/"}'
mkdir -p "$m/noconfig/files" && ln -s "$tiny/model.safetensors" "$m/noconfig/files/"
mk noweights '{"schemaVersion":1,"id":"noweights","layout":"plain","format":"mlx","entry":"files/"}'
mkdir -p "$m/noweights/files" && ln -s "$tiny/config.json" "$m/noweights/files/"
mk quant '{"schemaVersion":1,"id":"quant","layout":"plain","format":"mlx","entry":"files/","config":{"quantization":{"bits":8,"groupSize":64}}}'
snapshot "$m/quant/files"
mk shard '{"schemaVersion":1,"id":"shard","layout":"plain","format":"mlx","entry":"files/"}'
mkdir -p "$m/shard/files" && ln -s "$tiny/config.json" "$m/shard/files/"
ln -s "$tiny/model.safetensors" "$m/shard/files/model-00001-of-00002.safetensors"
echo '{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}' \
  >"$m/shard/files/model.safetensors.index.json"
mk bad-id '{"schemaVersion":1,"id":"a/b","layout":"plain","format":"mlx","entry":"files/"}'
mkdir -p "$m/broken" && echo '{nope' >"$m/broken/model.json"

# --- check -----------------------------------------------------------
line() { # <model> -> the one line check prints for it
  grep "^$1 " check.out || fail "check printed nothing for $1: $(cat check.out)"
}
"$gw" check "$m"/* >check.out 2>check.err
[ "$(wc -l <check.out)" -eq "$(ls "$m" | wc -l)" ] || fail "check: one line per model: $(cat check.out)"
[ "$(line tiny)" = "tiny ok" ] || fail "tiny: $(line tiny)"
[ "$(line tiny-hf)" = "tiny-hf ok" ] || fail "tiny-hf: $(line tiny-hf)"
line gguf | grep -q '^gguf skip format ' || fail "gguf: $(line gguf)"
line remote | grep -q '^remote skip endpoint ' || fail "remote: $(line remote)"
line legacy-remote | grep -q '^legacy-remote skip endpoint ' || fail "legacy-remote: $(line legacy-remote)"
for w in gone short odd noconfig noweights quant shard; do
  line $w | grep -q "^$w skip weights " || fail "$w: $(line $w)"
done
line bad-id | grep -q '^bad-id skip other ' || fail "bad-id: $(line bad-id)"
line broken | grep -q '^broken skip other ' || fail "broken: $(line broken)"
# A model.json path is the same as its directory.
[ "$("$gw" check "$m/tiny/model.json")" = "tiny ok" ] || fail "check by model.json"
# Too big for this host, a host it does not run on, a macOS too old.
AGENT_GATEWAY_MEMORY_BYTES=1000 "$gw" check "$m/tiny" | grep -q '^tiny skip memory ' || fail "memory"
AGENT_GATEWAY_PLATFORM=x86_64-linux "$gw" check "$m/tiny" | grep -q '^tiny skip platform ' || fail "platform"
AGENT_GATEWAY_MACOS_VERSION=14.6 "$gw" check "$m/tiny" | grep -q '^tiny skip host ' || fail "host"
if "$gw" check 2>/dev/null; then fail "check with no model accepted"; fi

# --- serve -----------------------------------------------------------
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
url=http://127.0.0.1:$port
# The models dir from the environment; a server argument passed through.
AGENT_STACKS_MODELS_DIR=$m "$gw" serve --listen "127.0.0.1:$port" -- --no-cache >serve.out 2>serve.err &
pid=$!
stop() { kill "$pid" 2>/dev/null || true; }
trap stop EXIT
for _ in $(seq 1500); do
  [ -s serve.out ] && break
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
[ "$(cat serve.out)" = ready ] || fail "serve did not print ready: $(cat serve.out) $(tail -20 serve.err)"
grep -q 'gguf skip format' serve.err || fail "serve did not warn about the skipped gguf model"

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
jq -e '.models[] | select(.id == "tiny") | .loaded == true and .contextLength == 40960' status.json >/dev/null ||
  fail "status of the loaded model: $(cat status.json)"
jq -e '.models[] | select(.id == "tiny-hf") | .loaded == false' status.json >/dev/null ||
  fail "status of the unloaded model: $(cat status.json)"
jq -e '[.models[] | keys] | all(. == ["contextLength", "id", "loaded"])' status.json >/dev/null ||
  fail "status shape: $(cat status.json)"
# Without /v1 too.
"$gw" status --url "$url" | jq -e '.models | length == 2' >/dev/null || fail "status without /v1"

# --- SIGHUP re-reads the models dirs ---------------------------------
mk late '{"schemaVersion":1,"id":"late","layout":"plain","format":"mlx","entry":"files/"}'
snapshot "$m/late/files"
kill -HUP "$pid"
for _ in $(seq 100); do
  curl -fsS "$url/v1/models" | jq -e '[.data[].id] | index("late")' >/dev/null 2>&1 && break
  sleep 0.1
done
[ "$(curl -fsS "$url/v1/models" | jq -c '[.data[].id] | sort')" = '["late","tiny","tiny-hf"]' ] ||
  fail "after SIGHUP: $(curl -fsS "$url/v1/models") $(tail -5 serve.err)"

# --- a taken address -------------------------------------------------
if "$gw" serve --listen "127.0.0.1:$port" "$m" >taken.out 2>/dev/null; then fail "served on a taken port"; fi
grep -q '^error address ' taken.out || fail "taken port: $(cat taken.out)"
[ "$(wc -l <taken.out)" -eq 1 ] || fail "taken port: more than one line"

# --- SIGTERM stops everything ----------------------------------------
kill -TERM "$pid"
for _ in $(seq 200); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then fail "serve still running after SIGTERM"; fi
trap - EXIT
[ "$(cat serve.out)" = ready ] || fail "stdout holds more than ready: $(cat serve.out)"
if curl -fsS "$url/health" >/dev/null 2>&1; then fail "oMLX still answering after SIGTERM"; fi
# The state it wrote (links, settings, logs) is gone, and the home it
# ran under was never written.
if ls "$TMPDIR" | grep -q '^agent-gateway-omlx'; then fail "state left in $TMPDIR: $(ls "$TMPDIR")"; fi
[ -z "$(ls -A "$HOME")" ] || fail "wrote to HOME: $(ls -A "$HOME")"
echo "agent-gateway-omlx: contract OK"
