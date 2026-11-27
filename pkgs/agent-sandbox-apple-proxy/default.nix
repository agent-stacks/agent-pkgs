# agent-sandbox-apple-proxy — the network exit of the VM that runs the
# agent on a Mac.
#
#   agent-sandbox-apple-proxy --socket <path> --allow <file> --startup <file> --log <file>
#
# An HTTP CONNECT proxy on a Unix socket (mode 0600); it prints `ready`
# once listening and exits 0, removing the socket, on SIGTERM or SIGINT.
#
#   - a target must name a host on the --allow list, or on the --startup
#     list until the VM sends CONNECT agent-sandbox-apple.start-done:0,
#     which closes the startup hosts for good; IP literals are refused;
#   - the host is resolved once, every address must be public (no
#     loopback, private, link-local, CGNAT or metadata address), and the
#     connection goes to those addresses in turn, never to the name
#     again, so the VM cannot reach the Mac or its network through it;
#   - a client has 30 s to send its request head; the soft open-file
#     limit is raised to min(hard, 10240), and out of descriptors it
#     waits rather than spinning;
#   - every decision is a line in the --log file: `allow host:port -> ip`,
#     `deny target (reason)`, `latch closed`.
#
# Standard library only, no crates.
{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "agent-sandbox-apple-proxy";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      ./tests
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;

  # The tests listen on a Unix socket and resolve localhost.
  __darwinAllowLocalNetworking = true;

  meta = {
    description = "Allow-list CONNECT proxy on a Unix socket for the agent-sandbox-apple VM";
    license = lib.licenses.mit;
    mainProgram = "agent-sandbox-apple-proxy";
    platforms = lib.platforms.unix;
    # Supports an agent rather than being one. ADR 0014.
    category = "agent-tool";
  };
}
