# agent-sandbox-noop — the sandbox that does nothing.
#
# The first sandbox package, and the test of the contract agent-stacks
# launch hands an agent to (agent-stacks-cli ADR 0051):
#
#   agent-sandbox-<name> [--options '<json>'] -- <command> [args]
#
# It validates its options, says it is not sandboxing, and execs the
# command unchanged. Its one option, `msg`, replaces that message; any
# other key is an error, so the error path is exercised too. srt and
# nono follow this shape (AI-1015, AI-1014).
{
  lib,
  writeShellApplication,
  jq,
}:

(writeShellApplication {
  name = "agent-sandbox-noop";
  runtimeInputs = [ jq ];
  text = ''
    die() {
      echo "agent-sandbox-noop: $*" >&2
      exit 2
    }

    opts=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --options)
          [ $# -ge 2 ] || die "--options needs a value"
          opts=$2
          shift 2
          ;;
        --options=*)
          opts=''${1#--options=}
          shift
          ;;
        --)
          shift
          break
          ;;
        *)
          die "unexpected '$1'; usage: agent-sandbox-noop [--options '<json>'] -- <command> [args]"
          ;;
      esac
    done
    [ $# -gt 0 ] || die "no command after --"

    msg="agent-sandbox-noop: no sandbox; running ''${1##*/} unsandboxed"
    if [ -n "$opts" ]; then
      jq -e 'type == "object"' >/dev/null 2>&1 <<<"$opts" ||
        die "options must be a JSON object, got: $opts"
      unknown=$(jq -r 'keys - ["msg"] | join(", ")' <<<"$opts")
      [ -z "$unknown" ] || die "unknown option: $unknown (the no-op takes only \"msg\")"
      if jq -e 'has("msg")' >/dev/null <<<"$opts"; then
        jq -e '.msg | type == "string"' >/dev/null <<<"$opts" || die "\"msg\" must be a string"
        msg=$(jq -r '.msg' <<<"$opts")
      fi
    fi

    echo "$msg" >&2
    exec "$@"
  '';
}).overrideAttrs (old: {
  meta = (old.meta or { }) // {
    description = "Sandbox that does nothing: prints that it is not sandboxing, then runs the agent";
    license = lib.licenses.mit;
    mainProgram = "agent-sandbox-noop";
    platforms = lib.platforms.all;
    # Supports an agent rather than being one. ADR 0014.
    category = "agent-tool";
  };
})
