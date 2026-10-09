#!/usr/bin/env bash
# Creates or deletes the MachineDeployment Karpenter scales, in the management cluster.
#
# Karpenter needs a MachineDeployment of its own: when it needs a node it first claims the
# existing Machines of its MachineDeployment that it does not own yet, and only adds
# replicas for the rest. On the shared MachineDeployment it would adopt running workers
# instead of creating nodes. This one is a copy of the existing worker MachineDeployment
# (same bootstrap and Metal3 templates, so new nodes still get size and group at join),
# with:
#   - 0 replicas, a selector and template labels of its own (nodepool: nodepool-karpenter);
#   - the label node.cluster.x-k8s.io/karpenter-member, which makes it visible to Karpenter;
#   - the scale-from-zero annotations describing the node to Karpenter: CPU, memory, disk
#     and pods read from a running worker, plus the labels Karpenter needs on a node before
#     it can consolidate it (instance type, zone, capacity type);
#   - no Cluster Autoscaler min/max annotations, so CA never adopts it.
#
# Usage:
#   ./machinedeployment.sh create [--dry-run]   # --dry-run: server-side validation only
#   ./machinedeployment.sh delete               # deletes it and its Machines
#   ./machinedeployment.sh render               # prints it without creating it
#   ./machinedeployment.sh show
#
# MGMT_KUBECONFIG (default ~/.kube/config), WORKLOAD_KUBECONFIG (default
# ~/workload.kubeconfig), MD_NAME (default test-cluster-m3), MD_NAMESPACE (default metal3).

set -euo pipefail

: "${MGMT_KUBECONFIG:=$HOME/.kube/config}"
: "${WORKLOAD_KUBECONFIG:=$HOME/workload.kubeconfig}"
: "${MD_NAME:=test-cluster-m3}"
: "${MD_NAMESPACE:=metal3}"
KARPENTER_MD="${MD_NAME}-karpenter"
POOL_LABEL=nodepool-karpenter

mgmt()     { kubectl --kubeconfig="$MGMT_KUBECONFIG" "$@"; }
workload() { kubectl --kubeconfig="$WORKLOAD_KUBECONFIG" "$@"; }
usage()    { awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; }

render() {   # the Karpenter MachineDeployment, as JSON, from the base one
  local worker
  # capacity of a running worker (control plane excluded): what Karpenter plans with
  worker=$(workload get nodes -l '!node-role.kubernetes.io/control-plane' -o json \
           | jq -c '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))][0].status.allocatable')
  [ -n "$worker" ] && [ "$worker" != null ] || { echo "no Ready worker to read the node size from" >&2; exit 1; }

  mgmt get machinedeployment "$MD_NAME" -n "$MD_NAMESPACE" -o json | python3 -c '
import json, sys
base, alloc, name, pool = json.load(sys.stdin), json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
cluster = base["spec"]["clusterName"]
labels = {"cluster.x-k8s.io/cluster-name": cluster, "nodepool": pool}
md = {
    "apiVersion": base["apiVersion"],
    "kind": "MachineDeployment",
    "metadata": {
        "name": name,
        "namespace": base["metadata"]["namespace"],
        "labels": {**labels, "node.cluster.x-k8s.io/karpenter-member": ""},
        "annotations": {
            "capacity.cluster-autoscaler.kubernetes.io/cpu": alloc["cpu"],
            "capacity.cluster-autoscaler.kubernetes.io/memory": alloc["memory"],
            "capacity.cluster-autoscaler.kubernetes.io/ephemeral-disk": alloc["ephemeral-storage"],
            "capacity.cluster-autoscaler.kubernetes.io/maxPods": alloc["pods"],
            "capacity.cluster-autoscaler.kubernetes.io/labels": ",".join([
                "kubernetes.io/arch=amd64",
                "karpenter.sh/capacity-type=on-demand",
                "node.kubernetes.io/instance-type=metal3-worker",
                "topology.kubernetes.io/zone=testbed",
            ]),
        },
    },
    "spec": {
        "clusterName": cluster,
        "replicas": 0,
        "selector": {"matchLabels": labels},
        "template": {
            "metadata": {"labels": labels},   # never the karpenter-member label: that marks a Machine as claimed
            "spec": base["spec"]["template"]["spec"],
        },
    },
}
if "rollout" in base["spec"]:
    md["spec"]["rollout"] = base["spec"]["rollout"]
print(json.dumps(md, indent=1))
' "$worker" "$KARPENTER_MD" "$POOL_LABEL"
}

case "${1:-}" in
  create)
    if [ "${2:-}" = --dry-run ]; then
      render | mgmt apply --dry-run=server -f -
    elif mgmt get machinedeployment "$KARPENTER_MD" -n "$MD_NAMESPACE" >/dev/null 2>&1; then
      echo "$KARPENTER_MD already exists"
    else
      render | mgmt create -f -
    fi
    ;;
  delete)
    replicas=$(mgmt get machinedeployment "$KARPENTER_MD" -n "$MD_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
    [ -n "$replicas" ] || { echo "$KARPENTER_MD does not exist"; exit 0; }
    [ "$replicas" = 0 ] || echo "WARNING: $KARPENTER_MD still has $replicas replicas: delete the NodePool first, so Karpenter drains its nodes"
    mgmt delete machinedeployment "$KARPENTER_MD" -n "$MD_NAMESPACE"
    ;;
  render)
    render
    ;;
  show)
    mgmt get machinedeployment "$KARPENTER_MD" -n "$MD_NAMESPACE" -o yaml
    # claimed = carries the karpenter-member label (its value is empty, hence jq)
    mgmt get machines -n "$MD_NAMESPACE" -l "nodepool=$POOL_LABEL" -o json | jq -r '
      ["MACHINE", "NODE", "CLAIMED"],
      (.items[] | [.metadata.name, (.status.nodeRef.name // "-"),
                   (if .metadata.labels | has("node.cluster.x-k8s.io/karpenter-member") then "yes" else "no" end)])
      | @tsv' | column -t
    ;;
  -h|--help|"") usage ;;
  *) echo "unknown command: $1 (see --help)" >&2; exit 1 ;;
esac
