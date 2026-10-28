# imessage-node-modules — what agent-plugin-imessage's MCP server installs at
# start, built from the bun.lock the plugin pins (ADR 0026).
{ lib, callPackage }:

let
  source = builtins.fromJSON (builtins.readFile ../agent-plugin-imessage/source.json);
in
(callPackage ../../lib/bun-lock-modules.nix { }) {
  name = "imessage";
  # Read at evaluation, as impeccable-engine reads its source.
  src = builtins.fetchTarball {
    url = "https://github.com/${source.src.owner}/${source.src.repo}/archive/${source.src.rev}.tar.gz";
    sha256 = source.src.hash;
  };
  dir = builtins.dirOf source.pluginRootPaths."bun.lock";
}
