# The overrideAttrs hooks for a plugin whose server runs `bun install`
# in its root: ship the tree that install would lay out, so the install
# finds nothing to do and the server starts offline (ADR 0030).
#
# Bun is not wrapped. With the lock's tree in place, upstream's own
# `bun install` exits 0 in a read-only root without touching the
# network, and the install check below proves that on every build.
{ }:

modules: old: {
  postAssemble = old.postAssemble + ''
    if [ -e "$dest/node_modules" ]; then
      echo "the plugin already ships node_modules; the tree from ${modules.name} would be merged into it (ADR 0030)" >&2
      exit 1
    fi
    cp -R ${modules}/node_modules "$dest/node_modules"
    chmod -R u+w "$dest/node_modules"
  '';
  # Upstream's install, as its start script runs it, unwrapped, offline,
  # in a read-only copy. It exits 0 only when node_modules matches
  # bun.lock and Bun writes nothing; a missing or wrong package makes it
  # try the unreachable registry and fail. Then the same install with
  # one package removed must fail, so a Bun that stops checking the tree
  # cannot pass the first step.
  postInstallCheck = (old.postInstallCheck or "") + ''
    offline_install() {
      HOME="$TMPDIR" BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache" BUN_CONFIG_REGISTRY=http://127.0.0.1:9 \
        "$1/bin/bun" install --cwd "$1" --no-summary
    }
    copy="$TMPDIR/read-only-plugin"
    cp -R "$out/${old.passthru.agentPlugin.path}" "$copy"
    chmod -R a-w "$copy"
    if ! offline_install "$copy"; then
      echo "bun install is not a no-op offline in the read-only plugin: node_modules does not match bun.lock, or Bun now writes to the root (ADR 0030)" >&2
      exit 1
    fi
    chmod -R u+w "$copy"

    victim="$(find "$copy/node_modules" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name '@*' | sort | head -n 1)"
    if [ -n "$victim" ]; then
      rm -rf "$victim"
      chmod -R a-w "$copy"
      if offline_install "$copy" >/dev/null 2>&1; then
        echo "bun install still passed offline with $(basename "$victim") removed, so it no longer checks the tree and the step above proves nothing (ADR 0030)" >&2
        exit 1
      fi
      chmod -R u+w "$copy"
    fi
  '';
}
