# omlx — the oMLX inference server (github.com/jundot/omlx), headless.
#
#   omlx serve [--model-dir DIR] [--base-path DIR] [--host H] [--port P]
#
# An OpenAI- and Anthropic-compatible server (/v1/chat/completions,
# /v1/messages, /v1/models) for MLX models on Apple silicon. Models
# are found in --model-dir (default ~/.omlx/models) and in the Hugging
# Face cache (~/.cache/huggingface/hub, or $HF_HUB_CACHE). Only the
# Python server and its CLI are built: upstream's menu-bar app and DMG
# are not.
#
# Built with uv2nix from uv.lock next to this file, which upgrade.sh
# generates from pyproject.toml: oMLX at the release tag named there,
# with the mcp, grammar and audio extras, every dependency at the
# version uv resolved and from its wheel where PyPI has one. The uv2nix
# libraries are this flake's inputs, as for pkgs/skillspector. Ported
# from flox/floxenvs .flox/pkgs/omlx.
#
# MLX runs on Metal, so this is aarch64-darwin only. The mlx and
# mlx-metal wheels from PyPI carry the Metal kernels, compiled by
# Apple's closed `metal` tool, which the Nix sandbox does not have.
# oMLX's optional custom kernels need that tool too and are not built,
# so oMLX itself is a pure-Python wheel.
#
# The MLX libraries' own test suites need a GPU and model downloads, so
# they are not run; the install check starts the CLI.
{
  lib,
  python313,
  callPackage,
  stdenv,
  stdenvNoCC,
  makeBinaryWrapper,
  pyproject-nix,
  uv2nix,
  pyproject-build-systems,
}:

let
  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

  overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

  sitePackages = python313.sitePackages;

  pyprojectOverrides =
    final: prev:
    let
      addSetuptools =
        pkg:
        pkg.overrideAttrs (old: {
          nativeBuildInputs =
            (old.nativeBuildInputs or [ ]) ++ final.resolveBuildSystem { setuptools = [ ]; };
        });
    in
    {
      # Git sources: uv does not record their build requirements in the
      # lock, so uv2nix builds them without setuptools. oMLX's own
      # build requirements also name cmake, nanobind and mlx, for the
      # custom Metal kernels, which are not built (see the header).
      mlx-audio = addSetuptools prev.mlx-audio;
      mlx-embeddings = addSetuptools prev.mlx-embeddings;
      # mlx-lm takes its version from git through setuptools-scm, and
      # the source uv2nix fetches has no .git, so the version uv
      # resolved is handed over. Without it mlx_lm/_version.py is not
      # written and `import mlx_lm` fails.
      mlx-lm = prev.mlx-lm.overrideAttrs (old: {
        nativeBuildInputs =
          (old.nativeBuildInputs or [ ])
          ++ final.resolveBuildSystem {
            setuptools = [ ];
            setuptools-scm = [ ];
          };
        env = (old.env or { }) // {
          SETUPTOOLS_SCM_PRETEND_VERSION = prev.mlx-lm.version;
        };
      });
      mlx-vlm = addSetuptools prev.mlx-vlm;
      omlx = addSetuptools prev.omlx;

      # PyPI sdists that declare no build system.
      docopt = addSetuptools prev.docopt;
      jieba = addSetuptools prev.jieba;

      # Another such sdist, which also reads its own version through
      # pkg_resources at import time. setuptools 82 dropped
      # pkg_resources, and pyproject.toml lifts mlx-audio's
      # setuptools<81 cap past it; mlx-audio's server.py and
      # sts/voice_pipeline.py import webrtcvad unguarded, so the call
      # is swapped for importlib.metadata's. In postPatch, so the
      # shipped bytecode is compiled from the patched source. Drop it
      # with the pyproject.toml override once mlx-audio lifts its cap.
      webrtcvad = (addSetuptools prev.webrtcvad).overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace webrtcvad.py \
            --replace-fail \
              "import pkg_resources" \
              "import importlib.metadata" \
            --replace-fail \
              "pkg_resources.get_distribution('webrtcvad').version" \
              "importlib.metadata.version('webrtcvad')"
        '';
      });

      # The mlx wheel's core.cpython-313-darwin.so loads
      # @loader_path/lib/libmlx.dylib, which ships in the separate
      # mlx-metal wheel. The virtualenv joins the two with symlinks,
      # and @loader_path resolves through the symlink to mlx's own
      # store path, which has no mlx/lib/. A copy of mlx-metal's
      # mlx/lib/ in mlx's store path is where dyld finds it.
      mlx = prev.mlx.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          mkdir -p $out/${sitePackages}/mlx/lib
          cp -r ${final.mlx-metal}/${sitePackages}/mlx/lib/. $out/${sitePackages}/mlx/lib/
        '';
      });
    };

  # Wheels are picked for macOS 15, not nixpkgs' minimum SDK. MLX
  # needs macOS 15 to run, and some dependencies publish only
  # macosx_15_0 wheels (opencv-python, which mlx-vlm needs): against
  # the lower default uv2nix would build those from their sdists.
  pythonSet =
    (callPackage pyproject-nix.build.packages {
      python = python313;
      stdenv = stdenv.override {
        targetPlatform = stdenv.targetPlatform // {
          darwinSdkVersion = "15.0";
        };
      };
    }).overrideScope
      (
        lib.composeManyExtensions [
          pyproject-build-systems.overlays.default
          overlay
          pyprojectOverrides
        ]
      );

  # bin/python here imports oMLX's MLX, for a caller that needs to ask
  # Metal something directly; it is the package's passthru.venv.
  venv = (pythonSet.mkVirtualEnv "omlx-env" workspace.deps.default).overrideAttrs (old: {
    meta = (old.meta or { }) // {
      mainProgram = "python";
    };
  });

  version = pythonSet.omlx.version;

in
# Only bin/omlx. The virtualenv's bin/ also holds python and every
# dependency's scripts, which would collide in an environment that has
# its own.
stdenvNoCC.mkDerivation {
  pname = "omlx";
  inherit version;

  dontUnpack = true;
  nativeBuildInputs = [ makeBinaryWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    makeBinaryWrapper ${venv}/bin/omlx $out/bin/omlx
    runHook postInstall
  '';

  # Upstream's tests load models and need a GPU, so the check starts
  # the CLI instead. `omlx serve --help` imports little, so the server
  # module, which imports mlx-lm, mlx-vlm and mlx-audio, is imported
  # too, and webrtcvad, which the setuptools override above puts at
  # risk.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    HOME=$(mktemp -d) $out/bin/omlx --version | grep -F ${version}
    HOME=$(mktemp -d) $out/bin/omlx serve --help > /dev/null
    HOME=$(mktemp -d) ${venv}/bin/python -I -c "import omlx.server"
    ${venv}/bin/python -I -c "import webrtcvad; webrtcvad.Vad(2)"
    runHook postInstallCheck
  '';

  # No passthru.python: python313's own mlx is nixpkgs', built without
  # Metal, so `python.withPackages (ps: [ ps.mlx ])` would not be
  # oMLX's MLX. The virtualenv is.
  passthru = { inherit venv; };

  meta = {
    description = "LLM inference server for Apple silicon, built on MLX";
    homepage = "https://github.com/jundot/omlx";
    changelog = "https://github.com/jundot/omlx/releases/tag/v${version}";
    license = lib.licenses.asl20;
    mainProgram = "omlx";
    platforms = [ "aarch64-darwin" ];
    # Serves a model to an agent rather than being one. ADR 0014.
    category = "agent-tool";
  };
}
