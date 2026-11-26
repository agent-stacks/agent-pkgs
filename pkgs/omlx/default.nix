# omlx — the oMLX inference server (github.com/jundot/omlx), headless.
#
#   omlx serve [--model-dir DIR] [--host H] [--port P]
#
# An OpenAI- and Anthropic-compatible server (/v1/chat/completions,
# /v1/messages, /v1/models) for MLX models on Apple silicon. Models
# are found in --model-dir (default ~/.omlx/models) and in the Hugging
# Face cache (~/.cache/huggingface/hub, or $HF_HUB_CACHE). Only the
# Python server and its CLI are built: upstream's menu-bar app and DMG
# are not.
#
# MLX runs on Metal, so this is aarch64-darwin only. The Metal kernels
# are compiled by Apple's closed `metal` tool, which the Nix sandbox
# does not have, and nixpkgs' `mlx` is built with Metal off. So mlx is
# nixpkgs' `mlx-bin`, the PyPI wheels upstream publishes with the
# Metal runtime, moved to the release oMLX pins. Those wheels are
# packaged for Python 3.13, which oMLX supports (<3.14), so the
# interpreter is python313.
#
# The MLX libraries are taken at the revisions oMLX's pyproject.toml
# pins, all from source except mlx: mlx-lm and mlx-vlm overriding
# nixpkgs, mlx-audio new here. The server imports mlx-vlm and
# mlx-audio at startup. Left out, because the server imports them only
# when a request needs them: mlx-embeddings (embedding models),
# cohere-melody (Cohere tool-call parser), markitdown (file uploads
# to markdown; it alone brings onnxruntime), mlx-vlm's datasets (its
# training scripts; it brings pyarrow) and the optional extras
# (grammar, audio, mcp, cluster, modelscope, paroquant).
#
# Upstream's exact pins nixpkgs does not meet are relaxed, not
# overridden: numpy, transformers and ddgs come from
# nixpkgs. The MLX libraries' own test suites need a GPU and model
# downloads, so they are not run; the install check starts the CLI.
{
  lib,
  stdenv,
  python313,
  fetchFromGitHub,
  fetchPypi,
}:

