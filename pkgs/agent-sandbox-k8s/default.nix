# agent-sandbox-k8s — runs the agent in a pod on Kubernetes: one
# agent-sandbox Sandbox (https://agent-sandbox.sigs.k8s.io/) per launch,
# on the Flox runtime class, with a FloxHub environment as everything in
# the pod.
#
#   agent-sandbox-k8s [--options '<json>'] -- <command> [args]
#
# The contract agent-stacks launch hands an agent to (agent-stacks-cli
# ADR 0056). Options, all optional:
#
#   - environment: the FloxHub environment, owner/name[:generation];
#   - context, namespace: where the Sandbox goes (current context,
#     agent-sandbox);
#   - copyWorkspace (true), copyWorkspaceBack (false): copy the project
#     folder in, and back at exit;
#   - forwardLogin, forwardFloxhubToken (false): pass the Claude login,
#     or the FloxHub token, into the pod;
#   - ttl (4h): when the cluster deletes a Sandbox left behind.
#
# When the environment has flox-agent, the agent runs through
# `flox-agent launch`, which gives it the stack's plugins.
#
# AGENT_SANDBOX_K8S_DRY_RUN=1 prints the manifests and the commands
# instead of running them. AGENT_SANDBOX_K8S_KUBECTL names another
# kubectl, for the contract check's stub.
{
  lib,
  writeShellApplication,
  jq,
  coreutils,
  gnutar,
  gnused,
  gnugrep,
  findutils,
  kubectl,
}:

