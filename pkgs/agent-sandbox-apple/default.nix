# agent-sandbox-apple — runs the agent in a throwaway Linux VM on the
# Mac, through Apple's `container` CLI. The VM has no network of its own:
# its one way out is an allow-list proxy on the Mac, reached through a
# Unix socket.
#
#   agent-sandbox-apple [--options '<json>'] -- <command> [args]
#
# The contract agent-stacks launch hands an agent to (agent-stacks-cli
# ADR 0056). Options, all optional:
#
#   - allowedDomains: hosts added to the allow-list;
#   - allowRead, allowWrite: more host paths, mounted read-only or
#     read-write at the same path;
#   - writableGit (false): mount .git read-write rather than read-only;
#   - forwardLogin, forwardFloxhubToken (false): pass the Claude login,
#     or the FloxHub token, into the VM;
#   - cpus (4), memory ("4G"): the VM's size.
#
# AGENT_SANDBOX_APPLE_DRY_RUN=1 prints what would run instead of running
# it. AGENT_SANDBOX_APPLE_CONTAINER names another container, for the
# contract check's stub.
{
  lib,
  writeShellApplication,
  jq,
  coreutils,
  gnugrep,
  gnused,
  git,
  # Runs around the VM once the image lands.
  agent-sandbox-apple-proxy,
}:

