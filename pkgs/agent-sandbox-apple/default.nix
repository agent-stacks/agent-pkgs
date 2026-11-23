# agent-sandbox-apple — runs the agent in a throwaway Linux VM on the
# Mac, through Apple's `container` CLI (`container run --rm`, one VM per
# launch). The VM has no network of its own (--network none): its one
# way out is an allow-list proxy on the Mac, reached through a Unix
# socket mounted into the VM.
#
#   agent-sandbox-apple [--options '<json>'] -- <command> [args]
#
# The contract agent-stacks launch hands an agent to (agent-stacks-cli
# ADR 0056). On each launch it:
#
#   - mounts the project read-write at its own path, and inside it
#     .git and .flox read-only, each as one mount (a worktree's .git
#     file and its common git folder too). Git and Flox run hooks on the
#     Mac, so the agent may not change them. The VM's root is read-only,
#     with /tmp and /home/agent on tmpfs;
#   - activates the Flox environment the caller is in (FLOX_ENV_PROJECT,
#     a local one locked for aarch64-linux) as root, in a folder of its
#     own rather than the project the agent writes, then runs the agent
#     in the project through `flox-agent launch` as uid 1000, with no
#     capabilities and no new privileges. /nix is not writable by the
#     agent;
#   - allows through the proxy (HTTPS CONNECT to host names only, no
#     private addresses): Claude's hosts, every host an MCP server of
#     the staged plugins names (CLAUDE_CODE_PLUGIN_DIRS), and
#     allowedDomains. api.flox.dev, s3.us-east-1.amazonaws.com and
#     cache.nixos.org are open while the environment activates: once
#     activation ends the proxy refuses new connections to them, though
#     a tunnel already open to one stays up;
#   - on any exit but SIGKILL, stops and deletes the VM, stops the
#     proxy and keeps its log at $TMPDIR/<VM name>.log;
#   - checks at exit every other git repository in the project, as git
#     on the Mac runs the hooks and core.fsmonitor of whichever one it
#     lands in: each .git or bare repository that is new, or whose hooks
#     or config changed, is named, and the exit is then 3 (or the
#     agent's own failure);
#   - refuses to start at /, at ~ or above it, from a FloxHub-managed
#     environment, or from one not locked for aarch64-linux.
#
# The guest image is built with `container build` on first use (about
# 6 minutes, measured), tagged with the hash of its Containerfile and
# guest.sh. Its /nix is copied to a volume, agent-sandbox-apple-nix-<tag>,
# that keeps the environment's packages between launches. Only one VM
# can attach that volume, so one launch runs at a time per image; a
# second is refused with the reason.
#
# Options, all optional. A switch weakens the sandbox, so each one that
# is on is named on stderr at every launch, as are allowedDomains and
# the allowRead and allowWrite paths:
#
#   - allowedDomains: hosts added to the allow-list;
#   - allowRead, allowWrite: more host paths, mounted read-only or
#     read-write at the same path. Absolute and existing, not holding ~,
#     and not inside or holding the project;
#   - writableGit (false): .git read-write rather than read-only. Its
#     hooks and its config, config.worktree, commondir and gitdir files
#     at any depth, core.hooksPath and .git itself are fingerprinted
#     before the run; any that changed are named at exit, which is then 3
#     (or the agent's own failure);
#   - forwardLogin (false): for claude, passes CLAUDE_CODE_OAUTH_TOKEN
#     or ANTHROPIC_API_KEY, whichever is set (make the first with
#     `claude setup-token`);
#   - forwardFloxhubToken (false): passes `flox auth token` as
#     FLOX_FLOXHUB_TOKEN, for environments with private packages;
#   - cpus (4), memory ("4G"): the VM's size.
#
# A secret goes in by name (`container run -e NAME`), never on a command
# line, and the agent can read it.
#
# Needs macOS 26 or later on Apple silicon, and Apple's container 1.6.0
# or later (<https://github.com/apple/container/releases>): 1.6.0 fixes
# its 2026 security advisories, and older ones are refused. Run
# `container system start` once first; its first run downloads a kernel
# and asks questions, so this does not run it for you. Never use
# `container machine` for agents: it mounts your home folder read-write.
#
# The paranoid setup. The sandbox keeps the agent away from your files,
# but a VM escape would land as you. To make that land on an account
# with nothing to steal, run the launches as a dedicated macOS user that
# holds no secrets (no SSH keys, cloud logins or browser profiles):
#
#   1. add a Standard (not admin) user, say agentbox, in System
#      Settings > Users & Groups;
#   2. log in as agentbox once (the login window, or
#      `ssh agentbox@localhost` with Remote Login on), and there run
#      `container system start`: the service is per user;
#   3. keep the projects that user works on in its own home, or in a
#      folder it shares with you, and launch from a shell of that user.
#      Give it only the tokens a launch needs, through forwardLogin and
#      forwardFloxhubToken.
#
# AGENT_SANDBOX_APPLE_DRY_RUN=1 prints what would run instead of running
# it. AGENT_SANDBOX_APPLE_CONTAINER and AGENT_SANDBOX_APPLE_PROXY name
# another container and proxy, for the contract check's stubs, and
# AGENT_SANDBOX_APPLE_SKIP_PLATFORM=1 skips the macOS and arch checks so
# that check can run them off the Mac. Test-only.
{
  lib,
  writeShellApplication,
  jq,
  coreutils,
  diffutils,
  findutils,
  gnugrep,
  gnused,
  git,
  # Runs around the VM, its only way out.
  agent-sandbox-apple-proxy,
}:

