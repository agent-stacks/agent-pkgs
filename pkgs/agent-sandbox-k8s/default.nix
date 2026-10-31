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

    if [ -n "''${AGENT_SANDBOX_K8S_DRY_RUN:-}" ]; then
      jq -n --arg e "$env_ref" '{"flox.dev/environment": $e}'
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