(writeShellApplication {
  name = "agent-sandbox-apple";
  runtimeInputs = [ jq coreutils gnugrep gnused git ];
  text = ''
    die() {
      echo "agent-sandbox-apple: $*" >&2
      exit 2
    }
    container_cmd() { "''${AGENT_SANDBOX_APPLE_CONTAINER:-container}" "$@"; }
    dry_run=''${AGENT_SANDBOX_APPLE_DRY_RUN:-}
    floor=1.6.0
    lists='["allowedDomains", "allowRead", "allowWrite"]'
    switches='["writableGit", "forwardLogin", "forwardFloxhubToken"]'

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
          die "unexpected '$1'; usage: agent-sandbox-apple [--options '<json>'] -- <command> [args]"
          ;;
      esac
    done
    [ $# -gt 0 ] || die "no command after --"

    # The Mac. Not in the dry run, which runs on any system.
    if [ -z "$dry_run" ]; then
      [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] ||
        die "this sandbox needs macOS 26 or later on Apple silicon"
      macos=$(sw_vers -productVersion 2>/dev/null) || macos=""
      [ "''${macos%%.*}" -ge 26 ] 2>/dev/null ||
        die "this sandbox needs macOS 26 or later; this is macOS ''${macos:-of unknown version}"
    fi

    # container: present, at least the version that fixes 2026's
    # advisories, and its system service running.
    install="install Apple's container $floor or later from https://github.com/apple/container/releases"
    if [ -n "''${AGENT_SANDBOX_APPLE_CONTAINER:-}" ]; then
      [ -x "$AGENT_SANDBOX_APPLE_CONTAINER" ] ||
        die "AGENT_SANDBOX_APPLE_CONTAINER names $AGENT_SANDBOX_APPLE_CONTAINER, which is not a program: $install, or unset it"
    else
      command -v container >/dev/null || die "Apple's container is not on PATH: $install"
    fi
    out=$(container_cmd --version 2>/dev/null) || out=""
    [[ $out =~ [0-9]+\.[0-9]+\.[0-9]+ ]] || die "cannot read the version of container: $install"
    version=''${BASH_REMATCH[0]}
    [ "$(printf '%s\n' "$floor" "$version" | sort -V | head -n1)" = "$floor" ] ||
      die "container $version is older than $floor, which fixes its security advisories: $install"
    out=$(container_cmd system status 2>&1) || true
    grep -Eq '^status[[:space:]]+running[[:space:]]*$' <<<"$out" ||
      die "container's system service is not running: run 'container system start' first"

    # The project folder is writable inside the VM, so starting at / or ~
    # would make the whole disk or home folder writable.
    here=$(pwd -P)
    home=$(cd "$HOME" 2>/dev/null && pwd -P) || home=""
    if [ "$here" = / ] || [ "$here" = "$home" ]; then
      die "refusing to start in $here: the project folder is writable inside the sandbox, so start from a project folder instead"
    fi

    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$opts" ||
      die "options must be a JSON object, got: $opts"
    known=$(jq -cn --argjson l "$lists" --argjson s "$switches" '$l + $s + ["cpus", "memory"]')
    unknown=$(jq -r --argjson k "$known" 'keys - $k | join(", ")' <<<"$opts")
    [ -z "$unknown" ] || die "unknown option: $unknown (apple takes $(jq -r 'join(", ")' <<<"$known"))"
    bad=$(jq -r --argjson l "$lists" '[to_entries[] | select(.key | IN($l[]))
      | select((.value | type) != "array" or any(.value[]; type != "string")) | .key] | join(", ")' <<<"$opts")
    [ -z "$bad" ] || die "option $bad must be a list of strings"
    bad=$(jq -r --argjson s "$switches" '[to_entries[] | select(.key | IN($s[]))
      | select((.value | type) != "boolean") | .key] | join(", ")' <<<"$opts")
    [ -z "$bad" ] || die "option $bad must be true or false"
    jq -e '.cpus // 4 | type == "number" and . == floor and . >= 1' >/dev/null <<<"$opts" ||
      die "option cpus must be a whole number of CPUs, such as 4"
    jq -e '.memory // "4G" | type == "string" and test("^[0-9]+[KMGTPkmgtp]?$")' >/dev/null <<<"$opts" ||
      die "option memory must be a size, such as 4G or 8192M"
    opts=$(jq -c '{allowedDomains: [], allowRead: [], allowWrite: [], writableGit: false,
      forwardLogin: false, forwardFloxhubToken: false, cpus: 4, memory: "4G"} + .' <<<"$opts")
    on() { jq -e ".$1" >/dev/null <<<"$opts"; }

    # The Flox environment, which the VM activates. Only a local one,
    # locked for the VM's system.
    proj=''${FLOX_ENV_PROJECT:-}
    [ -n "$proj" ] && [ -f "$proj/.flox/env.json" ] ||
      die "no Flox environment: launch from an activated Flox environment"
    owner=$(jq -r '.owner // empty' "$proj/.flox/env.json")
    [ -z "$owner" ] ||
      die "the environment in $proj is managed on FloxHub ($owner/$(jq -r .name "$proj/.flox/env.json")): only a local environment can run in the VM for now"
    lock=$proj/.flox/env/manifest.lock
    [ -f "$lock" ] || die "the environment in $proj has no manifest.lock: activate it once on the Mac"
    grep -q '"aarch64-linux"' "$lock" ||
      die "the environment in $proj is not locked for aarch64-linux, which the VM runs: add it to options.systems in its manifest"

    agent=''${1##*/}

    # agent-sandbox-apple-<project folder>-<5 random>: two launches from
    # one folder never share a VM name.
    dns() { tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-63 | sed 's/-*$//'; }
    project=$(basename "$here" | dns)
    suffix=""
    alnum=abcdefghijklmnopqrstuvwxyz0123456789
    for _ in 1 2 3 4 5; do suffix+=''${alnum:RANDOM%36:1}; done
    vm_name=$(printf 'agent-sandbox-apple-%s' "$project" | cut -c1-57 | sed 's/-*$//')-$suffix

    # Placeholders until the guest image lands: the tag will be the hash
    # of its Containerfile and guest script.
    tag=000000000000
    image=agent-sandbox-apple:$tag
    volume=agent-sandbox-apple-nix-$tag
    guest=/opt/agent-sandbox-apple/guest.sh

    # The proxy's socket, in a folder of its own (mode 0700), so a second
    # launch from the same folder has its own. Under /tmp, not macOS's
    # long $TMPDIR, to stay well inside the 104-byte socket path limit.
    sock_dir=$(mktemp -d /tmp/asa.XXXXXX)
    trap 'rm -rf "$sock_dir"' EXIT

    # The VM's environment holds only what is named here, and every value
    # goes in by name (-e NAME), never on the command line.
    export AGENT_SANDBOX_APPLE_UID=1000
    env_names=(AGENT_SANDBOX_APPLE_UID)
    if [ "$agent" = claude ] && on forwardLogin; then
      login=()
      for v in CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY; do
        [ -z "''${!v:-}" ] || login+=("$v")
      done
      [ ''${#login[@]} -gt 0 ] ||
        die "forwardLogin is on, but neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set (make one with 'claude setup-token')"
      env_names+=("''${login[@]}")
      echo "agent-sandbox-apple: forwardLogin is on: ''${login[*]} goes into the VM, where the agent can read it" >&2
    fi
    if on forwardFloxhubToken; then
      token=$(flox auth token 2>/dev/null) && [ -n "$token" ] ||
        die "forwardFloxhubToken is on, but 'flox auth token' gives no token: run 'flox auth login'"
      export FLOX_FLOXHUB_TOKEN=$token
      unset token
      env_names+=(FLOX_FLOXHUB_TOKEN)
      echo "agent-sandbox-apple: forwardFloxhubToken is on: your FloxHub token goes into the VM, where the agent can read it" >&2
    fi

    # The mounts, each at the same path unless named. container mounts a
    # folder with --mount, but a file or a socket only with -v.
    mounts="[]"
    mount_args=()
    add_mount() { # <source> <target> <true if read-only>
      mounts=$(jq -c --arg s "$1" --arg t "$2" --argjson ro "$3" '. + [{source: $s, target: $t, readonly: $ro}]' <<<"$mounts")
      if [ -f "$1" ] || [ "$2" = /run/agent-proxy.sock ]; then
        [[ "$1$2" != *:* ]] || die "cannot mount $1: container cannot take a file path with ':' in it"
        mount_args+=(-v "$1:$2$([ "$3" = false ] || echo :ro)")
      else
        [[ "$1$2" != *,* ]] || die "cannot mount $1: container cannot take a folder path with ',' in it"
        mount_args+=(--mount "type=bind,source=$1,target=$2$([ "$3" = false ] || echo ,readonly)")
      fi
    }
    add_mount "$here" "$here" false

    # Whether $1 is $2 or inside it.
    within() { case "$1/" in "''${2%/}/"*) return 0 ;; esac; return 1; }
    for kind in allowRead allowWrite; do
      n=$(jq -r ".$kind | length" <<<"$opts")
      for ((i = 0; i < n; i++)); do
        given=$(jq -r --arg k "$kind" --argjson i "$i" '.[$k][$i]' <<<"$opts")
        [[ $given = /* ]] || die "$kind: $given is not an absolute path"
        if [ -d "$given" ]; then
          path=$(cd "$given" && pwd -P)
        elif [ -e "$given" ]; then
          path=$(cd "$(dirname "$given")" && pwd -P)/$(basename "$given")
        else
          die "$kind: $given does not exist"
        fi
        if within "$here" "$path"; then
          die "$kind: $given holds the project folder, which is already mounted"
        fi
        if [ -n "$home" ] && within "$home" "$path"; then
          die "$kind: $given holds your home folder"
        fi
        if [ "$kind" = allowRead ]; then
          add_mount "$path" "$path" true
          echo "agent-sandbox-apple: allowRead: the agent can read $path" >&2
        else
          add_mount "$path" "$path" false
          echo "agent-sandbox-apple: allowWrite: the agent can change $path" >&2
        fi
      done
    done

    # Git runs hooks and config on the Mac, so the agent may not change
    # .git. It is one mount, with nothing inside it: container drops a
    # mount that holds another, and only a mount point cannot be renamed
    # away and replaced. A worktree's .git file and its common git folder
    # (outside the project, at its own path) are one mount each.
    git_ro=true
    if on writableGit; then
      git_ro=false
      echo "agent-sandbox-apple: writableGit is on: the agent can change git hooks and config; they are checked at exit" >&2
    fi
    if [ -d "$here/.git" ]; then
      add_mount "$here/.git" "$here/.git" "$git_ro"
    elif [ -f "$here/.git" ]; then
      common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
        die "cannot find the git folder of the worktree in $here"
      add_mount "$here/.git" "$here/.git" "$git_ro"
      add_mount "$common" "$common" "$git_ro"
    fi
    # Activation runs the environment's hooks as root: an agent that
    # could edit them would run as root in the next session.
    [ ! -d "$here/.flox" ] || add_mount "$here/.flox" "$here/.flox" true
    add_mount "$proj/.flox/env" /host-env true
    add_mount "$sock_dir/proxy.sock" /run/agent-proxy.sock false

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
    allow=$(jq -c --argjson mcp "$mcp_hosts" '["api.anthropic.com", "platform.claude.com", "claude.ai",
      "console.anthropic.com"] + $mcp + .allowedDomains | unique' <<<"$opts")
    # Open only until the agent starts: S3 is every bucket in the region.
    startup='["api.flox.dev", "s3.us-east-1.amazonaws.com", "cache.nixos.org"]'
    domains=$(jq -r '.allowedDomains | join(", ")' <<<"$opts")
    [ -z "$domains" ] || echo "agent-sandbox-apple: allowedDomains: the agent can reach $domains" >&2

    # The container run argv, without the image and the command.
    run_args=(--rm -i)
    if [ -t 0 ] && [ -t 1 ]; then run_args+=(-t); fi
    run_args+=(--name "$vm_name" -l agent-sandbox-apple=1 --network none
      --read-only --tmpfs /tmp --tmpfs /home/agent
      -c "$(jq -r .cpus <<<"$opts")" -m "$(jq -r .memory <<<"$opts")" -w "$here")
    for v in "''${env_names[@]}"; do run_args+=(-e "$v"); done
    run_args+=("''${mount_args[@]}" -v "$volume:/nix")
    command=("$guest" "$agent" "''${@:2}")

    if [ -n "$dry_run" ]; then
      json_list() { printf '%s\0' "$@" | jq -Rsc 'split("\u0000")[:-1]'; }
      jq -n --arg image "$image" --arg volume "$volume" --arg name "$vm_name" \
        --argjson mounts "$mounts" --argjson allow "$allow" --argjson startup "$startup" \
        --argjson env "$(json_list "''${env_names[@]}")" \
        --argjson command "$(json_list "''${command[@]}")" \
        '{image: $image, volume: $volume, name: $name, network: "none", mounts: $mounts,
          env: $env, allow: $allow, startup: $startup, command: $command}'
      {
        printf 'would run: container run'
        printf ' %q' "''${run_args[@]}" "$image" "''${command[@]}"
        echo
      } >&2
      exit 0
    fi

    # The image, the cache volume and the proxy come next.
    die "running the VM is not built yet; AGENT_SANDBOX_APPLE_DRY_RUN=1 shows what would run"
  '';
}).overrideAttrs (old: {
  meta = (old.meta or { }) // {
    description = "Sandbox that runs the agent in a throwaway Linux VM through Apple's container";
    license = lib.licenses.mit;
    mainProgram = "agent-sandbox-apple";
    # The contract check runs everywhere; the Mac is checked at run time.
    platforms = lib.platforms.unix;
    # Supports an agent rather than being one. ADR 0014.
    category = "agent-tool";
  };
})
