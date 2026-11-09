# The agent-sandbox-nono contract, run in the package's own build: the
# profile it writes (validated by the nono it runs), the temp folder,
# --options, and refusing to start at / or ~.
#
#   bash contract-test.sh <path to agent-sandbox-nono>
#
# Needs jq, nono and GNU coreutils on PATH.
set -euo pipefail
sandbox=$1
cd "$(mktemp -d)"
export HOME=$PWD/home TMPDIR=$PWD/tmp AGENT_SANDBOX_NONO_DRY_RUN=1
# Its own, or a macOS build would make /tmp/claude-<uid> for the build user.
export CLAUDE_CODE_TMPDIR=$PWD/agent-tmp
t=$CLAUDE_CODE_TMPDIR/claude-$(id -u)
mkdir -p "$t"
touch -d '2 days ago' "$t/agent-sandbox-nono.old"
mkdir -p $HOME $TMPDIR proj plugins/remote plugins/local
cd proj
printf '{"mcpServers":{"seo":{"type":"http","url":"https://app.openseo.so/mcp"}}}' > ../plugins/remote/.mcp.json
printf '{"mcpServers":{"cli":{"type":"stdio","command":"x"}}}' > ../plugins/local/.mcp.json
export CLAUDE_CODE_PLUGIN_DIRS=$PWD/../plugins/remote:$PWD/../plugins/local:$PWD/../plugins/missing
"$sandbox" -- claude --version > p.json 2>cmd
nono profile validate p.json
jq -e '.extends == "default" and .workdir.access == "readwrite"' p.json
jq -e '.filesystem.read | index("/nix/store")' p.json
jq -e '.filesystem.allow | index("$HOME/.claude")' p.json
jq -e '.filesystem.allow_file | index("$HOME/.claude.json")' p.json
# Network stays open until options name hosts.
jq -e '.network.allow_domain == null and .network.block == false' p.json
grep -q -- 'run -s --no-diagnostics --allow-cwd --profile .* -- claude --version' cmd
# Claude's temp folder exists before the sandbox goes up (Landlock
# drops a grant for a missing path) and is the one granted.
# Claude adds claude-<uid> to CLAUDE_CODE_TMPDIR; that folder, not its parent.
[ -d "$t" ] || { echo "temp folder not created"; exit 1; }
jq -e --arg t "$t" '.filesystem.allow | index($t) and (index($t | sub("/[^/]*$"; "")) | not)' p.json
[ "$(stat -c %a "$t")" = 700 ] || { echo "temp folder open to others"; exit 1; }
# Profiles from earlier days are cleared.
[ ! -e "$t/agent-sandbox-nono.old" ] || { echo "old profile kept"; exit 1; }
# TMPDIR points at that folder on Linux; a set one is kept on macOS.
if [ "$(uname -s)" = Linux ]; then
  grep -q -- "TMPDIR=$t " cmd || { echo "TMPDIR not replaced on Linux"; cat cmd; exit 1; }
elif grep -q 'TMPDIR=' cmd; then echo "replaced a set TMPDIR"; exit 1; fi
(unset TMPDIR; "$sandbox" -- true >/dev/null 2>cmd2)
grep -q -- "TMPDIR=$t " cmd2 || { echo "TMPDIR not set when unset"; cat cmd2; exit 1; }
# A temp folder that is a link (or not ours) is refused.
mkdir -p ../other ../planted && ln -s "$PWD/../other" "../planted/claude-$(id -u)"
if CLAUDE_CODE_TMPDIR=$PWD/../planted "$sandbox" -- true >/dev/null 2>err; then echo "used a planted temp folder"; exit 1; fi
grep -q 'not a folder of yours' err || { echo "no reason for planted folder"; cat err; exit 1; }
"$sandbox" --options '{"allowedDomains":["example.com"],"allowWrite":["/data"],"denyRead":["~/.aws"]}' -- true > o.json 2>/dev/null
nono profile validate o.json
jq -e '.network.allow_domain | index("example.com") and index("api.anthropic.com") and index("platform.claude.com") and index("app.openseo.so")' o.json
jq -e '.network.allow_domain | length == 4' o.json
jq -e '(.filesystem.allow | index("/data")) and (.filesystem.deny | index("~/.aws"))' o.json
for bad in '[1]' '{"allowedDomains":"x"}' '{"allowedDomains":[1]}' '{"other":[]}' '{nope'; do
  if "$sandbox" --options "$bad" -- true >/dev/null 2>err; then echo "accepted $bad"; exit 1; fi
  [ -s err ] || { echo "no reason for $bad"; exit 1; }
done
if "$sandbox" echo no-separator 2>/dev/null; then exit 1; fi
# The project folder is writable, so / or ~ would open everything.
for top in / "$HOME"; do
  if (cd "$top" && "$sandbox" -- true) >/dev/null 2>err; then echo "started from $top"; exit 1; fi
  grep -q 'project folder' err || { echo "no reason for $top"; cat err; exit 1; }
done
