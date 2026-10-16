# agent-sandbox-nono — runs the agent inside nono: Seatbelt on macOS,
# Landlock on Linux, with no admin step on either.
#
#   agent-sandbox-nono [--options '<json>'] -- <command> [args]
#
# The contract agent-stacks launch hands an agent to (agent-stacks-cli
# ADR 0056). Each launch writes a nono profile and runs the command on
# it. The profile is nono's own Claude profile (the nolabs-ai/claude
# registry pack's policy.json), carried here because that pack is
# fetched into the user's config at run time and also writes a plugin
# into ~/.claude. Its two registry paths are dropped, /nix/store is
# readable, and the Linux groups nono 0.79 does not ship yet are left
# out.
#
#   - the project folder writable; ~/.ssh and other credentials denied
#     by nono's default profile;
#   - the network open, as nono's Claude profile leaves it, until
#     allowedDomains is given: then only Claude's hosts, the hosts of
#     the staged plugins' MCP servers (CLAUDE_CODE_PLUGIN_DIRS) and the
#     listed ones;
#   - allowWrite and denyRead add folders to write or hide;
#   - it refuses to start at / or ~, where the project folder would be
#     everything.
#
# AGENT_SANDBOX_NONO_DRY_RUN=1 prints the profile and the command
# instead of running them.
{
  lib,
  writeShellApplication,
  jq,
  coreutils,
  findutils,
  nono,
}:

(writeShellApplication {
  name = "agent-sandbox-nono";
  runtimeInputs = [ jq coreutils findutils ];
  text = ''
    die() {
      echo "agent-sandbox-nono: $*" >&2
      exit 2
    }
    nono=${lib.getExe nono}
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
          die "unexpected '$1'; usage: agent-sandbox-nono [--options '<json>'] -- <command> [args]"
          ;;
      esac
    done
    [ $# -gt 0 ] || die "no command after --"

    here=$(pwd -P)
    if [ "$here" = / ] || [ "$here" = "$(cd "$HOME" 2>/dev/null && pwd -P)" ]; then
      die "refusing to start in $here: the project folder is writable inside the sandbox, so start from a project folder instead"
    fi

    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$opts" ||
      die "options must be a JSON object, got: $opts"
    unknown=$(jq -r --argjson k "$keys" 'keys - $k | join(", ")' <<<"$opts")
    [ -z "$unknown" ] || die "unknown option: $unknown (nono takes $(jq -r 'join(", ")' <<<"$keys"))"
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

    # Claude's temp folder: Claude adds claude-<uid> to CLAUDE_CODE_TMPDIR
    # (default /tmp). Landlock attaches a rule only to a path that exists,
    # so it is made before the sandbox goes up; otherwise Claude refuses
    # to start on a machine whose /tmp was just cleared. The profile is
    # written there, and in a shared /tmp another user can make the
    # folder first, so it must be ours and closed to everyone else.
    tmp=''${CLAUDE_CODE_TMPDIR:-/tmp}
    tmp=''${tmp%/}/claude-$(id -u)
    (umask 077 && mkdir -p "$tmp")
    [ -d "$tmp" ] && [ ! -L "$tmp" ] && [ -O "$tmp" ] ||
      die "$tmp is not a folder of yours; remove it, or set CLAUDE_CODE_TMPDIR to a folder you own"
    chmod 700 "$tmp"

    # exec leaves no chance to remove a launch's profile, so those from
    # earlier days, long read by nono, are cleared here.
    find "$tmp" -maxdepth 1 -name 'agent-sandbox-nono.*' -type f -mtime +0 -delete

    profile=$(mktemp "$tmp/agent-sandbox-nono.XXXXXX")
    jq -n --argjson o "$opts" --argjson mcp "$mcp_hosts" --arg tmp "$tmp" '{
      meta: { name: "agent-stacks-claude", description: "Claude Code under agent-stacks" },
      extends: "default",
      groups: { include: [
        { name: "claude_code_macos", when: "macos" },
        { name: "user_caches_macos", when: "macos" },
        "node_runtime", "rust_runtime", "python_runtime",
        { name: "vscode_macos", when: "macos" },
        "nix_runtime", "git_config", "unlink_protection"
      ] },
      security: { signal_mode: "isolated", capability_elevation: false },
      filesystem: ({
        allow: ([
          "$HOME/.claude", "$HOME/.local/state/claude/locks", "$HOME/.cache/claude",
          $tmp, { path: "$HOME/Library/Keychains", when: "macos" }
        ] + ($o.allowWrite // [])),
        read: ["/nix/store"],
        allow_file: ["$HOME/.claude.json", "$HOME/.claude.json.lock", "$HOME/.claude.lock"],
        bypass_protection: [{ path: "$HOME/Library/Keychains", when: "macos" }]
      } + (if $o.denyRead then { deny: $o.denyRead } else {} end)),
      network: ({ block: false } + (if $o.allowedDomains then
        { allow_domain: (["api.anthropic.com", "platform.claude.com"] + $mcp + $o.allowedDomains | unique) }
        else {} end)),
      workdir: { access: "readwrite" },
      open_urls: {
        allow_origins: ["https://claude.ai", "https://claude.com", "https://api.anthropic.com", "https://platform.claude.com"],
        allow_localhost: true
      },
      allow_launch_services: true
    }' >"$profile"

    name=''${1##*/}
    # mktemp inside needs a TMPDIR it can write to. On Linux /tmp itself
    # is not writable inside, and a TMPDIR from outside (/tmp, a nix-shell
    # folder) is not granted, so it points at the temp folder; macOS's
    # own TMPDIR is granted by nono and is kept.
    tmpenv=()
    if [ "$(uname -s)" = Linux ] || [ -z "''${TMPDIR:-}" ]; then
      tmpenv=(env "TMPDIR=$tmp")
    fi
    set -- "''${tmpenv[@]}" "$nono" run -s --no-diagnostics --allow-cwd --profile "$profile" -- "$@"
    if [ -n "''${AGENT_SANDBOX_NONO_DRY_RUN:-}" ]; then
      cat "$profile"
      echo "would run: $*" >&2
      exit 0
    fi

    # Landlock attaches a rule only to a path that exists, and drops the
    # grant for one that does not (the pack's ensure-dirs.sh).
    mkdir -p "$HOME/.claude" "$HOME/.cache/claude" "$HOME/.local/state/claude/locks"

    echo "agent-sandbox-nono: running $name inside nono" >&2
    exec "$@"
  '';
}).overrideAttrs (old: {
  meta = (old.meta or { }) // {
    description = "Sandbox that runs the agent inside nono";
    license = lib.licenses.mit;
    mainProgram = "agent-sandbox-nono";
    platforms = nono.meta.platforms or lib.platforms.unix;
    # Supports an agent rather than being one. ADR 0014.
    category = "agent-tool";
  };
})
