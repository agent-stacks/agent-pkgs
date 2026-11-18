# Patches packages of the llm-agents set. Compose it after
# llm-agents.nix's shared-nixpkgs overlay. ADR 0024.
final: prev:
let
  # Temporary, until the lock has numtide/llm-agents.nix#12320 or #12217,
  # either of which makes the same change upstream; drop it, and the
  # overrides that pass it on, then. Our nixpkgs builds aws-lc without the compat openssl.pc that codex
  # gave openssl-sys (Linux only), so it needs the real openssl. Once
  # upstream adds openssl itself, this would list it a second time.
  codexWithOpenssl = prev.llm-agents.codex.overrideAttrs (old: {
    buildInputs =
      (old.buildInputs or [ ]) ++ final.lib.optionals final.stdenv.hostPlatform.isLinux [ final.openssl ];
  });

  # The llm-agents set is a plain attribute set, not a scope, so packages
  # that take codex as an input keep llm-agents' own codex unless it is
  # passed to them.
  withCodex = name: prev.llm-agents.${name}.override { codex = codexWithOpenssl; };
in
{
  llm-agents = prev.llm-agents // {
    # Adds the env vars agent-stacks passes skills through (agent-stacks
    # ADR 0011). Only the codex package itself carries it; the packages
    # that run codex get codexWithOpenssl.
    #
    # builtins.path gives the patch its own store path. A plain path sits
    # inside this flake's source, so every commit would rebuild codex.
    codex = codexWithOpenssl.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        (builtins.path {
          path = ./codex-flox-fragments.patch;
          name = "codex-flox-fragments.patch";
        })
      ];
    });

    codex-acp = withCodex "codex-acp";
    oh-my-codex = withCodex "oh-my-codex";
    t3code = withCodex "t3code";
    # Wraps t3code, so it has to be handed the one above.
    t3code-desktop = prev.llm-agents.t3code-desktop.override { t3code = final.llm-agents.t3code; };

    # Temporary, until the lock has numtide/llm-agents.nix#12217, which makes
    # the same change upstream; drop it then. nixpkgs' cargo setup hook now
    # exports LIBGIT2_NO_VENDOR=1, so libgit2-sys panics when it finds no
    # system libgit2. autolith builds its fff-c library inside the package,
    # with the rustPlatform from the pkgs it is given; hand it one whose
    # buildRustPackage adds libgit2. fff-c is its only Rust build.
    autolith = prev.llm-agents.autolith.override (old: {
      pkgs = old.pkgs // {
        rustPlatform = old.pkgs.rustPlatform // {
          buildRustPackage =
            args:
            old.pkgs.rustPlatform.buildRustPackage (
              args // { buildInputs = (args.buildInputs or [ ]) ++ [ final.libgit2 ]; }
            );
        };
      };
    });
  };
}
