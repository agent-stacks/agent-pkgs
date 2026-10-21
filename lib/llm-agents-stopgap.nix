# Stopgap overrides for packages re-exported from llm-agents.nix that
# fail to build against this flake's nixpkgs.
#
# llm-agents.nix tests its packages against an older NixOS/nixpkgs than
# the flox/nixpkgs this flake follows, so its own CI is green while the
# same expressions fail here. Each override below repairs one such
# failure and names the upstream change that makes it redundant. Delete
# an override when llm-agents.nix lands that change and flake.lock moves
# past it; keep the file only while it still holds one.
#
# The overrides are deliberately minimal (override* on the upstream
# derivation) rather than copies of the package files, so an upstream
# update still flows through.
final: prev:
let
  # The scope llm-agents.nix builds has no overrideScope, so the
  # repaired packages replace their attributes in a plain update.
  # No other package in that scope has these in its default closure
  # (kandev takes copilot-cli only with copilotSupport), so none keeps
  # an unrepaired build; re-check when adding an override.
  super = prev.llm-agents;
in
{
  llm-agents = super // {
    # websockets 17 is in this nixpkgs; apm 0.34.0 pins websockets<17 and
    # pythonRuntimeDepsCheck rejects it. apm's only use is
    # websockets.sync.client.connect, which exists in 17.
    # Remove when apm widens the pin (microsoft/apm, websockets<18) and
    # llm-agents.nix packages that release.
    apm = super.apm.overridePythonAttrs (old: {
      pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "websockets" ];
    });

    # patchelf 0.19 corrupts the copilot Node single-executable binary
    # when one call sets the interpreter and the rpath, or sets the
    # interpreter first: `copilot --version` segfaults, so
    # versionCheckHook fails. Setting the rpath in its own earlier call
    # leaves a binary that runs, and the package's own combined call
    # then succeeds on it. --no-sort does not help; patchelf rejects
    # this binary with "non-contiguous SHT_NOTE sections". Linux only;
    # the package does not call patchelf on darwin. The rpath repeats
    # the one in packages/copilot-cli/package.nix.
    # Remove when llm-agents.nix sets the rpath before the interpreter
    # there, or patchelf stops corrupting the binary.
    copilot-cli = super.copilot-cli.overrideAttrs (old: {
      preInstall =
        (old.preInstall or "")
        + final.lib.optionalString final.stdenv.hostPlatform.isLinux ''
          patchelf --set-rpath "${final.lib.makeLibraryPath [ final.stdenv.cc.cc.lib ]}" copilot
        '';
    });

    # Python builds here use __structuredAttrs, which passes
    # makeWrapperArgs as a real list. The upstream single string
    # "--suffix PATH : ..." reaches makeWrapper as one argument it does
    # not understand.
    # Remove when llm-agents.nix splits the arguments in
    # packages/orbi-cli/package.nix.
    orbi-cli = super.orbi-cli.overridePythonAttrs (_old: {
      makeWrapperArgs = [
        "--suffix"
        "PATH"
        ":"
        (final.lib.makeBinPath [
          final.gh
          final.git
          super.pi
        ])
      ];
    });

    # remote-control-device-key.node links libtss2-*, which
    # auto-formatelf cannot find on Linux. chatgpt takes its unwrapped
    # build as an argument, so the override goes through it.
    # Remove when numtide/llm-agents.nix#11102 (adds tpm2-tss and
    # openssl to buildInputs) is merged and flake.lock moves past it.
    chatgpt = super.chatgpt.override {
      chatgpt-unwrapped = super.chatgpt.unwrapped.overrideAttrs (old: {
        buildInputs =
          (old.buildInputs or [ ])
          ++ final.lib.optionals final.stdenv.hostPlatform.isLinux [
            final.tpm2-tss
            final.openssl
          ];
      });
    };

    # herdr's vendored libghostty-vt requires Zig 0.16 exactly; the
    # default zig in this nixpkgs is 0.17, which its build rejects.
    # Remove when llm-agents.nix builds herdr with zig_0_16 (or herdr
    # supports 0.17) and flake.lock moves past it.
    herdr = super.herdr.override { zig = final.zig_0_16; };
  };
}