(writeShellApplication {
  name = "agent-sandbox-k8s";
  runtimeInputs = [ jq coreutils findutils gnutar gnused gnugrep ];
  # The cleanup functions are called only from the EXIT trap, which
  # ShellCheck does not follow.
  excludeShellChecks = [ "SC2329" ];
  text = ''
    die() {
      echo "agent-sandbox-k8s: $*" >&2
      exit 2
    }
    kubectl=''${AGENT_SANDBOX_K8S_KUBECTL:-${lib.getExe kubectl}}
    keys='["environment", "context", "namespace", "copyWorkspace", "copyWorkspaceBack", "forwardLogin", "forwardFloxhubToken", "ttl"]'

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
          die "unexpected '$1'; usage: agent-sandbox-k8s [--options '<json>'] -- <command> [args]"
          ;;
      esac
    done
    [ $# -gt 0 ] || die "no command after --"

    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$opts" ||
      die "options must be a JSON object, got: $opts"
    unknown=$(jq -r --argjson k "$keys" 'keys - $k | join(", ")' <<<"$opts")
    [ -z "$unknown" ] || die "unknown option: $unknown (k8s takes $(jq -r 'join(", ")' <<<"$keys"))"
    bad=$(jq -r 'to_entries[] | select(
        if (.key | IN("copyWorkspace", "copyWorkspaceBack", "forwardLogin", "forwardFloxhubToken"))
        then (.value | type) != "boolean"
        else (.value | type) != "string" or .value == "" end) | .key' <<<"$opts")
    [ -z "$bad" ] || die "option $(head -n1 <<<"$bad") has the wrong type (see the options in agent-sandbox-k8s's header)"
    opts=$(jq -c '{namespace: "agent-sandbox", copyWorkspace: true, copyWorkspaceBack: false,
      forwardLogin: false, forwardFloxhubToken: false, ttl: "4h"} + .' <<<"$opts")
    jq -e '.ttl | test("^[0-9]+[smhd]$")' >/dev/null <<<"$opts" ||
      die "ttl must be a number and a unit (s, m, h, d), such as 30m or 8h"
    jq -e '.copyWorkspaceBack and (.copyWorkspace | not)' >/dev/null <<<"$opts" &&
      die "copyWorkspaceBack needs copyWorkspace: there is nothing to copy back"
    copy_in=$(jq -r .copyWorkspace <<<"$opts")
    copy_back=$(jq -r .copyWorkspaceBack <<<"$opts")

    # The project folder is copied in (and back over), so starting at / or
    # ~ would copy the whole disk or home folder.
    here=$(pwd -P)
    if [ "$copy_in" = true ] &&
      { [ "$here" = / ] || [ "$here" = "$(cd "$HOME" 2>/dev/null && pwd -P)" ]; }; then
      die "refusing to start in $here: the project folder is copied into the sandbox, so start from a project folder instead"
    fi

    # The shim pulls the pod's environment from FloxHub by name, so the
    # launch environment must be pushed, and is pinned to the generation
    # it is at: one with changes not pushed would run as something else.
    resolve_environment() {
      local given proj owner name gen hub list
      given=$(jq -r '.environment // empty' <<<"$opts")
      if [ -n "$given" ]; then
        echo "$given"
        return
      fi
      proj=''${FLOX_ENV_PROJECT:-}
      [ -n "$proj" ] && [ -f "$proj/.flox/env.json" ] ||
        die "no environment: launch from an activated Flox environment pushed to FloxHub, or name one with the environment option"
      owner=$(jq -r '.owner // empty' "$proj/.flox/env.json")
      name=$(jq -r '.name // empty' "$proj/.flox/env.json")
      [ -n "$owner" ] ||
        die "the environment in $proj is not on FloxHub: run 'flox push' there, or name one with the environment option"
      list=$(flox list -a -d "$proj" 2>/dev/null) ||
        die "cannot read the environment in $proj with 'flox list -a'"
      gen=$(sed -n 's/^Generation: *\([0-9][0-9]*\) (live)$/\1/p' <<<"$list")
      hub=$(sed -n 's/^FloxHub: *//p' <<<"$list")
      if [ -z "$gen" ] || grep -q 'unpushed\|diverged' <<<"$hub"; then
        die "$owner/$name has changes not on FloxHub ($(sed -n 's/^Generation: *//p' <<<"$list")): run 'flox push' there, or name one with the environment option"
      fi
      echo "$owner/$name:$gen"
    }
    env_ref=$(resolve_environment)
    namespace=$(jq -r .namespace <<<"$opts")
    agent=''${1##*/}

    # <agent>-<project folder>-<5 random>, as a DNS label: two launches
    # from one folder never share a name.
    # The labels take the same form, at most 63 characters.
    dns() { tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-63 | sed 's/-*$//'; }
    project=$(basename "$(pwd -P)" | dns)
    agent_label=$(dns <<<"$agent")
    suffix=""
    alnum=abcdefghijklmnopqrstuvwxyz0123456789
    for _ in 1 2 3 4 5; do suffix+=''${alnum:RANDOM%36:1}; done
    prefix=$(printf '%s-%s' "$agent_label" "$project" | cut -c1-57 | sed 's/-*$//')
    sandbox_name=$prefix-$suffix

    # What the session Secret holds, values in memory only. The Claude
    # login is forwarded only to Claude.
    secret_data="{}"
    if [ "$agent" = claude ] && jq -e .forwardLogin >/dev/null <<<"$opts"; then
      for v in CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY; do
        [ -z "''${!v:-}" ] || secret_data=$(jq -c --arg k "$v" --arg v "''${!v}" '. + {($k): $v}' <<<"$secret_data")
      done
      [ "$secret_data" != "{}" ] ||
        die "forwardLogin is on, but neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set (make one with 'claude setup-token')"
    fi
    if jq -e .forwardFloxhubToken >/dev/null <<<"$opts"; then
      token=$(flox auth token 2>/dev/null) && [ -n "$token" ] ||
        die "forwardFloxhubToken is on, but 'flox auth token' gives no token: run 'flox auth login'"
      secret_data=$(jq -c --arg v "$token" '. + {"floxhub-token": $v}' <<<"$secret_data")
      unset token
    fi

    # The Secret, with its values as given (`redact`) or base64.
    secret_manifest() {
      jq -c --arg n "$sandbox_name" --arg ns "$namespace" --arg mode "$1" '{
        apiVersion: "v1", kind: "Secret",
        metadata: { name: $n, namespace: $ns,
                    labels: { "app.kubernetes.io/managed-by": "agent-sandbox-k8s" } },
        type: "Opaque",
        data: (map_values(if $mode == "redact" then "<redacted>" else @base64 end))
      }' <<<"$secret_data"
    }

    sandbox_manifest() {
      ttl=$(jq -r .ttl <<<"$opts")
      n=''${ttl%?}
      case $ttl in
        *s) secs=$n ;; *m) secs=$((n * 60)) ;; *h) secs=$((n * 3600)) ;; *d) secs=$((n * 86400)) ;;
      esac
      shutdown=$(date -u -d "@$(( $(date +%s) + secs ))" +%Y-%m-%dT%H:%M:%SZ)
      jq -n --arg n "$sandbox_name" --arg ns "$namespace" --arg agent "$agent_label" \
        --arg project "$project" --arg env "$env_ref" --arg shutdown "$shutdown" \
        --argjson keys "$(jq -c keys <<<"$secret_data")" '
        ($keys - ["floxhub-token"]) as $login
        | ($keys | index("floxhub-token") != null) as $hub
        | {
          apiVersion: "agents.x-k8s.io/v1beta1", kind: "Sandbox",
          metadata: { name: $n, namespace: $ns, labels: {
            "app.kubernetes.io/managed-by": "agent-sandbox-k8s",
            "agent-sandbox-k8s/agent": $agent,
            "agent-sandbox-k8s/project": $project } },
          spec: {
            service: false,
            shutdownTime: $shutdown,
            shutdownPolicy: "Delete",
            podTemplate: {
              metadata: { annotations: { "flox.dev/environment": $env } },
              spec: {
                runtimeClassName: "flox",
                automountServiceAccountToken: false,
                securityContext: { runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, runAsNonRoot: true },
                containers: [{
                  name: "agent",
                  image: "flox/empty:1.0.0",
                  command: ["sleep", "infinity"],
                  workingDir: "/workspace",
                  env: ([{ name: "HOME", value: "/home/agent" }, { name: "IS_SANDBOX", value: "1" }]
                    + [ $login[] | { name: ., valueFrom: { secretKeyRef: { name: $n, key: . } } } ]),
                  volumeMounts: ([{ name: "workspace", mountPath: "/workspace" },
                                  { name: "home", mountPath: "/home/agent" }]
                    + if $hub then [{ name: "floxhub-token", mountPath: "/var/run/secrets/flox.dev", readOnly: true }] else [] end)
                }],
                volumes: ([{ name: "workspace", emptyDir: {} }, { name: "home", emptyDir: {} }]
                  + if $hub then [{ name: "floxhub-token", secret: { secretName: $n,
                      items: [{ key: "floxhub-token", path: "floxhub-token" }] } }] else [] end)
              }
            }
          }
        }'
    }

    ctx=()
    context=$(jq -r '.context // empty' <<<"$opts")
    [ -z "$context" ] || ctx=(--context "$context")
    k=("$kubectl" "''${ctx[@]}" -n "$namespace")
    # kubectl as the user would type it, for messages.
    show="kubectl''${context:+ --context $context} -n $namespace"

    if [ -n "''${AGENT_SANDBOX_K8S_DRY_RUN:-}" ]; then
      [ "$secret_data" = "{}" ] || secret_manifest redact
      sandbox_manifest
      echo "would run: $show create -f - (the Sandbox), then exec $sandbox_name -- env -C /workspace $agent ''${*:2}, through flox-agent launch when the environment has it" >&2
      exit 0
    fi

    "$kubectl" "''${ctx[@]}" get namespace "$namespace" -o name >/dev/null 2>&1 ||
      die "namespace $namespace not found''${context:+ in $context}: create it, or name another with the namespace option"
    "$kubectl" "''${ctx[@]}" get crd sandboxes.agents.x-k8s.io -o name >/dev/null 2>&1 ||
      die "agent-sandbox is not installed in the cluster (no Sandbox resource): see https://agent-sandbox.sigs.k8s.io/"

    # Stage /workspace in a temporary folder, and only when all of it
    # arrived replace the project folder's contents with it, deletions
    # included. .git is never copied either way. Returns 0 when copied
    # back; 1 when nothing was copied, the folder unchanged; 2 when the
    # pod is not the session's (replaced, or gone at its ttl), the folder
    # unchanged; 3 when the replace failed part way, the stage kept in
    # $stage.
    stage=""
    copy_workspace_back() {
      local now
      now=$("''${k[@]}" get pod "$sandbox_name" -o jsonpath='{.metadata.uid}' 2>/dev/null) || now=""
      [ -n "$now" ] && [ "$now" = "$pod_uid" ] || return 2
      stage=$(mktemp -d)
      if ! { "''${k[@]}" exec "$sandbox_name" -c agent -- tar -C /workspace -cf - . >"$stage.tar" &&
        tar -C "$stage" -xf "$stage.tar"; }; then
        rm -rf "$stage" "$stage.tar"
        return 1
      fi
      rm -rf "$stage/.git" "$stage.tar"
      find "$here" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + &&
        cp -a "$stage/." "$here/" || return 3
      rm -rf "$stage"
    }

    # Runs once, on any exit: stops the agent, copies back, and deletes
    # the Sandbox (Kubernetes deletes the Secret it owns). Signals are
    # ignored from here, so a second Ctrl-C cannot stop a copy back half
    # way. While the Sandbox holds the only copy it is kept, for its ttl,
    # and how to recover is printed.
    created="" copied_in="" agent_pid="" cleaned="" pod_uid=""
    cleanup() {
      local rc=0
      [ -z "$cleaned" ] || return 0
      cleaned=1
      trap "" INT TERM HUP
      [ -z "$agent_pid" ] || kill "$agent_pid" 2>/dev/null || true
      [ -n "$created" ] || return 0
      if [ "$copy_back" = true ] && [ -n "$copied_in" ]; then
        copy_workspace_back || rc=$?
      fi
      case $rc in
        2)
          echo "agent-sandbox-k8s: the pod of $sandbox_name was replaced or is gone (its ttl may have passed), so its /workspace is not this session's; $here is unchanged" >&2
          ;;
        1 | 3)
          {
            if [ "$rc" = 1 ]; then
              echo "agent-sandbox-k8s: could not copy /workspace back; $here is unchanged."
            else
              echo "agent-sandbox-k8s: could not replace the contents of $here, which may be partly replaced; the sandbox's /workspace is saved in $stage"
            fi
            echo "$sandbox_name is kept until its ttl. To fetch the files, then remove it:"
            echo "  $show exec $sandbox_name -c agent -- tar -C /workspace -cf - . | tar -xf - -C <folder>"
            echo "  $show delete sandbox $sandbox_name"
          } >&2
          return 1
          ;;
      esac
      "''${k[@]}" delete sandbox "$sandbox_name" --wait=false >/dev/null 2>&1 ||
        echo "agent-sandbox-k8s: could not delete $sandbox_name: $show delete sandbox $sandbox_name" >&2
      [ "$rc" = 0 ]
    }
    on_exit() {
      local rc=$?
      cleanup || { [ "$rc" != 0 ] || rc=1; }
      exit "$rc"
    }
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    uid=$(sandbox_manifest | "''${k[@]}" create -f - -o jsonpath='{.metadata.uid}') ||
      die "could not create the Sandbox $sandbox_name in $namespace"
    created=1
    if [ "$secret_data" != "{}" ]; then
      secret_manifest base64 | jq -c --arg uid "$uid" '.metadata.ownerReferences = [{
          apiVersion: "agents.x-k8s.io/v1beta1", kind: "Sandbox",
          name: .metadata.name, uid: $uid, controller: true }]' |
        "''${k[@]}" create -f - >/dev/null ||
        die "could not create the Secret for $sandbox_name"
    fi

    echo "agent-sandbox-k8s: starting $sandbox_name in $namespace with $env_ref (the first pull of an environment on a node can take a few minutes); it is removed at its ttl ($(jq -r .ttl <<<"$opts")), even while in use" >&2
    "''${k[@]}" wait --for=condition=Ready "sandbox/$sandbox_name" --timeout=10m >/dev/null ||
      die "$sandbox_name did not become ready; see: $show describe sandbox $sandbox_name"
    # Copy back only from this pod: one that replaced it has a /workspace
    # without the session's work.
    pod_uid=$("''${k[@]}" get pod "$sandbox_name" -o jsonpath='{.metadata.uid}') && [ -n "$pod_uid" ] ||
      die "cannot read the pod of $sandbox_name"

    if [ "$copy_in" = true ]; then
      "''${k[@]}" exec "$sandbox_name" -c agent -- tar --version >/dev/null 2>&1 ||
        die "$env_ref has no tar, which copying the project folder needs: add gnutar to it, or set copyWorkspace to false"
      # The folder's entries, not the folder: /workspace is an emptyDir the
      # pod's user does not own, so tar may not set its mode or times.
      (cd "$here" && find . -mindepth 1 -maxdepth 1 ! -name .git -print0 |
        tar --null -T - -cf -) |
        "''${k[@]}" exec -i "$sandbox_name" -c agent -- tar -C /workspace -xf - ||
        die "could not copy $here into $sandbox_name"
      copied_in=1
    fi

    # Not exec'd, unlike the other sandboxes: this stays to copy back and
    # clean up. In the background so a signal reaches the trap at once;
    # stdin given explicitly, as a background job would get /dev/null.
    it=-i
    if [ -t 0 ] && [ -t 1 ]; then it=-it; fi
    agent_cmd=("$agent" "''${@:2}")
    if "''${k[@]}" exec "$sandbox_name" -c agent -- flox-agent version >/dev/null 2>&1; then
      agent_cmd=(flox-agent --config-dir /tmp/agent-stacks launch "$agent" -- "''${@:2}")
    fi
    echo "agent-sandbox-k8s: running $agent in $sandbox_name" >&2
    "''${k[@]}" exec "$it" "$sandbox_name" -c agent -- env -C /workspace "''${agent_cmd[@]}" <&0 &
    agent_pid=$!
    status=0
    wait "$agent_pid" || status=$?
    agent_pid=""
    exit "$status"
  '';
}).overrideAttrs (old: {
  meta = (old.meta or { }) // {
    description = "Sandbox that runs the agent in an agent-sandbox pod on Kubernetes";
    license = lib.licenses.mit;
    mainProgram = "agent-sandbox-k8s";
    platforms = lib.platforms.unix;
    # Supports an agent rather than being one. ADR 0014.
    category = "agent-tool";
  };
})
