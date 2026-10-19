# The agent-stacks CLI — the Flox implementation of the agent-plugins spec —
# fetched as a published binary rather than built from source.
#
# Named agent-stacks, not agent-stacks-bin, because package names come from
# the directory (flake.nix) and the entry point is
# `nix run <flake>#agent-stacks`. The pname keeps the -bin suffix, which is
# what the predicate in flake.nix matches on.
#
# Everything that changes between builds lives in source.json, which the
# update-agent-stacks workflow rewrites when agent-stacks/agent-stacks-cli
# uploads a new commit. source.json is never edited by hand; to move this
# package, run that workflow. This file is maintained by hand.
#
# The package is the binary wrapped so that this set's `skillspector` is on
# its PATH. `agent-stacks audit` looks `skillspector` up on PATH and cannot
# score without it, so an agent-stacks installed from this set audits with
# no separate install. Only this package is wrapped: the bare binary on
# downloads.agent-stacks.org is not, and needs `skillspector` installed
# beside it. passthru.unwrapped is the bare binary, for builds that run
# agent-stacks but never audit (buildAgentPlugin, flake.nix). ADR 0020.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeBinaryWrapper,
  skillspector,
}:

let
  source = builtins.fromJSON (builtins.readFile ./source.json);

  # What VERSION reads in the agent-stacks commit these binaries came from.
  # The binary reports this string, and the uploaded object's name embeds it,
  # so it is not the same thing as the version attribute below.
  inherit (source) baseVersion;

  # The agent-stacks commit. The upload directory is named after it in full;
  # the object inside is named after its first seven characters.
  inherit (source) rev;
  shortRev = builtins.substring 0 7 rev;

  # What the package is published as: `git describe --tags --always` in the
  # agent-stacks commit, so it names the release it descends from, the
  # distance, and the commit itself.
  #
  # The fallback is what this used to be unconditionally, and why it changed:
  # `<baseVersion>-unstable-<date>` cannot tell two commits on one day apart,
  # and on 2026-09-19 three different revisions were published as
  # 1.0.0-unstable-2026-09-19. A source.json written before the describe field
  # existed still evaluates, and still collides.
  version = source.version or "${baseVersion}-unstable-${source.date}";

  system = stdenvNoCC.hostPlatform.system;

  meta = {
    description = "CLI for building, checking, importing, and launching agent plugins";
    homepage = "https://downloads.agent-stacks.org/";
    license = lib.licenses.unfree;
    mainProgram = "agent-stacks";
    platforms = lib.attrNames source.hashes;
    # The CLI itself: not an agent, and not a plugin. ADR 0014.
    category = "agent-tool";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };

  # The binary as published. Its pname keeps the -bin suffix too, so the
  # unfree predicate admits it on its own.
  unwrapped = stdenvNoCC.mkDerivation {
    pname = "agent-stacks-bin";
    inherit version meta;

    # Uploaded by the CI workflow in agent-stacks/agent-stacks-cli, one object
    # per system per commit. Static (CGO_ENABLED=0), so the Linux binaries
    # carry no interpreter pointing into a foreign store. Nothing under
    # by-commit is ever rewritten, so these hashes stay valid for as long as
    # the object exists.
    src = fetchurl {
      url =
        "https://downloads.agent-stacks.org/agent-stacks/by-commit/${rev}"
        + "/agent-stacks-${baseVersion}-${shortRev}-${system}";
      hash =
        source.hashes.${system}
          or (throw "agent-stacks: no binary published for ${system}; see meta.platforms");
  };

  # A bare executable, not an archive.
  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/agent-stacks"
    runHook postInstall
  '';

  # Proves the fetched binary runs on the builder and reports the version the
  # commit claims. Checked against baseVersion, not version: the binary
  # prints what VERSION holds, which carries no -unstable- suffix. Skipped
  # when the binary cannot run on the build machine.
  doInstallCheck = stdenvNoCC.hostPlatform.canExecute stdenvNoCC.hostPlatform;
  installCheckPhase = ''
    runHook preInstallCheck
    got="$("$out/bin/agent-stacks" --version)"
    if [ "$got" != "${baseVersion}" ]; then
      echo "agent-stacks --version reported '$got', expected '${baseVersion}'" >&2
      exit 1
    fi
    runHook postInstallCheck
  '';
  };
in

stdenvNoCC.mkDerivation {
  pname = "agent-stacks-bin";
  inherit version meta;

  dontUnpack = true;
  nativeBuildInputs = [ makeBinaryWrapper ];

  installPhase = ''
    runHook preInstall
    makeBinaryWrapper ${lib.getExe' unwrapped "agent-stacks"} "$out/bin/agent-stacks" \
      --prefix PATH : ${lib.makeBinPath [ skillspector ]}
    runHook postInstall
  '';

  passthru = { inherit unwrapped; };
}
