# agent-sandbox-srt — runs the agent inside Anthropic's sandbox-runtime
# (srt): Seatbelt on macOS, bubblewrap and seccomp on Linux, with a
# proxy that allows only the hosts listed.
#
#   agent-sandbox-srt [--options '<json>'] -- <command> [args]
#
# The contract agent-stacks launch hands an agent to (agent-stacks-cli
# ADR 0056). srt reads one settings file and merges nothing, so this
# writes the whole file on each launch:
#
#   - Claude's own hosts, and every host an MCP server of the staged
#     plugins names (read from CLAUDE_CODE_PLUGIN_DIRS, which launch
#     sets for the agent);
#   - ~/.ssh denied; the project, /tmp and Claude's state writable;
#   - on macOS, allowPty and /private/tmp (see below);
#   - the caller's options, each a list added to the above.
#
# Found by James Bayer's tests (agent-stacks-sandbox-lab) and recorded in
# spec proposal 0001, appendix A. AGENT_SANDBOX_SRT_DRY_RUN=1 prints the
# settings and the command instead of running them.
{
  lib,
  writeShellApplication,
  jq,
  coreutils,
  sandbox-runtime,
}:

(writeShellApplication {
  name = "agent-sandbox-srt";
  runtimeInputs = [ jq coreutils ];
  text = ''
    die() {
      echo "agent-sandbox-srt: $*" >&2
      exit 2
    }
    srt=${lib.getExe' sandbox-runtime "srt"}
    keys='["allowedDomains", "allowWrite", "denyRead"]'

    opts="{}"
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
          die "unexpected '$1'; usage: agent-sandbox-srt [--options '<json>'] -- <command> [args]"
          ;;
      esac
    done
    [ $# -gt 0 ] || die "no command after --"

    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$opts" ||
      die "options must be a JSON object, got: $opts"
    unknown=$(jq -r --argjson k "$keys" 'keys - $k | join(", ")' <<<"$opts")
    [ -z "$unknown" ] || die "unknown option: $unknown (srt takes $(jq -r 'join(", ")' <<<"$keys"))"
    bad=$(jq -r 'to_entries[] | select((.value | type) != "array" or any(.value[]; type != "string")) | .key' <<<"$opts")
    [ -z "$bad" ] || die "option $bad must be a list of strings"

    # Every host the staged plugins' MCP servers reach.
    mcp_hosts="[]"
    IFS=: read -r -a dirs <<<"''${CLAUDE_CODE_PLUGIN_DIRS:-}"
    for d in "''${dirs[@]}"; do
      [ -f "$d/.mcp.json" ] || continue
      mcp_hosts=$(jq -c --argjson acc "$mcp_hosts" '
        $acc + [ (.mcpServers // {})[] | .url? // empty
                 | sub("^[a-zA-Z][a-zA-Z0-9+.-]*://"; "") | split("/")[0]
                 | split("@")[-1] | split(":")[0] | select(length > 0) ]' "$d/.mcp.json") ||
        die "cannot read MCP servers in $d/.mcp.json"
    done

    # macOS: Claude's terminal cannot go raw without allowPty, and srt
    # does not follow the /tmp -> /private/tmp link, so "/tmp" alone
    # leaves Claude's Bash tool unable to make its working folder.
    darwin=false
    [ "$(uname -s)" = Darwin ] && darwin=true

    settings=$(mktemp "''${TMPDIR:-/tmp}/agent-sandbox-srt.XXXXXX")
    jq -n --argjson o "$opts" --argjson mcp "$mcp_hosts" --argjson darwin "$darwin" '{
      network: {
        allowedDomains: (["api.anthropic.com", "platform.claude.com"] + $mcp + ($o.allowedDomains // []) | unique),
        deniedDomains: []
      },
      filesystem: {
        denyRead: (["~/.ssh"] + ($o.denyRead // []) | unique),
        allowWrite: ([".", "/tmp", "~/.claude", "~/.claude.json", "~/.claude.json.lock"]
                     + (if $darwin then ["/private/tmp"] else [] end) + ($o.allowWrite // []) | unique),
        denyWrite: []
      }
    } + (if $darwin then {allowPty: true} else {} end)' >"$settings"

    if [ -n "''${AGENT_SANDBOX_SRT_DRY_RUN:-}" ]; then
      cat "$settings"
      echo "would run: $srt --settings $settings -- $*" >&2
      exit 0
    fi

    # Ubuntu 24.04 and later restrict unprivileged user namespaces, and
    # srt's bubblewrap cannot start under that without an admin step.
    if [ "$(uname -s)" = Linux ] &&
      [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ] &&
      ! "$srt" --settings "$settings" -- true >/dev/null 2>&1; then
      die "srt cannot start a sandbox here: this kernel restricts unprivileged user namespaces.
Fix it once, as root, with either:
  - an AppArmor profile granting userns to srt's bwrap ($srt), or
  - sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 (relaxes it for the whole host)"
    fi

    echo "agent-sandbox-srt: running ''${1##*/} inside srt" >&2
    exec "$srt" --settings "$settings" -- "$@"
  '';
}).overrideAttrs (old: {
  meta = (old.meta or { }) // {
    description = "Sandbox that runs the agent inside Anthropic's sandbox-runtime (srt)";
    license = lib.licenses.mit;
    mainProgram = "agent-sandbox-srt";
    platforms = sandbox-runtime.meta.platforms or lib.platforms.unix;
    # Supports an agent rather than being one. ADR 0014.
    category = "agent-tool";
  };
})
