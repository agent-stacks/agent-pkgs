# mkAgentStack — compose plugins and one harness into a runnable stack.
#
#   $out/share/agent-plugins/<plugin>/   the neutral spec layout
#   $out/bin/<name>                      launcher
#
# A stack runs exactly one agent. Several agents means several stacks
# installed into one environment. All harness adaptation happens at
# launch time in `agent-stacks launch`, so nothing here is per-harness.
{ lib
, stdenvNoCC
, runtimeShell
  # The agent-stacks package the launcher runs.
  # agent-pkgs binds pkgs/agent-stacks here; null falls back to PATH
  # resolution, which is what a consumer without the package gets.
, defaultAgentStacks ? null
}:

{ name
  # "claude" (resolved from PATH), a path, or a package
, harness ? null
, plugins ? [ ]
  # Override the agent-stacks CLI this stack runs.
, agentStacks ? defaultAgentStacks
  # Removed: a stack no longer has an audit output. Accepted here only
  # so that passing it fails with the reason below rather than Nix's
  # "called with unexpected argument".
, audit ? null
}@args:

let
  # Mirrors the adapter registry in agent-stacks internal/launch.
  knownAdapters = [ "agent-deck" "claude" "codex" "opencode" "pi" ];

  # Resolve the harness to an adapter name plus, when the harness was
  # pinned, the bin directory to prepend to PATH. meta.mainProgram is
  # the only package-side source: listing the package's bin/ would
  # force it to build during evaluation.
  harnessInfo =
    if harness == null then
      throw ''
        mkAgentStack: stack '${name}' has no harness.
        A stack runs exactly one agent:
          harness = "claude";      # resolved from the consumer's PATH
          harness = claude-code;   # pinned, with its own runtime
      ''
    else if lib.isDerivation harness then
      {
        adapter = harness.meta.mainProgram or (throw ''
          mkAgentStack: harness package has no meta.mainProgram, so the
          agent it provides cannot be named. Pass the binary instead:
            harness = "''${pkgs.claude-code}/bin/claude";
        '');
        pinDir = "${harness}/bin";
      }
    else if builtins.isString harness && lib.hasInfix "/" harness then
      { adapter = baseNameOf harness; pinDir = dirOf harness; }
    else if builtins.isString harness then
      { adapter = harness; pinDir = null; }
    else
      throw ''
        mkAgentStack: harness must be the agent's name, a path to its
        binary written as a string, or a package. A Nix path literal such
        as ./result/bin/claude is not accepted: it would copy that one
        file into the store without the rest of its package.
      '';

  adapter =
    if lib.elem harnessInfo.adapter knownAdapters then harnessInfo.adapter
    else throw ''
      mkAgentStack: '${harnessInfo.adapter}' is not an agent agent-stacks
      can launch. Known agents: ${lib.concatStringsSep ", " knownAdapters}
    '';

  # The launcher runs the agent-stacks CLI it was built against, so a
  # stack carries its own agent in its closure rather than hoping the
  # consumer has one on PATH. Precedence at runtime, highest first:
  # AGENT_STACKS_BIN, then the deprecated FLOX_AGENT_BIN (kept so an
  # existing stack override does not break), then this baked-in default.
  # With no package bound, the default name resolves from PATH as before.
  agentStacksDefault =
    if agentStacks == null then "agent-stacks"
    else lib.getExe' agentStacks "agent-stacks";
  agentStacksBin =
    ''"''${AGENT_STACKS_BIN:-''${FLOX_AGENT_BIN:-${agentStacksDefault}}}"'';

  # builtins.placeholder gives this output's final store path, so the
  # script can name its own share directory without any substitution.
  launcherText = ''
    #!${runtimeShell}
    set -eu
  ''
  + lib.optionalString (harnessInfo.pinDir != null) ''
    export PATH="${harnessInfo.pinDir}:$PATH"
  ''
  + ''
    exec ${agentStacksBin} \
      --dir "${builtins.placeholder "out"}/share" \
      launch ${adapter} -- "$@"
  '';

  pluginOf = p:
    p.passthru.agentPlugin or (throw ''
      mkAgentStack: '${p.pname or p.name or "<unnamed>"}' is not an agent
      plugin. Every entry in `plugins` must come from buildAgentPlugin.
    '');

  pluginNames = map (p: (pluginOf p).name) plugins;

  duplicates = lib.unique
    (lib.filter (n: lib.count (m: m == n) pluginNames > 1) pluginNames);

  checkedPlugins =
    if duplicates == [ ] then plugins
    else throw ''
      mkAgentStack: duplicate plugin names: ${
        lib.concatStringsSep ", " duplicates
      }.
      Each plugin in a stack must have a unique name.
    '';

  copyPlugin = p:
    let ap = pluginOf p; in
    ''
      cp -R "${p}/${ap.path}" "$out/share/agent-plugins/${ap.name}"
    '';

  # A stack had an `audit` output and option until ADR 0021. A call
  # still passing the option is refused by name, so its author learns
  # why and what to run instead.
  removedAudit = ''
    mkAgentStack: stack '${name}' passes `audit`, which was removed
    (ADR 0021). A stack no longer builds an audit script. Audit the
    built stack with agent-stacks instead:
      agent-stacks audit ./result
    with an agent-stacks carrying agent-stacks-cli #187, or plugin by
    plugin with one carrying #186:
      agent-stacks audit ./result/share/agent-plugins/<name>
    Drop `audit` from the call.
  '';
in
if args ? audit then throw removedAudit else
stdenvNoCC.mkDerivation {
  pname = "agent-stack-${name}";
  version = "0";

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  # Written to a file by the builder, so no shell quoting of the
  # script body is involved.
  inherit launcherText;
  passAsFile = [ "launcherText" ];

  # A stack composes plugins; it never rewrites their content.
  # buildAgentPlugin already resolved every interpreter to an absolute
  # store path and fails the build if any executable still carries a
  # /usr/bin/env shebang, so patching here would be a no-op at best and
  # a corruption of pinned paths at worst. Plugin files are also copied
  # read-only out of the store, which patchShebangs could not write to.
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/agent-plugins" "$out/bin"
    ${lib.concatMapStringsSep "\n" copyPlugin checkedPlugins}
    install -Dm755 "$launcherTextPath" "$out/bin/${name}"

    runHook postInstall
  '';

  passthru.agentStack = {
    inherit name adapter harness agentStacks;
    plugins = pluginNames;
  };

  meta = {
    description = "Agent stack ${name} (${adapter})";
    mainProgram = name;
    # A stack is the composed environment, not a plugin and not an
    # agent — ADR 0014 names the four values.
    category = "agent-stack";
    platforms = lib.platforms.all;
  };
}
