# discord-node-modules — what agent-plugin-discord's MCP server installs at
# start, built from the bun.lock the plugin pins (ADR 0026).
{ lib, callPackage }:

let
  source = builtins.fromJSON (builtins.readFile ../agent-plugin-discord/source.json);
in
(callPackage ../../lib/bun-lock-modules.nix { }) {
  name = "discord";
  # Read at evaluation, as impeccable-engine reads its source.
  src = builtins.fetchTarball {
    url = "https://github.com/${source.src.owner}/${source.src.repo}/archive/${source.src.rev}.tar.gz";
    sha256 = source.src.hash;
  };
  dir = builtins.dirOf source.pluginRootPaths."bun.lock";
}
