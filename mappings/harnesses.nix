# Re-exported agents whose own program runs through `agent-stacks
# launch`, keyed by package name, valued by the launch adapter that
# drives it. Typing the program in an environment then hands it the
# environment's plugins (AI-570, ADR 0019).
#
# Only agents launch hands plugins to without touching the user's
# arguments. pi is left out: launch puts its --skill flags in front of
# them, so a subcommand would not stay one. codex is left out until the
# catalog serves the flox-patched build (AI-1012); the unpatched one
# would warn on every run.
{
  claude-code = "claude";
  opencode = "opencode";
}
