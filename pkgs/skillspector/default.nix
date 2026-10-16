# NVIDIA SkillSpector, the security scanner `agent-stacks audit` runs,
# and the default audit tool of every stack (mappings/audit-tools.nix).
#
# Built from uv.lock with uv2nix. pyproject.toml here is a wrapper that
# exists only to lock skillspector at the commit it names; hashes.json
# records that commit and the version it carries. upgrade.sh moves all
# three. Ported from flox/floxenvs .flox/pkgs/skillspector, with that
# repository's sibling wrapper packages for the uv2nix libraries
# replaced by this flake's inputs (flake.nix, ADR 0020).
{
  lib,
  python313,
  callPackage,
  yara,
  runCommand,
  makeBinaryWrapper,
  pyproject-nix,
  uv2nix,
  pyproject-build-systems,
}:

let
  workspace = uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = ./.;
  };

  overlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };

  pyprojectOverrides =
    final: prev:
    let
      addBuildSystem =
        buildSystem: pkg:
        pkg.overrideAttrs (old: {
          nativeBuildInputs =
            (old.nativeBuildInputs or [ ]) ++ final.resolveBuildSystem { "${buildSystem}" = [ ]; };
        });
      addSetuptools = addBuildSystem "setuptools";
      addHatchling = addBuildSystem "hatchling";
    in
    {
      # Git-sourced skillspector: uv doesn't capture the
      # declared build-system in the lockfile, and upstream
      # uses hatchling.
      skillspector = addHatchling prev.skillspector;

      # forbiddenfruit sdist needs setuptools (no build-system decl).
      forbiddenfruit = addSetuptools prev.forbiddenfruit;

      # yara-python sdist needs setuptools + the libyara
      # C library at build time.
      yara-python = (addSetuptools prev.yara-python).overrideAttrs (old: {
        buildInputs = (old.buildInputs or [ ]) ++ [ yara ];
      });
    };

  pythonSet =
    (callPackage pyproject-nix.build.packages {
      python = python313;
    }).overrideScope
      (
        lib.composeManyExtensions [
          pyproject-build-systems.overlays.default
          overlay
          pyprojectOverrides
        ]
      );

  venv = pythonSet.mkVirtualEnv "skillspector-env" workspace.deps.default;

  version = (lib.importJSON ./hashes.json).version;

in
# Expose ONLY bin/skillspector. Installing the venv itself would put its
# bin/python{,3,3.13} symlinks on the environment's bin/ and collide
# with an environment-level python3.
runCommand "skillspector-${version}"
  {
    pname = "skillspector";
    inherit version;
    nativeBuildInputs = [ makeBinaryWrapper ];

    passthru = {
      inherit venv;
      python = python313;
    };

    meta = {
      description = "Security scanner for AI agent skills";
      homepage = "https://github.com/NVIDIA/SkillSpector";
      license = lib.licenses.asl20;
      mainProgram = "skillspector";
      platforms = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      # Audits plugins rather than being an agent or one. ADR 0014.
      category = "agent-tool";
    };
  }
  ''
    mkdir -p $out/bin
    makeBinaryWrapper ${venv}/bin/skillspector $out/bin/skillspector
  ''
