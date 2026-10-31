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
  kubectl,
}:

(writeShellApplication {
  name = "agent-sandbox-k8s";
  runtimeInputs = [ jq coreutils gnutar ];
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

    if [ -n "''${AGENT_SANDBOX_K8S_DRY_RUN:-}" ]; then
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
