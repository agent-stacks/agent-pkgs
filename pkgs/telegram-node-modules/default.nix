# telegram-node-modules — what agent-plugin-telegram's MCP server installs at
# start, built from the bun.lock the plugin pins (ADR 0030).
{ callPackage }:

callPackage ../../lib/bun-lock-modules.nix { } { plugin = ../agent-plugin-telegram; }