let
  # The guest image's build context: its tag is the hash of these two.
  share = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./Containerfile ./guest.sh ];
  };
in
(writeShellApplication {
  name = "agent-sandbox-apple";
  runtimeInputs = [ jq coreutils diffutils findutils gnugrep gnused git ];
  # The clean-up functions are called only from the EXIT trap, which
  # ShellCheck does not follow.
  excludeShellChecks = [ "SC2329" ];
  text = ''
    die() {
      echo "agent-sandbox-apple: $*" >&2
      exit 2
    }
    # Text the agent or container chose, made safe to print: each control
    # character but newline becomes '?', so none can drive the terminal.
    # GNU tr works on bytes whatever the locale. No LC_ALL=C here: set in
    # a function run as a pipeline stage, it crashed bash (SIGSEGV, about
    # one run in six) in the nix build sandbox on macOS.
    inert() { tr '\000-\011\013-\037\177' '?'; }
    container=''${AGENT_SANDBOX_APPLE_CONTAINER:-container}
    container_cmd() { "$container" "$@"; }
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

    # The Mac. Not in the dry run, which runs on any system, nor when the
    # contract check asks.
    if [ -z "$dry_run" ] && [ "''${AGENT_SANDBOX_APPLE_SKIP_PLATFORM:-}" != 1 ]; then
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

    # Whether $1 is $2 or inside it.
    within() { case "$1/" in "''${2%/}/"*) return 0 ;; esac; return 1; }
    # The project folder is writable inside the VM, so starting at / or ~,
    # or any folder that holds ~, would make the disk or home writable.
    here=$(pwd -P)
    home=$(cd "$HOME" 2>/dev/null && pwd -P) || home=""
    if [ "$here" = / ] || { [ -n "$home" ] && within "$home" "$here"; }; then
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
    # has(), not //: false and null are given values, and wrong ones.
    jq -e 'if has("cpus") then .cpus else 4 end | type == "number" and . == floor and . >= 1' >/dev/null <<<"$opts" ||
      die "option cpus must be a whole number of CPUs, such as 4"
    jq -e 'if has("memory") then .memory else "4G" end | type == "string" and test("^[0-9]+[KMGTPkmgtp]?$")' >/dev/null <<<"$opts" ||
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

    # The image is tagged with the hash of its Containerfile and guest
    # script, and each image has a /nix cache volume of its own.
    share=${share}
    tag=$(cat "$share/Containerfile" "$share/guest.sh" | sha256sum | cut -c1-12)
    image=agent-sandbox-apple:$tag
    volume=agent-sandbox-apple-nix-$tag
    guest=/opt/agent-sandbox-apple/guest.sh
    marker=/nix-cache/.agent-sandbox-apple-filled

    # The proxy's socket, in a folder of its own (mode 0700), so a second
    # launch from the same folder has its own. Under /tmp, not macOS's
    # long $TMPDIR, to stay well inside the 104-byte socket path limit.
    sock_dir=$(mktemp -d /tmp/asa.XXXXXX)

    # Runs once, on any exit but SIGKILL: stops the VM and the proxy,
    # keeps the proxy's log, checks the project's git repositories, and
    # removes $sock_dir. Signals are ignored from here, so a second Ctrl-C
    # cannot cut it short.
    run_pid="" proxy_pid="" scanned="" git_changed="" cleaned=""
    # The VMs of this launch whose `container run` has not returned. --rm
    # is done by that process, so a run cut short leaves its VM behind,
    # stopped and holding the cache volume, which no later launch can
    # then attach.
    leftover=()
    stop() { # <pid>: SIGTERM, then up to 10 s for it to go
      kill "$1" 2>/dev/null || return 0
      for _ in $(seq 100); do
        kill -0 "$1" 2>/dev/null || break
        sleep 0.1
      done
      wait "$1" 2>/dev/null || true
    }
    cleanup() {
      [ -z "$cleaned" ] || return 0
      cleaned=1
      trap "" INT TERM HUP
      # container run ignores SIGTERM, and the guest's PID 1 does too:
      # stopping the VM by name is what ends it, and --rm removes it.
      if [ -n "$run_pid" ]; then
        container_cmd stop "$vm_name" >/dev/null 2>&1 || true
        stop "$run_pid"
      fi
      for c in "''${leftover[@]}"; do
        container_cmd delete -f "$c" >/dev/null 2>&1 || true
      done
      if [ -n "$proxy_pid" ]; then
        stop "$proxy_pid"
        if [ -f "$sock_dir/proxy.log" ]; then
          kept=''${TMPDIR:-/tmp}
          kept=''${kept%/}/$vm_name.log
          cp "$sock_dir/proxy.log" "$kept" &&
            echo "agent-sandbox-apple: the proxy's log of this session is $kept" >&2
        fi
      fi
      if [ -n "$scanned" ]; then
        # The paths are the agent's to name, so they are printed inert.
        # Through files: a scan that cannot be read counts as a change.
        local diff_rc=0
        scan_state >"$sock_dir/scan.after" || diff_rc=2
        [ "$diff_rc" -gt 1 ] || diff "$sock_dir/scan.before" "$sock_dir/scan.after" >"$sock_dir/scan.diff" || diff_rc=$?
        [ "$diff_rc" -le 1 ] || : >"$sock_dir/scan.diff"
        sed -n 's/^[<>] [^ ]* //p' "$sock_dir/scan.diff" | sort -u | inert >"$sock_dir/changed"
        if [ "$diff_rc" -gt 1 ]; then
          git_changed=1
          echo "agent-sandbox-apple: could not check the project's git hooks and config; review them before running git here" >&2
        elif [ -s "$sock_dir/changed" ]; then
          git_changed=1
          {
            while IFS= read -r path; do echo "agent-sandbox-apple: changed: $path"; done <"$sock_dir/changed"
            echo "agent-sandbox-apple: git hooks or config changed during the session; review them before running git here"
          } >&2
        fi
      fi
      rm -rf "$sock_dir"
    }
    on_exit() {
      local rc=$?
      cleanup
      if [ -n "$git_changed" ] && [ "$rc" = 0 ]; then rc=3; fi
      exit "$rc"
    }
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    # The VM's environment holds only what is named here, and every value
    # goes in by name (-e NAME), never on the command line.
    env_names=()
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
        # Inside the project, it would sit over .git or .flox, whose
        # mounts container then drops.
        if within "$here" "$path" || within "$path" "$here"; then
          die "$kind: $given holds or is inside the project folder, which is already mounted"
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
    git_dirs=()
    if [ -d "$here/.git" ]; then
      add_mount "$here/.git" "$here/.git" "$git_ro"
      git_dirs=("$here/.git")
    elif [ -f "$here/.git" ]; then
      common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
        die "cannot find the git folder of the worktree in $here"
      add_mount "$here/.git" "$here/.git" "$git_ro"
      add_mount "$common" "$common" "$git_ro"
      own=$(git -C "$here" rev-parse --absolute-git-dir 2>/dev/null) ||
        die "cannot find the git folder of the worktree in $here"
      git_dirs=("$own")
      [ "$own" = "$common" ] || git_dirs+=("$common")
    fi
    # "<fingerprint> <path>" lines of what git on the Mac would run, so
    # that a change made in the VM shows as a changed or new line.
    fingerprint() {
      if [ -L "$1" ]; then
        printf 'link-%s\n' "$(readlink "$1" | sha256sum | cut -c1-64)"
      elif [ -f "$1" ]; then
        # The mode too: a hook made executable is a change.
        printf '%s-%s\n' "$(stat -c %a "$1")" "$(sha256sum <"$1" | cut -c1-64)"
      elif [ -d "$1" ]; then
        echo dir
      elif [ -e "$1" ]; then
        echo other
      else
        echo missing
      fi
    }
    # A path as a find -path/-ipath pattern that matches only itself.
    glob_quote() { printf '%s' "$1" | sed 's/[][*?\\]/\\&/g'; }
    # A git dir: itself and every config, config.worktree, commondir and
    # gitdir file and hook in it, at any depth (a submodule's under
    # modules/, a worktree's under worktrees/). Names match in any case:
    # the Mac's disk is case-insensitive, so git there reads CONFIG and
    # HOOKS too. Not its own objects folder: large, and git runs nothing
    # from it.
    git_meta() { # <git dir>
      local f
      echo "$(fingerprint "$1") $1"
      # A folder find cannot read shows as a line of its own, rather than
      # failing the scan, or hiding what is in it.
      {
        find "$1" -mindepth 1 -ipath "$(glob_quote "$1")/objects" -prune -o \( -iname config \
          -o -iname config.worktree -o -iname commondir -o -iname gitdir -o -iname hooks \
          -o -ipath '*/hooks/*' \) -print0 2>/dev/null ||
          printf '%s\0' "$1/<unreadable>"
      } | sort -z | while IFS= read -r -d "" f; do echo "$(fingerprint "$f") $f"; done
    }
    # A path a git config names, made absolute against <base>: printed
    # when it is in the project, both as written and with symlinks
    # resolved, as the agent can change either. A leading ~/ is $HOME,
    # as git takes it, and projects usually live there; ~user paths are
    # left alone.
    in_project() { # <path> <base>
      local t=$1 r
      case $t in
        \~/*) t=$HOME/''${t:2} ;;
        \~*) return 0 ;;
      esac
      [[ $t = /* ]] || t=$2/$t
      t=$(realpath -m -s -- "$t") || return 0
      r=$(realpath -m -- "$t") || r=$t
      if within "$t" "$here"; then printf '%s\0' "$t"; fi
      if [ "$r" != "$t" ] && within "$r" "$here"; then printf '%s\0' "$r"; fi
      return 0
    }
    # A path and, for a real folder, everything in it at any depth.
    tree_state() { # <path>
      local f
      echo "$(fingerprint "$1") $1"
      [ -d "$1" ] && [ ! -L "$1" ] || return 0
      {
        find "$1" -mindepth 1 -print0 2>/dev/null || printf '%s\0' "$1/<unreadable>"
      } | sort -z | while IFS= read -r -d "" f; do echo "$(fingerprint "$f") $f"; done
    }
    # What a config file points into the project: its core.hooksPath
    # (husky's .husky, lefthook), relative to <hooks base> as git takes
    # it, and its include.path and includeIf.*.path files, relative to
    # the file's folder, followed <depth> levels. Read with `git config
    # --file`, which runs nothing and follows no include by itself.
    config_file_state() { # <config file> <hooks base> <depth>
      local rec t
      {
        git -C / config -z --file "$1" --get-all core.hooksPath 2>/dev/null || true
      } | while IFS= read -r -d "" rec; do
        in_project "$rec" "$2" | while IFS= read -r -d "" t; do
          tree_state "$t"
          # husky v9: hooksPath is .husky/_, whose stubs run, through
          # _/h, the user's hooks one folder up.
          if [ "''${t##*/}" = _ ] || [ -f "$t/h" ] || [ -f "$t/husky.sh" ]; then
            if [ "''${t%/*}" != "$here" ] && within "''${t%/*}" "$here"; then tree_state "''${t%/*}"; fi
          fi
        done
      done
      [ "$3" -gt 0 ] || return 0
      {
        git -C / config -z --file "$1" --get-regexp '^(include\.path|includeif\..*\.path)$' 2>/dev/null || true
      } | while IFS= read -r -d "" rec; do
        in_project "''${rec#*$'\n'}" "''${1%/*}" | while IFS= read -r -d "" t; do
          tree_state "$t"
          if [ -f "$t" ]; then config_file_state "$t" "$2" $(($3 - 1)); fi
        done
      done
      return 0
    }
    # A git dir's own config files, and those of its submodules (under
    # modules/, hooks relative to the submodule's work tree: its
    # core.worktree, else its module path under the work tree) and of
    # its linked worktrees (worktrees/*/config.worktree, hooks relative
    # to the folder its gitdir file names).
    config_refs() { # <git dir> <hooks base>
      local f m wt rel w g
      for f in "$1/config" "$1/config.worktree"; do
        if [ -f "$f" ]; then config_file_state "$f" "$2" 2; fi
      done
      if [ -d "$1/modules" ]; then
        {
          find "$1/modules" -iname objects -type d -prune -o \( -iname config -o -iname config.worktree \) \
            -type f -print0 2>/dev/null || true
        } | sort -z | while IFS= read -r -d "" f; do
          m=''${f%/*}
          wt=$(git -C / config --file "$m/config" --get core.worktree 2>/dev/null) || wt=""
          if [ -n "$wt" ]; then
            [[ $wt = /* ]] || wt=$m/$wt
          else
            rel=''${m#"$1/modules/"}
            wt=$2/''${rel//\/modules\//\/}
          fi
          config_file_state "$f" "$wt" 2
        done
      fi
      for w in "$1"/worktrees/*/; do
        w=''${w%/}
        [ -f "$w/gitdir" ] || continue
        g=$(head -n 1 "$w/gitdir")
        [ -n "$g" ] || continue
        for f in "$w/config" "$w/config.worktree"; do
          if [ -f "$f" ]; then config_file_state "$f" "''${g%/*}" 2; fi
        done
      done
      return 0
    }
    # A git dir found in the project, and the common dir its commondir
    # file names, when that is in the project too: it holds the config
    # and hooks git uses, and need not have a HEAD of its own. With what
    # their config points into the project.
    git_dir_state() { # <git dir> <work tree, or the git dir when bare>
      local c
      git_meta "$1"
      config_refs "$1" "$2"
      [ -f "$1/commondir" ] || return 0
      c=$(head -n 1 "$1/commondir")
      [ -n "$c" ] || return 0
      [[ $c = /* ]] || c=$1/$c
      if [ -d "$c" ] && c=$(cd "$c" && pwd -P) && within "$c" "$here" && ! within "$c" "$here/.git"; then
        git_meta "$c"
        config_refs "$c" "$2"
      fi
      return 0
    }
    # Under writableGit, the project's own git dirs, core.hooksPath, .git
    # itself and the git dirs git resolves, as each can point git at other
    # hooks and config.
    git_state() {
      local d hooks_path resolved
      for d in "''${git_dirs[@]}"; do git_meta "$d"; done
      hooks_path=$(git -C "$here" config --get core.hooksPath 2>/dev/null) || hooks_path=""
      echo "$(printf '%s' "$hooks_path" | sha256sum | cut -c1-64) core.hooksPath"
      echo "$(stat -c %d:%i "$here/.git" 2>/dev/null || echo missing)-$(fingerprint "$here/.git") $here/.git"
      resolved=$(git -C "$here" rev-parse --absolute-git-dir --path-format=absolute --git-common-dir 2>&1) || true
      echo "$(printf '%s' "$resolved" | sha256sum | cut -c1-64) the git dirs git resolves: $(tr '\n' ' ' <<<"$resolved")"
    }
    # Every other git repository in the project, on every launch: the
    # agent can make one or change one it holds (a vendored repo, a
    # submodule's), and git on the Mac runs its hooks and core.fsmonitor
    # wherever it lands, a shell prompt's `git status` included. Every
    # .git, file or folder, the git dir a .git file names when it is in
    # the project, and every folder git would take as a git dir: a HEAD
    # (file or symlink) with objects and refs, or with a commondir. Names
    # match in any case (.GIT, head), as on the Mac's disk. Not
    # node_modules, nor the top-level .git when it is mounted on its own
    # (read-only, or checked by git_state).
    planted_state() {
      local skip=() f d g
      if [ ''${#git_dirs[@]} -gt 0 ]; then
        skip=(-path "$(glob_quote "$here/.git")" -prune -o)
      fi
      {
        find "$here" "''${skip[@]}" -name node_modules -type d -prune -o \
          -iname .git -print0 -prune -o -iname HEAD -print0 2>/dev/null ||
          printf '%s\0' "$here/<unreadable>"
      } | sort -z |
        while IFS= read -r -d "" f; do
          case ''${f##*/} in
            [.][gG][iI][tT])
              if [ -d "$f" ] && [ ! -L "$f" ]; then
                git_dir_state "$f" "''${f%/*}"
                continue
              fi
              echo "$(fingerprint "$f") $f"
              [ -f "$f" ] && [ ! -L "$f" ] || continue
              g=$(sed -n '1s/^gitdir: //p' "$f")
              [ -n "$g" ] || continue
              [[ $g = /* ]] || g=''${f%/*}/$g
              if [ -d "$g" ] && g=$(cd "$g" && pwd -P) && within "$g" "$here" && ! within "$g" "$here/.git"; then
                git_dir_state "$g" "''${f%/*}"
              fi
              ;;
            [hH][eE][aA][dD])
              d=''${f%/*}
              if { [ -d "$d/objects" ] && [ -d "$d/refs" ]; } || [ -f "$d/commondir" ]; then
                git_dir_state "$d" "$d"
              fi
              ;;
            *) echo "$(fingerprint "$f") $f" ;;
          esac
        done
    }
    scan_state() {
      local d
      planted_state
      # The project's own repository: its .git is mounted on its own, but
      # what its config points into the project is not.
      for d in "''${git_dirs[@]}"; do config_refs "$d" "$here"; done
      [ ''${#git_dirs[@]} -eq 0 ] || ! on writableGit || git_state
    }
    # Activation runs the environment's hooks as root: an agent that
    # could edit them would run as root in the next session.
    # That is the environment's too when it is a folder of the project.
    [ ! -d "$here/.flox" ] || add_mount "$here/.flox" "$here/.flox" true
    env_flox=$(cd "$proj/.flox" && pwd -P)
    if [ "$env_flox" != "$here/.flox" ] && within "$env_flox" "$here"; then
      add_mount "$env_flox" "$env_flox" true
    fi
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
      json_list() {
        if [ $# -eq 0 ]; then echo '[]'; return; fi
        printf '%s\0' "$@" | jq -Rsc 'split("\u0000")[:-1]'
      }
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

    # The image and the cache volume, made on first use. These, and the
    # VM's start, are the only waits, so each says what it is doing.
    say() { echo "agent-sandbox-apple: $*" >&2; }
    # <name> <container run args...>: a VM that runs one command, named so
    # clean-up can delete it if the run is cut short.
    helper_run() {
      local rc=0
      leftover+=("$1")
      container_cmd run --rm --name "$1" "''${@:2}" || rc=$?
      unset 'leftover[-1]'
      return "$rc"
    }
    ensure_image() {
      container_cmd image inspect "$image" >/dev/null 2>&1 && return 0
      say "building the guest image $image, once per version of this sandbox (about 6 minutes)"
      container_cmd build -t "$image" "$share" >"$sock_dir/build.log" 2>&1 || {
        cat "$sock_dir/build.log" >&2
        die "could not build the guest image $image"
      }
    }
    # A new volume is empty, not a copy of the image's /nix. The marker
    # goes in last, so a fill cut short is done again. Never call this on
    # a volume a launch has used: it overwrites var/nix/db with the
    # image's, which then no longer knows the environment's packages.
    fill_volume() {
      say "filling the Nix cache volume $volume from the image (about 15 seconds)"
      helper_run "agent-sandbox-apple-fill-$suffix" --network none -l agent-sandbox-apple=1 \
        -v "$volume:/nix-cache" "$image" sh -c "cp -a /nix/. /nix-cache/ && touch $marker" >&2 ||
        die "could not fill the Nix cache volume $volume"
    }
    ensure_volume() {
      if ! container_cmd volume inspect "$volume" >/dev/null 2>&1; then
        say "creating the Nix cache volume $volume, shared by every launch of this image"
        container_cmd volume create "$volume" >/dev/null || die "could not create the volume $volume"
        fill_volume
        return 0
      fi
      # Filled again only when the check says so: a fill over a used
      # volume puts back the image's Nix database, which then no longer
      # knows the environment's packages. The check fails outright when
      # the volume is in use: only one VM can attach it.
      # Not through helper_run: $(...) is a subshell, whose leftover the
      # clean-up would not see.
      local check=agent-sandbox-apple-check-$suffix state why
      leftover+=("$check")
      state=$(container_cmd run --rm --name "$check" --network none -l agent-sandbox-apple=1 \
        -v "$volume:/nix-cache" "$image" sh -c "if test -f $marker; then echo filled; else echo empty; fi" \
        2>"$sock_dir/check.err") || state=""
      unset 'leftover[-1]'
      case ''${state##*$'\n'} in
        filled) ;;
        empty) fill_volume ;;
        *)
          why=$(grep -v '^[[:space:]]*$' "$sock_dir/check.err" | tail -n 1 | inert) || why=""
          die "could not read the Nix cache volume $volume''${why:+ (container: $why)}. Only one launch can use it at a time: is another running? ('container list -a'). A stopped agent-sandbox-apple-* VM there, left by a launch that was killed, holds it too: remove it with 'container delete <name>'"
          ;;
      esac
    }
    ensure_image
    ensure_volume

    # The proxy, the VM's one way out, on the socket the VM mounts.
    jq -r '.[]' <<<"$allow" >"$sock_dir/allow"
    jq -r '.[]' <<<"$startup" >"$sock_dir/startup"
    mkfifo "$sock_dir/ready"
    proxy=''${AGENT_SANDBOX_APPLE_PROXY:-${agent-sandbox-apple-proxy}/bin/agent-sandbox-apple-proxy}
    "$proxy" --socket "$sock_dir/proxy.sock" --allow "$sock_dir/allow" --startup "$sock_dir/startup" \
      --log "$sock_dir/proxy.log" >"$sock_dir/ready" &
    proxy_pid=$!
    line=""
    read -r -t 10 line <"$sock_dir/ready" || true
    [ "$line" = ready ] || die "the proxy did not start"

    scan_state >"$sock_dir/scan.before" || die "could not read the project's git repositories before the run"
    scanned=1

    # Not exec'd: this stays to stop the proxy and clean up. In the
    # background so a signal reaches the trap at once; stdin given
    # explicitly, as a background job would get /dev/null. Its stderr is
    # kept too, to spot a FloxHub sign-in failure.
    mkfifo "$sock_dir/stderr"
    tee "$sock_dir/run.err" <"$sock_dir/stderr" >&2 &
    tee_pid=$!
    # The program itself, not the function, so $! is its pid.
    leftover+=("$vm_name")
    "$container" run "''${run_args[@]}" "$image" "''${command[@]}" <&0 2>"$sock_dir/stderr" &
    run_pid=$!
    status=0
    wait "$run_pid" || status=$?
    run_pid=""
    leftover=()
    wait "$tee_pid" || true

    if [ "$status" != 0 ] && ! on forwardFloxhubToken; then
      if sed '/^latch closed$/q' "$sock_dir/proxy.log" 2>/dev/null | grep -Eq '^deny api\.flox\.dev(:[0-9]+)? ' ||
        grep -Eqi 'not be authenticated|floxhub.*(auth|log ?in|token)' "$sock_dir/run.err" 2>/dev/null; then
        say "the Flox environment may need your FloxHub sign-in: set forwardFloxhubToken to true in the sandbox's options"
      fi
    fi
    exit "$status"
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
