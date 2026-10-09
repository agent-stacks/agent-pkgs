# wrapHarness — a harness package whose own program runs through
# `agent-stacks launch`, so a plain `claude` in an environment gets the
# environment's plugins with nothing to set up (AI-570, ADR 0019).
#
#   $out/bin/<program>                          the wrapper
#   $out/bin/<other>                            links to the harness's other programs
#   $out/libexec/agent-stacks/<adapter>/bin/<program>   the real program
#   $out/<everything else>                      links into the harness
#
# The wrapper puts the real program first on PATH before it calls
# launch, so launch's own lookup finds the real one and not the wrapper.
# Launch sets AGENT_STACKS=1 for the agent it starts, so a wrapper that
# sees it, because a stack's launcher or launch itself started it, runs
# the real program directly instead of launching twice.
{ lib
, runCommand
, runtimeShell
}:

{ harness
  # The launch adapter that drives it: claude, opencode, …
, adapter
  # The agent-stacks package whose launch the wrapper runs.
, agentStacks
}:

let
  program = harness.meta.mainProgram or adapter;
  realDir = "libexec/agent-stacks/${adapter}/bin";
in
runCommand harness.name
{
  inherit runtimeShell;
  passthru = (harness.passthru or { }) // { unwrapped = harness; };
  meta = harness.meta // { mainProgram = program; };
} ''
  mkdir -p $out/bin $out/${realDir}

  # Everything the harness ships, linked, except bin/ which is rebuilt.
  for entry in ${harness}/*; do
    name=$(basename "$entry")
    [ "$name" = bin ] || ln -s "$entry" "$out/$name"
  done
  for entry in ${harness}/bin/*; do
    name=$(basename "$entry")
    [ "$name" = ${lib.escapeShellArg program} ] || ln -s "$entry" "$out/bin/$name"
  done

  ln -s ${harness}/bin/${program} $out/${realDir}/${program}

  cat > $out/bin/${program} <<EOF
  #!${runtimeShell}
  real_dir=$out/${realDir}
  if [ -n "\''${AGENT_STACKS_OFF:-}" ] || [ "\''${AGENT_STACKS:-}" = 1 ]; then
    exec "\$real_dir/${program}" "\$@"
  fi
  export AGENT_STACKS_WRAPPED=1
  PATH="\$real_dir:\$PATH" exec ${lib.getExe' agentStacks "agent-stacks"} launch ${adapter} -- "\$@"
  EOF
  chmod +x $out/bin/${program}
''