let
  version = "0.8.4";

  src = fetchFromGitHub {
    owner = "jundot";
    repo = "omlx";
    tag = "v${version}";
    hash = "sha256-uJ+rWApCUe7IddclY/bxLXs6YG+tq3f5THieyC9mU84=";
  };

  # The mlx release oMLX pins. The wheel and the Metal runtime move
  # together; nixpkgs' mlx-bin asserts they match.
  mlxVersion = "0.32.5";

  python = python313.override {
    self = python;
    packageOverrides = pyFinal: pyPrev: {
      mlx-metal = pyPrev.mlx-metal.overridePythonAttrs {
        version = mlxVersion;
        src = fetchPypi {
          pname = "mlx_metal";
          version = mlxVersion;
          format = "wheel";
          dist = "py3";
          python = "py3";
          abi = "none";
          platform = "macosx_14_0_arm64";
          hash = "sha256-xmLDVDucXaLL4SEmnN8JnRREekjawtTT6Wll3zYpx4c=";
        };
      };

      mlx =
        (pyPrev.mlx-bin.override { inherit (pyFinal) mlx-metal; }).overridePythonAttrs
          {
            version = mlxVersion;
            src = fetchPypi {
              pname = "mlx";
              version = mlxVersion;
              format = "wheel";
              dist = "cp313";
              python = "cp313";
              abi = "cp313";
              platform = "macosx_14_0_arm64";
              hash = "sha256-Tgc+ilZou5V9vugqVx58g3m8118KJKmGIo1mGrkLzQU=";
            };
            # The wheel's tests are mlx's source tree at the tag; not run.
            passthru.tests = { };
          };

      # mlx-lm main after 0.32.2, the commit oMLX pins.
      mlx-lm = pyPrev.mlx-lm.overridePythonAttrs {
        version = "0.32.3.dev0";
        src = fetchFromGitHub {
          owner = "ml-explore";
          repo = "mlx-lm";
          rev = "0d4d3d04f8ab7ce4a51e7209e8615755a48ba94d";
          hash = "sha256-7yhde/j0RIKOefGoEiWcugKoftv4ikb/REnVwLQDapg=";
        };
        env.SETUPTOOLS_SCM_PRETEND_VERSION = "0.32.3.dev0";
        doCheck = false;
      };

      mlx-audio = pyFinal.buildPythonPackage {
        pname = "mlx-audio";
        version = "0.6.5";
        pyproject = true;
        src = fetchFromGitHub {
          owner = "Neywa-Labs";
          repo = "mlx-audio";
          rev = "1157775c1999654b1ebde41ed03d88108e23f88b";
          hash = "sha256-TA7KtIyqpY63SfRzzkenwSmDoHJYCFY2EfASpd76wE8=";
        };
        build-system = with pyFinal; [
          setuptools
          wheel
        ];
        dependencies = with pyFinal; [
          huggingface-hub
          jinja2
          miniaudio
          mlx
          numpy
          scipy
          sentencepiece
          sounddevice
          tqdm
          transformers
        ];
        doCheck = false;
        pythonImportsCheck = [ "mlx_audio" ];
        meta = {
          description = "Text-to-speech, speech-to-text and speech-to-speech on MLX";
          homepage = "https://github.com/Neywa-Labs/mlx-audio";
          license = lib.licenses.mit;
          platforms = [ "aarch64-darwin" ];
        };
      };

      # nixpkgs marks its 0.4.4 broken; this is the commit oMLX pins.
      mlx-vlm = pyPrev.mlx-vlm.overridePythonAttrs (old: {
        version = "0.8.1";
        src = fetchFromGitHub {
          owner = "Neywa-Labs";
          repo = "mlx-vlm";
          rev = "36494b42c7676081aa3c14878b3175b90c2fedf4";
          hash = "sha256-xEHl6GMPllitvB+nRdvZdL8Svx75reqrRV3kmMXVpGc=";
        };
        build-system = with pyFinal; [
          setuptools
          wheel
        ];
        dependencies =
          builtins.filter (d: (d.pname or "") != "datasets") old.dependencies
          ++ (with pyFinal; [
            cryptography
            httpx
            jinja2
            llguidance
            mlx-audio
            python-multipart
            sentencepiece
            starlette
            websockets
          ]);
        pythonRemoveDeps = [ "datasets" ];
        doCheck = false;
        meta = old.meta // {
          broken = false;
          changelog = null;
        };
      });
    };
  };

  py = python.pkgs;
in
py.buildPythonApplication {
  pname = "omlx";
  inherit version src;
  pyproject = true;

  # The build requirements name cmake, nanobind and mlx for the optional
  # custom Metal kernels (OMLX_WITH_CUSTOM_KERNEL), which are not built:
  # they need the `metal` compiler too. Without them setup.py builds a
  # pure-Python wheel.
  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail '"cmake>=3.27",' "" \
      --replace-fail '"nanobind==3.1.0",' "" \
      --replace-fail '    "mlx==0.32.5",
]
build-backend' ']
build-backend'
  '';

  build-system = with py; [
    setuptools
    wheel
  ];

  dependencies = with py; [
    ddgs
    fastapi
    httpx
    huggingface-hub
    itsdangerous
    jinja2
    jsonschema
    mistral-common
    mlx
    mlx-audio
    mlx-lm
    mlx-vlm
    numpy
    openai-harmony
    pillow
    protobuf
    psutil
    python-multipart
    pyyaml
    regex
    requests
    rich
    sentencepiece
    setproctitle
    socksio
    tabulate
    tiktoken
    tokenizers
    tqdm
    transformers
    uvicorn
  ];

  pythonRelaxDeps = [
    "ddgs"
    "mlx"
    "mlx-lm"
    "mlx-vlm"
    "mlx-audio"
    "numpy"
    "transformers"
  ];

  # Imported only when a request needs them; see the header.
  pythonRemoveDeps = [
    "cohere-melody"
    "cohere_melody"
    "markitdown"
    "mlx-embeddings"
  ];

  pythonImportsCheck = [
    "omlx"
    "omlx.server"
  ];

  # Upstream's tests load models and need a GPU, so the check phase
  # starts the CLI instead. Left on: buildPythonPackage runs this
  # phase only when doCheck is set.
  installCheckPhase = ''
    runHook preInstallCheck
    HOME=$(mktemp -d) $out/bin/omlx --version | grep -F ${version}
    HOME=$(mktemp -d) $out/bin/omlx serve --help > /dev/null
    runHook postInstallCheck
  '';

  passthru = { inherit python; };

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
