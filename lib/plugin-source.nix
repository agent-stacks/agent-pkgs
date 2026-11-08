# pluginSource — a plugin package's call file and the upstream tree it
# pins, fetched at evaluation so files in it (a Cargo.lock, a bun.lock)
# can be read without import-from-derivation (ADR 0025, 0030).
#
# The call file is default.json since agent-stacks ADR 0086 (ADR 0028),
# else the source.json of a plugin no such binary has replayed yet. The
# NAR hash fetchFromGitHub recorded is the hash of this same unpacked
# tree, so no second hash is kept by hand.
pluginDir:

let
  callFile =
    if builtins.pathExists (pluginDir + "/default.json") then pluginDir + "/default.json"
    else pluginDir + "/source.json";
  call = builtins.fromJSON (builtins.readFile callFile);
in
{
  inherit call;
  src = builtins.fetchTarball {
    url = "https://github.com/${call.src.owner}/${call.src.repo}/archive/${call.src.rev}.tar.gz";
    sha256 = call.src.hash;
  };
}
