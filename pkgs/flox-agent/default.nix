# The flox-agent CLI — the Flox implementation of the agent-plugins spec —
# fetched as a published binary rather than built from source.
#
# Named flox-agent, not flox-agent-bin, because package names come from the
# directory (flake.nix) and the acceptance command is
# `nix run <flake>#flox-agent`. The pname keeps the -bin suffix, which is what
# the allowUnfreePredicate in flake.nix matches on.
#
# Bumping a version: change version, then for each system run
#   nix store prefetch-file --json <url> | jq -r .hash
# The objects are immutable per version, so the hashes only change with it.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  version = "0.8.0";

  # Published by the build-and-publish workflow in agent-stacks/flox-agent,
  # which uploads the nix build output for each system. Static (CGO_ENABLED=0),
  # so the Linux binaries carry no interpreter pointing into a foreign store.
  hashes = {
    x86_64-linux = "sha256-1qAt7x9kTsIHyQ5y2ynezm/YdA1hzwuYIcqtvMEJIhg=";
    aarch64-linux = "sha256-C6BSr2NqYplhY5ZmNAcgon+yt33Vjj6E+/1Nh1EQ4vc=";
    x86_64-darwin = "sha256-P1978i0YAlEFc5xvL5uMSQkYwlkDL2T/0lvwHjt6goQ=";
    aarch64-darwin = "sha256-M+E/4VVzN4/CaV2/Ml61NyJbjv+fOcazYUrx8ErQhZI=";
  };

  system = stdenvNoCC.hostPlatform.system;
in

stdenvNoCC.mkDerivation {
  pname = "flox-agent-bin";
  inherit version;

  src = fetchurl {
    url = "https://downloads.agent-stacks.org/flox-agent/${version}/flox-agent-${version}-${system}";
    hash =
      hashes.${system}
        or (throw "flox-agent: no binary published for ${system}; see meta.platforms");
  };

  # A bare executable, not an archive.
  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/flox-agent"
    runHook postInstall
  '';

  # Proves the fetched binary runs on the builder and reports the version this
  # derivation claims — the acceptance criterion that `flox-agent --version`
  # matches what generated a given generated.nix. Skipped when the binary
  # cannot run on the build machine.
  doInstallCheck = stdenvNoCC.hostPlatform.canExecute stdenvNoCC.hostPlatform;
  installCheckPhase = ''
    runHook preInstallCheck
    got="$("$out/bin/flox-agent" --version)"
    if [ "$got" != "${version}" ]; then
      echo "flox-agent --version reported '$got', expected '${version}'" >&2
      exit 1
    fi
    runHook postInstallCheck
  '';

  meta = {
    description = "Flox-native config management for Claude Code CLI";
    homepage = "https://downloads.agent-stacks.org/";
    license = lib.licenses.unfree;
    mainProgram = "flox-agent";
    platforms = lib.attrNames hashes;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
