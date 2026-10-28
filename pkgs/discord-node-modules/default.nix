# discord-node-modules — what agent-plugin-discord's MCP server installs at
# start, built from the bun.lock the plugin pins (ADR 0026).
{ callPackage }:

callPackage ../../lib/bun-lock-modules.nix { } { source = ../agent-plugin-discord/source.json; }
