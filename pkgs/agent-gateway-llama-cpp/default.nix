# agent-gateway-llama-cpp — llama.cpp's llama-server behind the
# agent-gateway contract (agent-stacks spec proposal 0002, section 7):
#
#   agent-gateway-llama-cpp describe
#   agent-gateway-llama-cpp check <model dir | model.json>...
#   agent-gateway-llama-cpp serve [--listen <host:port>] [<models dir>...] [-- <server args>]
#   agent-gateway-llama-cpp status --url <url>
#
# One package per inference server behind one contract, as the
# agent-sandbox-* packages are for sandboxes. `serve` links every GGUF
# in the models directories (by default AGENT_STACKS_MODELS_DIR, else
# $FLOX_ENV/share/agent-models) into a per-run state folder, writes a
# llama-server preset naming each by its model.json id, and runs
# llama-server in router mode over it: every model at one endpoint,
# loaded when a request names it. Borrowed models in the Hugging Face
# cache are served as llama-server serves them. SIGHUP re-reads the
# models directories and reloads the router's list.
#
# The llama-server is nixpkgs' llama-cpp, as this flake pins it: Metal
# on macOS. The build runs the contract on the built command against
# that server, with a 1 MB GGUF, on the CPU.
{
  lib,
  stdenvNoCC,
  fetchurl,
  python3,
  llama-cpp,
  jq,
  curl,
  coreutils,
}:

let
  # A real model small enough for the build: llama.cpp's own CI model.
  stories260K = fetchurl {
    url = "https://huggingface.co/ggml-org/models/resolve/499bc8821c6b12b4e53c5bffcb21ec206f212d81/tinyllamas/stories260K.gguf";
    hash = "sha256-Jwy6G9UQn0LQM1D2BAYCRWBGTbFzwOOH2R8EJtO9JW0=";
  };
  # Where this set publishes it; llama-cpp itself builds for more.
  platforms = [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ];
in
stdenvNoCC.mkDerivation {
  pname = "agent-gateway-llama-cpp";
  # The gateway's own version is the server's: it carries nothing else
  # that changes.
  inherit (llama-cpp) version;

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/libexec/agent-gateway-llama-cpp
    substitute ${./gateway.py} $out/libexec/agent-gateway-llama-cpp/gateway.py \
      --replace-fail '@llamaServer@' '${lib.getExe' llama-cpp "llama-server"}' \
      --replace-fail '@version@' '${llama-cpp.version}' \
      --replace-fail '@platforms@' '${builtins.toJSON platforms}'
    # The contract, shared with the other agent-gateway-* packages.
    cp ${../../lib/agent-gateway/agent_gateway.py} $out/libexec/agent-gateway-llama-cpp/agent_gateway.py
    cat >$out/bin/agent-gateway-llama-cpp <<EOF
    #!${stdenvNoCC.shell}
    exec ${lib.getExe python3} -I $out/libexec/agent-gateway-llama-cpp/gateway.py "\$@"
    EOF
    chmod +x $out/bin/agent-gateway-llama-cpp
    runHook postInstall
  '';

  # The contract, on the installed command, against the pinned server.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ jq curl coreutils python3 ];
  installCheckPhase = ''
    runHook preInstallCheck
    bash ${./contract-test.sh} $out/bin/agent-gateway-llama-cpp ${stories260K}
    runHook postInstallCheck
  '';
  # The contract test talks to llama-server on loopback.
  __darwinAllowLocalNetworking = true;

  passthru = { inherit llama-cpp; };

  meta = {
    description = "Model gateway that serves GGUF models with llama.cpp's llama-server";
    license = lib.licenses.mit;
    mainProgram = "agent-gateway-llama-cpp";
    inherit platforms;
    # Supports an agent rather than being one. ADR 0014.
    category = "agent-tool";
  };
}
