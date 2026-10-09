#!/usr/bin/env bash
# Shared helpers for the DREEM / baseline / Cluster-Autoscaler testbed.
#
# The control plane must never receive a size label or a consumption profile.
# Identifying it by BMH name does not work: metal3-dev-env names every BMH
# node-N, and CAPM3 puts the cluster.x-k8s.io/control-plane label on the
# Machine, not on the BareMetalHost. We therefore walk the real ownership
# chain: Machine (control-plane label) -> Metal3Machine -> BMH.

set -euo pipefail

# One dedicated variable per cluster. KUBECONFIG is deliberately ignored: a shell that
# exported KUBECONFIG=~/workload.kubeconfig to use kubectl on the workload cluster would
# otherwise send every management call (BMHs, Machines, Cluster Autoscaler) there.
: "${MGMT_KUBECONFIG:=$HOME/.kube/config}"             # metal3 management cluster (minikube)
: "${WORKLOAD_KUBECONFIG:=$HOME/workload.kubeconfig}"   # workload cluster running the tests
: "${METAL3_NS:=metal3}"

mgmt()     { kubectl --kubeconfig="$MGMT_KUBECONFIG" "$@"; }
workload() { kubectl --kubeconfig="$WORKLOAD_KUBECONFIG" "$@"; }

# Fail early when a kubeconfig reaches the wrong cluster: only the management cluster
# serves BareMetalHosts.
check_mgmt_cluster() {
  mgmt get crd baremetalhosts.metal3.io >/dev/null 2>&1 && return 0
  echo "ERROR: MGMT_KUBECONFIG=$MGMT_KUBECONFIG does not reach the metal3 management cluster (no BareMetalHost CRD)" >&2
  return 1
}

check_workload_cluster() {
  if ! workload get nodes >/dev/null 2>&1; then
    echo "ERROR: WORKLOAD_KUBECONFIG=$WORKLOAD_KUBECONFIG does not reach a cluster" >&2
    return 1
  fi
  if workload get crd baremetalhosts.metal3.io >/dev/null 2>&1; then
    echo "ERROR: WORKLOAD_KUBECONFIG=$WORKLOAD_KUBECONFIG reaches the management cluster, not the workload cluster" >&2
    return 1
  fi
}

check_clusters() { check_mgmt_cluster && check_workload_cluster; }

# Prints the control-plane BMH as "namespace/name".
cp_bmh() {
  local cp_machines m3m_names
  cp_machines=$(mgmt get machine -A -o json | jq -r '
    .items[]
    | select(.metadata.labels["cluster.x-k8s.io/control-plane"] != null)
    | .spec.infrastructureRef.name')

  if [ -z "$cp_machines" ]; then
    echo "ERROR: no Machine carries the cluster.x-k8s.io/control-plane label" >&2
    return 1
  fi

  m3m_names=$(printf '%s\n' "$cp_machines" | jq -R . | jq -s .)
  mgmt get m3m -A -o json | jq -r --argjson names "$m3m_names" '
    .items[]
    | select(.metadata.name as $n | $names | index($n))
    | .metadata.annotations["metal3.io/BareMetalHost"]' | sort -u
}

# Prints worker BMHs as "name", sorted, excluding the control-plane BMH.
worker_bmhs() {
  local cp
  cp=$(cp_bmh)
  mgmt get bmh -n "$METAL3_NS" -o json | jq -r --arg cp "$cp" '
    .items[]
    | select("\(.metadata.namespace)/\(.metadata.name)" != $cp)
    | .metadata.name' | sort
}

# Prints the control-plane Node name (empty if the CP BMH has no consumer yet).
cp_node() {
  local cp cp_ns cp_name
  cp=$(cp_bmh); cp_ns=${cp%%/*}; cp_name=${cp##*/}
  mgmt get bmh "$cp_name" -n "$cp_ns" -o jsonpath='{.spec.consumerRef.name}'
}
 