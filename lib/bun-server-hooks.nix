# The overrideAttrs hooks for a plugin whose server runs `bun install`
# in its root: ship the modules tree and make that install a no-op
# (ADR 0026).
{ makeBinaryWrapper }:

modules: old: {
  nativeBuildInputs = old.nativeBuildInputs ++ [ makeBinaryWrapper ];
  postAssemble = old.postAssemble + ''
    cp -R ${modules}/node_modules "$dest/node_modules"
    chmod -R u+w "$dest/node_modules"
    bun="$(realpath "$dest/bin/bun")"
    rm "$dest/bin/bun"
    makeBinaryWrapper "$bun" "$dest/bin/bun" --set-default BUN_CONFIG_SKIP_INSTALL_PACKAGES 1
  '';
  postInstallCheck = (old.postInstallCheck or "") + ''
    copy="$TMPDIR/read-only-plugin"
    cp -R "$out/${old.passthru.agentPlugin.path}" "$copy"
    chmod -R a-w "$copy"
    if ! HOME="$TMPDIR" BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache" BUN_CONFIG_REGISTRY=http://127.0.0.1:9 \
        "$copy/bin/bun" install --cwd "$copy" --no-summary; then
      echo "the plugin's bun install is no longer a no-op offline in a read-only root; a Bun upgrade broke it (ADR 0026)" >&2
      exit 1
    fi
    chmod -R u+w "$copy"
  '';
}
