#!/usr/bin/env bash
# Sets up the testbed after installing the environment from scratch (metal3-dev-env), so
# every install ends up with the same configuration. Safe to run again.
#
# Run it once the workload cluster exists (control plane and workers provisioned):
#   1. workload kubeconfig: written with clusterctl when $WORKLOAD_KUBECONFIG is missing
#   2. profiles.json: the fleet is described as ordered slots (size, consumption profile,
#      group); gen-profiles.py assigns them to the worker BMHs sorted by name, so it does
#      not matter which BMH became the control plane. A file that already matches the
#      live workers is kept as it is.
#   3. BMH annotations: assign-profiles.sh writes size, consumption profile and group
#   4. labels at join: for every MachineDeployment the worker data template copies the
#      BMH annotations dreemk8s.io/size and dreemk8s.io/group into the host metadata, and
#      kubelet registers every new node with size and group already set. A data template
#      cannot be modified, so a copy named <template>-labels is created and the machine
#      template pointed at it. Nothing is reprovisioned: existing workers keep their
#      template and get their labels in step 5.
#   5. nodes: apply-profiles.sh labels the existing workers and resets the power-cycle
#      counter; sync-bmc-secrets.sh writes DREEM's BMC secrets if DREEM is installed
#
# It covers the testbed's own configuration only: Calico, Istio, monitoring and the DREEM
# operator are installed separately.
#
# Usage:
#   ./init-testbed.sh [--dry-run] [--regenerate-profiles] [--skip-templates]
#
#   --dry-run              change nothing, show what would be done
#   --regenerate-profiles  reassign the slots to the live workers even though profiles.json
#                          exists - needed when a reinstall moved the control plane or
#                          renamed the hosts. It changes which host has which profile:
#                          never do it between the arms of one comparison.
#   --skip-templates       leave the Cluster API templates untouched

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
export MGMT_KUBECONFIG WORKLOAD_KUBECONFIG

PROFILES="$HERE/profiles.json"
LABEL_KEYS='group={{ ds.meta_data.group }},size={{ ds.meta_data.size }}'

DRY_RUN=false; REGENERATE=false; SKIP_TEMPLATES=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)             DRY_RUN=true ;;
    --regenerate-profiles) REGENERATE=true ;;
    --skip-templates)      SKIP_TEMPLATES=true ;;
    -h|--help)             awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 1 ;;
  esac
done
DRY=(); DRY_SERVER=(); DRY_TAG=""
if $DRY_RUN; then DRY=(--dry-run); DRY_SERVER=(--dry-run=server); DRY_TAG="[dry-run] "; fi

say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# --- 1. workload kubeconfig ----------------------------------------------------------

check_mgmt_cluster || exit 1

say "1/5 Workload cluster kubeconfig"
if [ -s "$WORKLOAD_KUBECONFIG" ] && workload get nodes >/dev/null 2>&1; then
  echo "using $WORKLOAD_KUBECONFIG"
else
  CLUSTER=$(mgmt get cluster -n "$METAL3_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$CLUSTER" ] || die "no Cluster in namespace $METAL3_NS: provision the cluster first"
  if $DRY_RUN; then
    echo "[dry-run] would write $WORKLOAD_KUBECONFIG with: clusterctl get kubeconfig $CLUSTER -n $METAL3_NS"
  else
    clusterctl get kubeconfig "$CLUSTER" -n "$METAL3_NS" --kubeconfig "$MGMT_KUBECONFIG" > "$WORKLOAD_KUBECONFIG"
    workload get nodes >/dev/null || die "the kubeconfig written to $WORKLOAD_KUBECONFIG does not reach the cluster"
    echo "wrote $WORKLOAD_KUBECONFIG (cluster $CLUSTER)"
  fi
fi
if [ -s "$WORKLOAD_KUBECONFIG" ]; then check_workload_cluster || exit 1; fi

# --- 2. profiles.json ----------------------------------------------------------------

say "2/5 Fleet profiles (profiles.json)"
CP="$(cp_bmh)"
mapfile -t WORKERS < <(worker_bmhs)
[ "${#WORKERS[@]}" -gt 0 ] || die "no worker BMH found in namespace $METAL3_NS"
echo "control-plane BMH: $CP"
echo "worker BMHs:       ${WORKERS[*]}"
GEN=(python3 "$HERE/gen-profiles.py" --profiles "$PROFILES" --workers "${WORKERS[@]}")
if [ -f "$PROFILES" ] && ! $REGENERATE; then
  if "${GEN[@]}" --check; then
    echo "profiles.json already matches these workers: kept"
    "${GEN[@]}" --summary
  else
    die "profiles.json assigns other BMHs (differences above). If a reinstall moved the control plane or renamed the hosts, run again with --regenerate-profiles to reassign the slots to the live workers."
  fi
