# Patches packages of the llm-agents set. Compose it after
# llm-agents.nix's shared-nixpkgs overlay. ADR 0024.
final: prev: {
  llm-agents = prev.llm-agents // {
    # Adds the env vars agent-stacks passes skills through (agent-stacks
    # ADR 0011).
    #
    # builtins.path gives the patch its own store path. A plain path sits
    # inside this flake's source, so every commit would rebuild codex.
    #
    # openssl: llm-agents builds openssl-sys against aws-lc's compat
    # openssl.pc. This nixpkgs' aws-lc installs its headers under
    # include/aws-lc and ships no openssl.pc, so on Linux openssl-sys
    # finds no OpenSSL. Give it openssl itself, as nixpkgs does for
    # packages that link both (mise, zed-editor): aws-lc's symbols are
    # prefixed, so the two libcrypto copies no longer clash. Darwin
    # builds without it.
    codex = prev.llm-agents.codex.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        (builtins.path {
          path = ./codex-flox-fragments.patch;
          name = "codex-flox-fragments.patch";
        })
      ];
      buildInputs =
        (old.buildInputs or [ ])
        ++ final.lib.optionals final.stdenv.hostPlatform.isLinux [ final.openssl ];
    });

    # llm-agents points aws-lc-sys at a prefix joined from aws-lc's dev
    # and lib outputs, and aws-lc-sys reads include/openssl/base.h from
    # it. This nixpkgs' aws-lc keeps that header at
    # include/aws-lc/openssl/base.h, so the build panics. Drop the prefix
    # and let aws-lc-sys find aws-lc through pkg-config (aws-lc.pc), as
    # nono does. The prefix only existed to keep aws-lc's compat
    # openssl.pc away from openssl-sys, and this aws-lc has none.
    lean-ctx = prev.llm-agents.lean-ctx.overrideAttrs (old: {
      env = removeAttrs old.env [ "AWS_LC_SYS_SYSTEM_DIR" ];
      buildInputs = (old.buildInputs or [ ]) ++ [ final.aws-lc ];
    });

    # nixpkgs' cargo setup hook now exports AWS_LC_SYS_USE_SYSTEM=1, so
    # aws-lc-sys links the system AWS-LC instead of building its own, and
    # panics when it finds none. nono vendors aws-lc-sys and declares
    # none; give it nixpkgs' aws-lc, and pkg-config to find it (nono has
    # pkg-config only on Linux), as nixpkgs does for its own packages.
    # Harmless before that change: the hook did not set the variable, so
    # aws-lc-sys built from source.
    nono = prev.llm-agents.nono.overrideAttrs (old: {
      buildInputs = (old.buildInputs or [ ]) ++ [ final.aws-lc ];
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.pkg-config ];
    });
  };
}
