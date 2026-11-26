#!/usr/bin/env bash
# Moves pkgs/omlx to an oMLX release and re-locks it.
#
#   nix shell --inputs-from . nixpkgs#uv nixpkgs#python313 nixpkgs#curl \
#     -c pkgs/omlx/upgrade.sh [TAG]
#
# TAG defaults to oMLX's latest GitHub release. The script
#
#   1. points [tool.uv.sources] in pyproject.toml at TAG,
#   2. copies oMLX's own [tool.uv] override-dependencies at TAG
#      between the "upstream overrides" markers in pyproject.toml
#      (uv applies a project's overrides only when it is the project
#      being locked, so oMLX's git pins of mlx and mlx-lm are lost
#      unless repeated here), and
#   3. regenerates uv.lock with every dependency re-resolved, so
#      transitive pins move too even when TAG is the current one.
#
# Then build: nix build .#omlx. Its version is the one uv.lock records
# for omlx, so there are no hashes to refresh by hand.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pyproject="$here/pyproject.toml"

# Authenticated when a token is set, for the 5000/hr API limit rather
# than the shared anonymous 60/hr. Conditional: an empty Bearer value
# is refused.
auth=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

tag="${1:-}"
if [ -z "$tag" ]; then
  tag="$(curl -sSfL "${auth[@]}" https://api.github.com/repos/jundot/omlx/releases/latest |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])')"
fi
case "$tag" in
  v*) ;;
  *) echo "upgrade.sh: tag '$tag' does not start with v" >&2; exit 1 ;;
esac

upstream="$(mktemp)"
trap 'rm -f "$upstream"' EXIT
curl -sSfL "https://raw.githubusercontent.com/jundot/omlx/$tag/pyproject.toml" -o "$upstream"

python3 - "$pyproject" "$upstream" "$tag" <<'EOF'
import re, sys, tomllib

path, upstream, tag = sys.argv[1:]
with open(upstream, "rb") as f:
    overrides = tomllib.load(f).get("tool", {}).get("uv", {}).get("override-dependencies", [])
with open(path) as f:
    text = f.read()

begin, end = "  # BEGIN upstream overrides\n", "  # END upstream overrides\n"
head, rest = text.split(begin, 1)
block, tail = rest.split(end, 1)
# The block's leading comment is kept; only the entries are replaced.
comment = "".join(l + "\n" for l in block.splitlines() if l.lstrip().startswith("#"))
entries = "".join(f'  "{o}",\n' for o in overrides)
text = head + begin + comment + entries + end + tail

text, n = re.subn(r'(omlx = \{ git = "[^"]+", tag = )"[^"]+"', rf'\1"{tag}"', text)
if n != 1:
    sys.exit("upgrade.sh: no omlx source line in pyproject.toml")
with open(path, "w") as f:
    f.write(text)
EOF

cd "$here"
uv lock --upgrade --python-preference only-system
echo "pkgs/omlx: oMLX $tag locked; build it with nix build .#omlx"
