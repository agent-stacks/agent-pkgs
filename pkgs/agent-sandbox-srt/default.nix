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
#   - on macOS, allowPty and /private/tmp (srt does not follow /tmp);
#   - the agent's temp folder made, which srt names but does not create;
#   - on macOS, SSL_CERT_FILE set unless the caller has, so gh can check
#     a certificate without the trust service the sandbox blocks;
#   - and it refuses to start at / or ~, where "." would open everything;
#   - the caller's options: lists added to the above, and switches that
#     are off unless true. A switch weakens the sandbox, so each one
#     that is on is named on stderr at every launch.
#
# Found by James Bayer's tests (agent-stacks-sandbox-lab) and recorded in
# spec proposal 0001, appendix A. AGENT_SANDBOX_SRT_DRY_RUN=1 prints the
# settings and the command instead of running them.
{
  lib,
  writeShellApplication,
  jq,
  coreutils,
  stdenv,
  bubblewrap,
  cacert,
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
    # Linux: the bwrap srt runs, named so the AppArmor fix below can name
    # it too. The same one nixpkgs' srt puts first on its PATH.
    bwrap=${lib.optionalString stdenv.hostPlatform.isLinux (lib.getExe' bubblewrap "bwrap")}
    # The options: lists of strings, and switches that are true or false.
    lists='["allowedDomains", "allowUnixSockets", "allowWrite", "denyRead"]'
    switches='["allowLocalBinding", "enableWeakerNetworkIsolation"]'

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

    # The project folder (".") is writable, so starting at / or ~ would
    # make the whole disk or home folder writable.
    here=$(pwd -P)
    if [ "$here" = / ] || [ "$here" = "$(cd "$HOME" 2>/dev/null && pwd -P)" ]; then
      die "refusing to start in $here: the project folder is writable inside the sandbox, so start from a project folder instead"
    fi

    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$opts" ||
      die "options must be a JSON object, got: $opts"
    known=$(jq -cn --argjson l "$lists" --argjson s "$switches" '$l + $s')
    unknown=$(jq -r --argjson k "$known" 'keys - $k | join(", ")' <<<"$opts")
    [ -z "$unknown" ] || die "unknown option: $unknown (srt takes $(jq -r 'join(", ")' <<<"$known"))"
    bad=$(jq -r --argjson l "$lists" '[to_entries[] | select(.key | IN($l[]))
      | select((.value | type) != "array" or any(.value[]; type != "string")) | .key] | join(", ")' <<<"$opts")
    [ -z "$bad" ] || die "option $bad must be a list of strings"
    bad=$(jq -r --argjson s "$switches" '[to_entries[] | select(.key | IN($s[]))
      | select((.value | type) != "boolean") | .key] | join(", ")' <<<"$opts")
    [ -z "$bad" ] || die "option $bad must be true or false"

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

    # srt points the agent's TMPDIR here and allows writing it, but on
    # macOS does not create it, so mktemp inside the sandbox fails.
    mkdir -p "''${CLAUDE_CODE_TMPDIR:-''${CLAUDE_TMPDIR:-/tmp/claude}}"

    # macOS: a program that has the system check a certificate fails in
    # the sandbox, which blocks the trust service that does the check. A
    # Go program (gh) checks it itself when SSL_CERT_FILE or SSL_CERT_DIR
    # is set, from Go 1.27 on, so set one unless the caller has. Nix's
    # file first: a machine's added authorities are usually in it. Not
    # with the switch on: the trust service answers then, and it also
    # knows the authorities only the keychain holds.
    cert_file=
    if [ "$darwin" = true ] && [ -z "''${SSL_CERT_FILE:-}" ] && [ -z "''${SSL_CERT_DIR:-}" ] &&
      jq -e '.enableWeakerNetworkIsolation != true' >/dev/null <<<"$opts"; then
      cert_file=''${NIX_SSL_CERT_FILE:-}
      [ -r "$cert_file" ] || cert_file=${cacert}/etc/ssl/certs/ca-bundle.crt
    fi

    settings=$(mktemp "''${TMPDIR:-/tmp}/agent-sandbox-srt.XXXXXX")
    jq -n --argjson o "$opts" --argjson mcp "$mcp_hosts" --argjson darwin "$darwin" --arg bwrap "$bwrap" '{
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
    } + (if $darwin then {allowPty: true} else {} end)
      + (if $o.enableWeakerNetworkIsolation == true then {enableWeakerNetworkIsolation: true} else {} end)
      + (if $bwrap != "" then {bwrapPath: $bwrap} else {} end)
      | .network += (($o.allowUnixSockets // []) | if length > 0 then {allowUnixSockets: unique} else {} end)
      | .network += (if $o.allowLocalBinding == true then {allowLocalBinding: true} else {} end)' >"$settings"

    # A stack can carry its options, so the person at the terminal may
    # not have chosen them: say what is on that weakens the sandbox.
    if jq -e '.enableWeakerNetworkIsolation == true' "$settings" >/dev/null; then
      echo "agent-sandbox-srt: enableWeakerNetworkIsolation is on: flox and other programs that verify certificates through macOS can do so, and data can leave through its trust service" >&2
    fi
    # Linux is not told: the sandbox has its own loopback there, and srt
    # ignores the switch.
    if [ "$darwin" = true ] && jq -e '.network.allowLocalBinding == true' "$settings" >/dev/null; then
      echo "agent-sandbox-srt: allowLocalBinding is on: programs can listen on local ports, and can reach every service on localhost, including a proxy that forwards off this machine" >&2
    fi
    # What listens on a socket runs outside the sandbox. The Nix daemon
    # is named because it is the one that undoes the allow list: it
    # fetches from, and its builds can send to, any host. srt allows a
    # path and everything under it, hence the prefix match.
    sockets=$(jq -r '.network.allowUnixSockets // [] | join(", ")' "$settings")
    if [ -n "$sockets" ] && [ "$darwin" = false ]; then
      echo "agent-sandbox-srt: allowUnixSockets has no effect on Linux, where srt cannot allow a socket by its path" >&2
    elif [ -n "$sockets" ]; then
      echo "agent-sandbox-srt: Unix sockets allowed: $sockets: what listens on one runs outside the sandbox" >&2
      if jq -e '.network.allowUnixSockets | any(. as $p | "/nix/var/nix/daemon-socket/socket" | startswith($p))' "$settings" >/dev/null; then
        echo "agent-sandbox-srt: the Nix daemon is reachable: it runs outside the sandbox and can reach any host, so the allow list no longer limits what leaves this session" >&2
      fi
    fi

    if [ -n "''${AGENT_SANDBOX_SRT_DRY_RUN:-}" ]; then
      cat "$settings"
      [ -z "$cert_file" ] || echo "would set: SSL_CERT_FILE=$cert_file" >&2
      echo "would run: $srt --settings $settings -- $*" >&2
      exit 0
    fi

    # Ubuntu 24.04 and later restrict unprivileged user namespaces, and
    # srt's bubblewrap cannot start under that without an admin step.
    if [ "$(uname -s)" = Linux ] &&
      [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ] &&
      ! "$srt" --settings "$settings" -- true >/dev/null 2>&1; then
      # Named after bwrap's store hash, so installs on other nixpkgs keep
      # their own profile rather than replacing each other's.
      aa=''${bwrap#/nix/store/}
      aa=agent-sandbox-srt-''${aa:0:8}
      die "srt cannot start a sandbox here: this kernel restricts unprivileged user namespaces.
Fix it once, as root, with either:
  - an AppArmor profile granting userns to srt's bwrap, for example
    /etc/apparmor.d/$aa holding
      abi <abi/4.0>,
      include <tunables/global>
      profile $aa $bwrap flags=(unconfined) {
        userns,
      }
    then: apparmor_parser -r /etc/apparmor.d/$aa
    (it names a /nix/store path, so redo it when bubblewrap is updated), or
  - sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 (relaxes it for the whole host)"
    fi

    [ -z "$cert_file" ] || export SSL_CERT_FILE=$cert_file
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
