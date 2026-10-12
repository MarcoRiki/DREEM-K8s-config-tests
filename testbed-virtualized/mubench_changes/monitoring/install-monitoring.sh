#!/usr/bin/env bash
# Pins the workload cluster's monitoring stack to the control plane.
#
# The stack itself comes from muBench's own install (README.md, Setup step 4), run
# against the workload cluster:
#
#   Monitoring/kubernetes-full-monitoring/monitoring-install.sh
#                        kube-prometheus-stack (Prometheus, Grafana; NodePorts 30000/30001),
#                        Istio (sidecar injection in namespace default), Jaeger and Kiali
#                        (NodePorts 30002/30003)
#   kubectl apply -f Monitoring/kubernetes-full-monitoring/mub-monitor.yaml
#                        PodMonitor that scrapes the muBench pods (namespace default)
#
# This script only adds what was done by hand after it: Prometheus, Grafana,
# kube-state-metrics and the Prometheus operator get a nodeSelector and a toleration for
# the control plane, so scaling a worker down never interrupts the measurements. It
# waits for them to roll out. Safe to run again.
#
# Usage: ./install-monitoring.sh
# WORKLOAD_KUBECONFIG (default ~/workload.kubeconfig).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${WORKLOAD_KUBECONFIG:-$HOME/workload.kubeconfig}"
PROMETHEUS=prometheus-kube-prometheus-prometheus
DEPLOYMENTS=(prometheus-grafana prometheus-kube-state-metrics prometheus-kube-prometheus-operator)

say() { printf '\n==> %s\n' "$*"; }
kubectl -n monitoring get prometheus "$PROMETHEUS" >/dev/null 2>&1 \
  || { echo "ERROR: no Prometheus $PROMETHEUS in namespace monitoring of $KUBECONFIG: run muBench's monitoring-install.sh first (README.md, Setup step 4)" >&2; exit 1; }

say "monitoring pinned to the control plane"
CP='{"node-role.kubernetes.io/control-plane": ""}'
TOL='[{"key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule"}]'
kubectl -n monitoring patch prometheus "$PROMETHEUS" --type=merge \
  -p "{\"spec\": {\"nodeSelector\": $CP, \"tolerations\": $TOL}}"
for d in "${DEPLOYMENTS[@]}"; do
  kubectl -n monitoring patch deployment "$d" --type=merge \
    -p "{\"spec\": {\"template\": {\"spec\": {\"nodeSelector\": $CP, \"tolerations\": $TOL}}}}"
done
for d in "${DEPLOYMENTS[@]}"; do
  kubectl -n monitoring rollout status deployment "$d" --timeout=10m
done

cat <<EOF

Prometheus: http://<node IP>:30000   Grafana: http://<node IP>:30001 (admin password:
  kubectl -n monitoring get secret prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
Next: $HERE/import-dashboard.sh
EOF
