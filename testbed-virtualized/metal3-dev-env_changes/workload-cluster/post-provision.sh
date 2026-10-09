#!/usr/bin/env bash
# Base add-ons of the workload cluster, right after metal3-dev-env has provisioned it
# (control plane and 8 workers), with the versions the experiments ran on:
#
#   1. workload kubeconfig: clusterctl get kubeconfig, written to $WORKLOAD_KUBECONFIG
#      if it is missing or does not reach the cluster;
#   2. Calico v3.26.1 (CNI): the nodes stay NotReady until it runs;
#   3. metrics-server v0.9.0, needed by the HorizontalPodAutoscalers of the workload:
#      --kubelet-insecure-tls (kubelet certificates are self-signed) and pinned to the
#      control plane, so scaling a worker down never removes it.
#
# Istio and the monitoring stack come next, from muBench (../../mubench_changes).
#
# Usage: ./post-provision.sh
# MGMT_KUBECONFIG (default ~/.kube/config), WORKLOAD_KUBECONFIG (default ~/workload.kubeconfig),
# CLUSTER_NAME (default test-cluster-m3), METAL3_NS (default metal3).

set -euo pipefail
: "${MGMT_KUBECONFIG:=$HOME/.kube/config}"
: "${WORKLOAD_KUBECONFIG:=$HOME/workload.kubeconfig}"
: "${CLUSTER_NAME:=test-cluster-m3}"
: "${METAL3_NS:=metal3}"
CALICO_URL=https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml
METRICS_SERVER_URL=https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml

workload() { kubectl --kubeconfig="$WORKLOAD_KUBECONFIG" "$@"; }
say() { printf '\n==> %s\n' "$*"; }

say "1/3 workload kubeconfig"
if [ -s "$WORKLOAD_KUBECONFIG" ] && workload get nodes >/dev/null 2>&1; then
  echo "using $WORKLOAD_KUBECONFIG"
else
  clusterctl get kubeconfig "$CLUSTER_NAME" -n "$METAL3_NS" --kubeconfig "$MGMT_KUBECONFIG" > "$WORKLOAD_KUBECONFIG"
  chmod 600 "$WORKLOAD_KUBECONFIG"
  workload get nodes >/dev/null
  echo "wrote $WORKLOAD_KUBECONFIG"
fi

say "2/3 Calico v3.26.1"
workload apply -f "$CALICO_URL" >/dev/null
workload -n kube-system rollout status daemonset calico-node --timeout=15m
workload wait --for=condition=Ready nodes --all --timeout=15m

say "3/3 metrics-server v0.9.0"
workload apply -f "$METRICS_SERVER_URL" >/dev/null
if ! workload -n kube-system get deployment metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' \
     | grep -q -- --kubelet-insecure-tls; then
  workload -n kube-system patch deployment metrics-server --type=json \
    -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]' >/dev/null
fi
workload -n kube-system patch deployment metrics-server --type=merge -p '{
  "spec": {"template": {"spec": {
    "nodeSelector": {"node-role.kubernetes.io/control-plane": ""},
    "tolerations": [{"key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule"}]
  }}}}' >/dev/null
workload -n kube-system rollout status deployment metrics-server --timeout=5m
workload get nodes
