#!/usr/bin/env bash
# Runs audit-dashboard.py against a small pkgs tree and reads back the
# data it embedded. Usage:
#   audit-dashboard.test.sh <path to audit-dashboard.py> <path to the template>
set -uo pipefail

generator=$1
template=$2
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

pkgs="$root/pkgs"
mkdir -p "$pkgs/agent-plugin-demo" "$pkgs/agent-plugin-blocked" \
  "$pkgs/agent-plugin-new" "$pkgs/agent-plugin-gone" "$pkgs/agent-stacks"
for p in demo blocked new; do echo '{}' > "$pkgs/agent-plugin-$p/default.nix"; done

cat > "$pkgs/agent-plugin-demo/source.json" <<'EOF'
{ "version": "1.0.0",
  "src": { "owner": "acme", "repo": "skills", "rev": "abc123" },
  "skills": { "lint": "plugins/demo/skills/lint" } }
EOF
cat > "$pkgs/agent-plugin-demo/audit.json" <<'EOF'
{ "target": "./result", "score": 12, "status": "do not install",
  "tool": { "name": "skillspector", "version": "2.12.0", "osv": { "checkedAt": "2026-10-19T00:00:00Z" } },
  "plugins": [ { "name": "demo", "components": [ {
    "path": "skills/lint", "score": 12, "status": "do not install", "partial": false, "coverage": 100,
    "exceptions": [ { "reason": "reference_missing", "path": "skills/lint/SKILL.md", "line": 4 } ],
    "findings": [
      { "id": "P9", "severity": "MEDIUM", "message": "Whitespace Padding", "file": "skills/lint/SKILL.md", "line": 3 },
      { "id": "PE3", "severity": "HIGH", "message": "Credential Access", "file": "skills/lint/run.sh", "line": 7 },
      { "id": "PE3", "severity": "HIGH", "message": "Credential Access", "file": "skills/lint/run.sh", "line": 9 },
      { "id": "PE3", "severity": "CRITICAL", "message": "Credential Access", "file": "plugin.json", "line": 0 },
      { "id": "X1", "severity": "LOW", "message": "</script><b>", "file": "skills/lint/a.md", "line": 1 }
    ] } ] } ] }
EOF
cat > "$pkgs/agent-plugin-blocked/audit.json" <<'EOF'
{ "target": "./result", "audited": false, "score": null, "status": "could not audit",
  "reason": "nothing to audit", "hints": [], "tool": { "name": "skillspector", "version": "2.12.0" } }
EOF
# A package gone but for its audit.json is not listed at all.
echo '{"score": 1}' > "$pkgs/agent-plugin-gone/audit.json"

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

out="$root/index.html"
if ! python3 "$generator" "$pkgs" "$template" "$out" --rev deadbeef --rev-date 2026-10-20T00:00:00Z > "$root/stdout"; then
  fail "the generator exited non-zero"
  cat "$root/stdout"
  exit 1
fi

grep -q '__DATA__' "$out" && fail "the placeholder is still in the page"
grep -q '</script><b>' "$out" && fail "a finding's message closed the script"

data="$root/data.json"
sed -n 's/^const DATA = \(.*\);$/\1/p' "$out" > "$data"
jq -e . "$data" > /dev/null 2>&1 || fail "the embedded data is not JSON"

check() {
  local what=$1 filter=$2
  jq -e "$filter" "$data" > /dev/null 2>&1 || fail "$what ($filter)"
}
check "the commit is recorded" '.rev == "deadbeef" and .revDate == "2026-10-20T00:00:00Z"'
check "only packages with a default.nix and an audit are listed" '[.plugins[].p] == ["agent-plugin-blocked", "agent-plugin-demo"]'
check "a package with no audit is listed as not audited" '.unaudited == ["agent-plugin-new"]'
check "a could-not-audit package keeps its reason" '.plugins[0].why == "nothing to audit" and .plugins[0].s == null'
check "the upstream is named" '.plugins[1].gh == "acme/skills" and .plugins[1].rev == "abc123"'
check "a skill carries its upstream path" '.plugins[1].k[0].n == "lint" and .plugins[1].k[0].up == "plugins/demo/skills/lint"'
check "rules are kept once per id, severity and message" '(.rules | length) == 4'
check "a finding's file is relative to its skill" '[.plugins[1].k[0].f[] | .[1]] | index("run.sh") != null'
check "a file outside the skill is marked with a leading /" '[.plugins[1].k[0].f[] | .[1]] | index("/plugin.json") != null'
check "findings are ordered by severity, critical first" '.rules[.plugins[1].k[0].f[0][0]][1] == "CRITICAL"'
check "exceptions are kept" '.plugins[1].k[0].x == [["reference_missing", "skills/lint/SKILL.md", 4]]'

if [ "$failures" -ne 0 ]; then
  echo "audit-dashboard: $failures failure(s)"
  exit 1
fi
echo "audit-dashboard: all cases pass"
