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
  kubectl,
}:

(writeShellApplication {
  name = "agent-sandbox-k8s";
  runtimeInputs = [ jq coreutils gnutar gnused gnugrep ];
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
    dns() { tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'; }
    project=$(basename "$(pwd -P)" | dns)
    suffix=""
    alnum=abcdefghijklmnopqrstuvwxyz0123456789
    for _ in 1 2 3 4 5; do suffix+=''${alnum:RANDOM%36:1}; done
    prefix=$(printf '%s-%s' "$(dns <<<"$agent")" "$project" | cut -c1-57 | sed 's/-*$//')
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
      jq -n --arg n "$sandbox_name" --arg ns "$namespace" --arg agent "$agent" \
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

    if [ -n "''${AGENT_SANDBOX_K8S_DRY_RUN:-}" ]; then
      [ "$secret_data" = "{}" ] || secret_manifest redact
      sandbox_manifest
      echo "would run: $kubectl … -- $*" >&2
      exit 0
    fi
    die "not implemented yet"
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