elif $DRY_RUN; then
  echo "[dry-run] would write profiles.json with:"
  "${GEN[@]}" --summary
else
  if [ -f "$PROFILES" ]; then cp -p "$PROFILES" "$PROFILES.bak-$(date +%Y%m%d%H%M%S)"; fi
  "${GEN[@]}" --write
fi

# --- 3. BMH annotations --------------------------------------------------------------

say "3/5 BMH annotations: size, consumption profile, group"
if $DRY_RUN; then
  "$HERE/assign-profiles.sh" --dry-run || echo "(the dry run reads the current profiles.json, which was not rewritten)"
else
  "$HERE/assign-profiles.sh"
fi

# --- 4. labels at join ---------------------------------------------------------------

has_bmh_labels() {   # data template JSON on stdin: does it copy group and size from the BMH?
  jq -e '[.spec.metaData.fromAnnotations[]? | select(.object == "baremetalhost") | .key] as $keys
         | ($keys | index("group")) != null and ($keys | index("size")) != null' >/dev/null
}

configure_machine_deployment() {   # MachineDeployment name in $METAL3_NS
  local md=$1 ns=$METAL3_NS kct m3mt dt new manifest kct_json current value patch api gen_before gen_after
  local args_path=/spec/template/spec/joinConfiguration/nodeRegistration/kubeletExtraArgs
  if [ "$(mgmt get md "$md" -n "$ns" -o jsonpath='{.spec.template.spec.infrastructureRef.kind}')" != Metal3MachineTemplate ]; then
    echo "MachineDeployment $md: not backed by a Metal3MachineTemplate, skipped"
    return 0
  fi
  gen_before=$(mgmt get md "$md" -n "$ns" -o jsonpath='{.metadata.generation}')
  kct=$(mgmt get md "$md" -n "$ns" -o jsonpath='{.spec.template.spec.bootstrap.configRef.name}')
  m3mt=$(mgmt get md "$md" -n "$ns" -o jsonpath='{.spec.template.spec.infrastructureRef.name}')
  dt=$(mgmt get metal3machinetemplate "$m3mt" -n "$ns" -o jsonpath='{.spec.template.spec.dataTemplate.name}')
  echo "MachineDeployment $md: bootstrap $kct, machine template $m3mt, data template $dt"

  # data template: copy size and group from the BMH into the host metadata
  if mgmt get metal3datatemplate "$dt" -n "$ns" -o json | has_bmh_labels; then
    echo "  data template $dt already copies size/group from the BMH"
  else
    new="$dt-labels"
    if mgmt get metal3datatemplate "$new" -n "$ns" >/dev/null 2>&1; then
      echo "  data template $new already exists"
    else
      manifest=$(mgmt get metal3datatemplate "$dt" -n "$ns" -o json | jq --arg n "$new" '{
        apiVersion, kind,
        metadata: {name: $n, namespace: .metadata.namespace,
                   labels: (.metadata.labels // {}), ownerReferences: (.metadata.ownerReferences // [])},
        spec: (.spec | .metaData.fromAnnotations = (
                 ((.metaData.fromAnnotations // []) | map(select(.key != "group" and .key != "size")))
                 + [{key: "group", object: "baremetalhost", annotation: "dreemk8s.io/group"},
                    {key: "size",  object: "baremetalhost", annotation: "dreemk8s.io/size"}]))}')
      mgmt create "${DRY_SERVER[@]}" -f - <<<"$manifest" >/dev/null
      echo "  ${DRY_TAG}created data template $new (copy of $dt that also copies size/group from the BMH)"
    fi
    mgmt patch metal3machinetemplate "$m3mt" -n "$ns" --type merge "${DRY_SERVER[@]}" \
      -p "$(jq -n --arg n "$new" '{spec: {template: {spec: {dataTemplate: {name: $n}}}}}')" >/dev/null
    echo "  ${DRY_TAG}machine template $m3mt now uses $new"
  fi

  # bootstrap template: kubelet registers the node with size and group
  kct_json=$(mgmt get kubeadmconfigtemplate "$kct" -n "$ns" -o json)
  current=$(jq -r '.spec.template.spec.joinConfiguration.nodeRegistration.kubeletExtraArgs
                   | if type == "array" then (map(select(.name == "node-labels")) | first | .value // "")
                     elif type == "object" then (.["node-labels"] // "")
                     else "" end' <<<"$kct_json")
  if [[ "$current" == *"ds.meta_data.group"* && "$current" == *"ds.meta_data.size"* ]]; then
    echo "  kubelet node-labels already include size/group: $current"
  else
    value="${current:+$current,}$LABEL_KEYS"
    case "$(jq -r '.spec.template.spec.joinConfiguration.nodeRegistration.kubeletExtraArgs | type' <<<"$kct_json")" in
      array)
        local idx
        idx=$(jq '.spec.template.spec.joinConfiguration.nodeRegistration.kubeletExtraArgs | map(.name) | index("node-labels")' <<<"$kct_json")
        if [ "$idx" = null ]; then
          patch=$(jq -n --arg p "$args_path/-" --arg v "$value" '[{op: "add", path: $p, value: {name: "node-labels", value: $v}}]')
        else
          patch=$(jq -n --arg p "$args_path/$idx/value" --arg v "$value" '[{op: "replace", path: $p, value: $v}]')
        fi ;;
      object)
        patch=$(jq -n --arg p "$args_path/node-labels" --arg v "$value" '[{op: "add", path: $p, value: $v}]') ;;
      *)
        api=$(jq -r '.apiVersion' <<<"$kct_json")
        if [[ "$api" == */v1beta1 ]]; then
          patch=$(jq -n --arg p "$args_path" --arg v "$value" '[{op: "add", path: $p, value: {"node-labels": $v}}]')
        else
          patch=$(jq -n --arg p "$args_path" --arg v "$value" '[{op: "add", path: $p, value: [{name: "node-labels", value: $v}]}]')
        fi ;;
    esac
    mgmt patch kubeadmconfigtemplate "$kct" -n "$ns" --type json "${DRY_SERVER[@]}" -p "$patch" >/dev/null
    echo "  ${DRY_TAG}kubelet node-labels in $kct: $value"
  fi

  if ! $DRY_RUN; then
    sleep 5
    gen_after=$(mgmt get md "$md" -n "$ns" -o jsonpath='{.metadata.generation}')
    if [ "$gen_after" = "$gen_before" ]; then
      echo "  no rollout: MachineDeployment generation still $gen_after"
    else
      echo "  WARNING: MachineDeployment generation changed $gen_before -> $gen_after, check the machines"
    fi
  fi
}

say "4/5 Labels at join (Cluster API worker templates)"
if $SKIP_TEMPLATES; then
  echo "skipped (--skip-templates)"
else
  mapfile -t MDS < <(mgmt get machinedeployment -n "$METAL3_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [ "${#MDS[@]}" -eq 0 ]; then
    echo "no MachineDeployment in $METAL3_NS yet: provision the workers, then run this script again"
  fi
  for md in "${MDS[@]}"; do
    configure_machine_deployment "$md"
  done
fi

# --- 5. nodes and DREEM secrets ------------------------------------------------------

say "5/5 Worker nodes and DREEM BMC secrets"
if ! "$HERE/apply-profiles.sh" "${DRY[@]}"; then
  $DRY_RUN || exit 1
  echo "(the dry run reads the current profiles.json, which was not rewritten)"
fi
if workload get namespace dreem >/dev/null 2>&1; then
  "$HERE/sync-bmc-secrets.sh" "${DRY[@]}"
else
  echo "namespace dreem not found in the workload cluster: after installing DREEM run ./sync-bmc-secrets.sh"
fi

# --- summary -------------------------------------------------------------------------

if ! $DRY_RUN; then
  say "Summary"
  printf '%-8s %-30s %-6s %-8s %-6s %s\n' BMH NODE SIZE PROFILE GROUP "NODE LABELS size/group"
  mgmt get bmh -n "$METAL3_NS" -o json | jq -r '.items[] | [.metadata.name, (.spec.consumerRef.name // "-"),
      (.metadata.annotations["dreemk8s.io/size"] // "-"), (.metadata.annotations["dreemk8s.io/consumption-profile"] // "-"),
      (.metadata.annotations["dreemk8s.io/group"] // "-")] | @tsv' \
  | while IFS=$'\t' read -r bmh node size profile group; do
      if [ "$METAL3_NS/$bmh" = "$CP" ]; then labels="(control plane)"
      else labels=$(workload get node "$node" -o jsonpath='{.metadata.labels.size}/{.metadata.labels.group}' 2>/dev/null || echo "-"); fi
      printf '%-8s %-30s %-6s %-8s %-6s %s\n' "$bmh" "$node" "$size" "$profile" "$group" "$labels"
    done
fi
echo
echo "done."
