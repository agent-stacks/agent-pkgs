# The flox-agent CLI — the Flox implementation of the agent-plugins spec —
# fetched as a published binary rather than built from source.
#
# Named flox-agent, not flox-agent-bin, because package names come from the
# directory (flake.nix) and the entry point is `nix run <flake>#flox-agent`.
# The pname keeps the -bin suffix, which is what the predicate in flake.nix
# matches on.
#
# Everything that changes between builds lives in source.json, which the
# update-flox-agent workflow rewrites when agent-stacks/flox-agent uploads a
# new commit. Nothing here is edited by hand; to move this package, run that
# workflow rather than editing either file.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  source = builtins.fromJSON (builtins.readFile ./source.json);

  # What VERSION reads in the flox-agent commit these binaries came from. The
  # binary reports this string, and the uploaded object's name embeds it, so
  # it is not the same thing as the version attribute below.
  inherit (source) baseVersion;

  # The flox-agent commit. The upload directory is named after it in full; the
  # object inside is named after its first seven characters.
  inherit (source) rev;
  shortRev = builtins.substring 0 7 rev;

  # A snapshot between releases, named the way nixpkgs names one. The date is
  # the day the binaries were uploaded.
  version = "${baseVersion}-unstable-${source.date}";

  system = stdenvNoCC.hostPlatform.system;
in

stdenvNoCC.mkDerivation {
  pname = "flox-agent-bin";
  inherit version;

  # Uploaded by the CI workflow in agent-stacks/flox-agent, one object per
  # system per commit. Static (CGO_ENABLED=0), so the Linux binaries carry no
  # interpreter pointing into a foreign store. Nothing under by-commit is ever
  # rewritten, so these hashes stay valid for as long as the object exists.
  src = fetchurl {
    url =
      "https://downloads.agent-stacks.org/flox-agent/by-commit/${rev}"
      + "/flox-agent-${baseVersion}-${shortRev}-${system}";
    hash =
      source.hashes.${system}
        or (throw "flox-agent: no binary published for ${system}; see meta.platforms");
  };

  # A bare executable, not an archive.
  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/flox-agent"
    runHook postInstall
  '';

  # Proves the fetched binary runs on the builder and reports the version the
  # commit claims. Checked against baseVersion, not version: the binary prints
  # what VERSION holds, which carries no -unstable- suffix. Skipped when the
  # binary cannot run on the build machine.
  doInstallCheck = stdenvNoCC.hostPlatform.canExecute stdenvNoCC.hostPlatform;
  installCheckPhase = ''
    runHook preInstallCheck
    got="$("$out/bin/flox-agent" --version)"
    if [ "$got" != "${baseVersion}" ]; then
      echo "flox-agent --version reported '$got', expected '${baseVersion}'" >&2
      exit 1
    fi
    runHook postInstallCheck
  '';

  meta = {
    description = "Flox-native config management for Claude Code CLI";
    homepage = "https://downloads.agent-stacks.org/";
    license = lib.licenses.unfree;
    mainProgram = "flox-agent";
    platforms = lib.attrNames source.hashes;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
