# NVIDIA SkillSpector, the security scanner `agent-stacks audit` runs.
# Packaged for the CI job that audits every plugin in this set and for
# users, as `agent-stacks/skillspector` in the catalog. ADR 0020.
#
# Built with uv2nix from the uv.lock upstream ships at the release tag
# the `skillspector-src` flake input names, so the version is that
# tag's and flake.lock pins its revision. SkillSpector moves by
# editing the tag in flake.nix, in a reviewed pull request. Ported
# from flox/floxenvs .flox/pkgs/skillspector, with that repository's
# vendored lock and sibling wrapper packages for the uv2nix libraries
# replaced by this flake's inputs.
#
# python313 and yara (the libyara yara-python builds against) are not
# pinned here: they come from this flake's nixpkgs and move with its
# hourly bump. A known limit, ADR 0020.
{
  lib,
  python313,
  callPackage,
  yara,
  runCommand,
  makeBinaryWrapper,
  skillspector-src,
  pyproject-nix,
  uv2nix,
  pyproject-build-systems,
}:

let
  workspace = uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = skillspector-src;
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
    in
    {
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

  # The workspace root is skillspector itself, so its version is the
  # one the tag's pyproject.toml declares.
  version = pythonSet.skillspector.version;

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
