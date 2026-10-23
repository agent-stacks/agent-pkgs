# impeccable-engine — the Rust binary every impeccable skill verb runs.
#
# Built from the commit agent-plugin-impeccable pins, read from its
# source.json, so the hourly replay moves the plugin and its engine
# together. The plugin ships it in the slot upstream's launcher tries
# before downloading one (ADR 0025).
{
  lib,
  rustPlatform,
}:

let
  source = builtins.fromJSON (builtins.readFile ../agent-plugin-impeccable/source.json);

  # Fetched at evaluation, not as a derivation, so Cargo.lock and
  # Cargo.toml can be read without import-from-derivation and no
  # vendor hash has to be kept in step by hand. The NAR hash
  # fetchFromGitHub recorded is the hash of this same unpacked tree.
  src = builtins.fetchTarball {
    url = "https://github.com/${source.src.owner}/${source.src.repo}/archive/${source.src.rev}.tar.gz";
    sha256 = source.src.hash;
  };

  # What the launcher expects, against what this commit builds.
  skillVersion = lib.trim (builtins.readFile "${src}/${source.skills.impeccable}/scripts/VERSION");
  workspace = builtins.fromTOML (builtins.readFile "${src}/Cargo.toml");
in
rustPlatform.buildRustPackage {
  pname = "impeccable-engine";
  version = workspace.workspace.package.version;
  inherit src;

  cargoLock.lockFile = "${src}/Cargo.lock";
  cargoBuildFlags = [ "-p" "impeccable" ];
  # The crate's unit tests, which all live in its library; upstream
  # marks the ones that need Chromium #[ignore]. The suites under
  # crates/cli/tests drive Chrome and timed loopback servers, which
  # fail in the build sandbox.
  cargoTestFlags = [ "-p" "impeccable" "--lib" ];
  # Some unit tests listen on 127.0.0.1.
  __darwinAllowLocalNetworking = true;

  # The launcher execs the sibling slot without asking its version, so
  # a commit whose engine and VERSION disagree fails here instead.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    probe="$($out/bin/impeccable engine-probe)"
    if [ "$probe" != "impeccable-engine ${skillVersion}" ]; then
      echo "the skill's scripts/VERSION is ${skillVersion}, but the engine says: $probe" >&2
      exit 1
    fi
    runHook postInstallCheck
  '';

  meta = {
    description = "Engine behind the impeccable design skill's commands";
    homepage = "https://github.com/pbakaus/impeccable";
    license = lib.licenses.asl20;
    mainProgram = "impeccable";
    platforms = lib.platforms.unix;
    # Supports an agent rather than being one. ADR 0014.
    category = "agent-tool";
  };
}
