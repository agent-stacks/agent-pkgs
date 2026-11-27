# Qwen2.5 0.5B Instruct, Q4_K_M GGUF: the first carried model, small
# enough (470 MiB) to prove buildAgentModel end to end and to serve
# with agent-gateway-llama-cpp. Written by hand until `agent-stacks
# import hf:<org>/<repo>` writes model packages; the call has the
# shape that import will record.
#
# sha256 is the Hugging Face LFS etag for the GGUF, and the file's own
# digest for LICENSE, which is in Git.
#
# `agentStacks` overrides the binary that writes model.json and checks
# it, for `.override { agentStacks = <package with bin/agent-stacks>; }`
# until pkgs/agent-stacks pins a binary carrying `assemble-model`.
{ buildAgentModel ? callPackage ../../lib/build-agent-model.nix { }
, callPackage
, agentStacks ? null
}:

buildAgentModel {
  name = "qwen2.5-0.5b-instruct-q4_k_m";
  source = {
    hub = "huggingface";
    repo = "Qwen/Qwen2.5-0.5B-Instruct-GGUF";
    revision = "9217f5db79a29953eb74d5343926648285ec7e67";
  };
  descriptor = {
    family = "qwen2";
    licenses = [ "Apache-2.0" ];
  };
  files = [
    {
      path = "qwen2.5-0.5b-instruct-q4_k_m.gguf";
      sha256 = "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db";
    }
    {
      path = "LICENSE";
      sha256 = "832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e";
    }
  ];
  inherit agentStacks;
}
