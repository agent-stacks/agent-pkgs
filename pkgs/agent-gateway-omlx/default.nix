# agent-gateway-omlx — oMLX behind the agent-gateway contract
# (agent-stacks spec proposal 0002, section 7):
#
#   agent-gateway-omlx describe
#   agent-gateway-omlx check <model dir | model.json>...
#   agent-gateway-omlx serve [--listen <host:port>] [<models dir>...] [-- <server args>]
#   agent-gateway-omlx status --url <url>
#
# The second gateway after agent-gateway-llama-cpp, sharing its
# contract module (lib/agent-gateway). `serve` links every MLX model
# directory in the models directories (by default
# AGENT_STACKS_MODELS_DIR, else $FLOX_ENV/share/agent-models) into a
# per-run model directory under its model.json id, and runs
# `omlx serve --model-dir` over it: every model at one endpoint,
# loaded when a request names it. Borrowed MLX models in the Hugging
# Face cache are served as oMLX serves them. SIGHUP re-reads the
# models directories and reloads oMLX's list.
#
# oMLX keeps its settings, logs and caches under a base path, and
# writes CLI flags into its settings.json. The gateway gives it a
# per-run one, and runs it with HOME there too, so the user's ~/.omlx
# (and the ~/.omlx/bin shim oMLX publishes) is never read or written.
#
# MLX only: oMLX serves GGUF for a few families through a separate
# engine (Splash) that is not packaged. The build runs the contract on
# the built command against the pinned oMLX, on Metal, with a 5 MB
# random-weight Qwen3 from TRL's test models.
{
  lib,
  stdenvNoCC,
  fetchurl,
  linkFarm,
  python3,
  omlx,
  jq,
  curl,
  coreutils,
}:

let
  # TRL's tiny random Qwen3: the real architecture, tokenizer and
  # chat template (with tool calls), 2 layers of width 8.
  tinyQwen3 =
    let
      repo = "trl-internal-testing/tiny-Qwen3ForCausalLM";
      rev = "92ee0a3c801d3ffbec16626c3b9f5fe60e778253";
      file = name: hash: {
        inherit name;
        path = fetchurl {
          url = "https://huggingface.co/${repo}/resolve/${rev}/${name}";
          inherit hash;
        };
      };
    in
    linkFarm "tiny-Qwen3ForCausalLM" [
      (file "config.json" "sha256-W2zBazY2ngJDpWMHW/Z75KJso+Q63sowD0m7eeM3L/o=")
      (file "model.safetensors" "sha256-n5M/8zRK2HeOsBxHZlO57K0mTTtgKhvy7XqZhJOm1aI=")
      (file "tokenizer.json" "sha256-rrEzB6cazY/oGGHZStVKtonfdzMYgJ7tPL55S0SS2uQ=")
      (file "tokenizer_config.json" "sha256-RDv6Yp6xY4ehLtv5Knb2pvELKvO1PYe6FVCt/PRff6A=")
      (file "chat_template.jinja" "sha256-stPE2BzBOO87DBuPnDrFTxXxyjitou70w6hpC67OAHQ=")
      (file "generation_config.json" "sha256-zNhXSu+3gX8F4TRzDL0NdaltFEGqGrtpl1iBbUrjMUQ=")
      (file "special_tokens_map.json" "sha256-doYudlJmuFqpRZdn4zy68Tlw8yeg6I0cZYRsLd06Hs0=")
      (file "added_tokens.json" "sha256-wChLWC4UmH+9PVossr0TkIQ3HtmsuuSIgpockAgzxoA=")
    ];

  # oMLX's own MLX, to ask Metal how much memory a model may use.
  mlxPython = omlx.passthru.python.withPackages (ps: [ ps.mlx ]);

  inherit (omlx.meta) platforms;
in
stdenvNoCC.mkDerivation {
  pname = "agent-gateway-omlx";
  # The gateway's own version is the server's: it carries nothing else
  # that changes.
  inherit (omlx) version;

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/libexec/agent-gateway-omlx
    substitute ${./gateway.py} $out/libexec/agent-gateway-omlx/gateway.py \
      --replace-fail '@omlx@' '${lib.getExe omlx}' \
      --replace-fail '@mlxPython@' '${lib.getExe mlxPython}' \
      --replace-fail '@version@' '${omlx.version}' \
      --replace-fail '@platforms@' '${builtins.toJSON platforms}'
    # The contract, shared with the other agent-gateway-* packages.
    cp ${../../lib/agent-gateway/agent_gateway.py} $out/libexec/agent-gateway-omlx/agent_gateway.py
    cat >$out/bin/agent-gateway-omlx <<EOF
    #!${stdenvNoCC.shell}
    exec ${lib.getExe python3} -I $out/libexec/agent-gateway-omlx/gateway.py "\$@"
    EOF
    chmod +x $out/bin/agent-gateway-omlx
    runHook postInstall
  '';

  # The contract, on the installed command, against the pinned server.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ jq curl coreutils python3 ];
  installCheckPhase = ''
    runHook preInstallCheck
    bash ${./contract-test.sh} $out/bin/agent-gateway-omlx ${tinyQwen3}
    runHook postInstallCheck
  '';
  # The contract test talks to oMLX on loopback.
  __darwinAllowLocalNetworking = true;

  passthru = { inherit omlx tinyQwen3; };

  meta = {
    description = "Model gateway that serves MLX models with oMLX";
    license = lib.licenses.mit;
    mainProgram = "agent-gateway-omlx";
    inherit platforms;
    # Supports an agent rather than being one. ADR 0014.
    category = "agent-tool";
  };
}
