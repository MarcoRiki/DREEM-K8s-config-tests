#!/usr/bin/env bash
# Monitoring stack and service mesh of the workload cluster, from muBench.
#
# The same steps as muBench's Monitoring/kubernetes-full-monitoring/monitoring-install.sh,
# with the chart versions the experiments ran on pinned (the original installs whatever is
# latest), plus what was done by hand after it:
#
#   kube-prometheus-stack 89.2.2   Prometheus (10-day retention), Grafana 13.2.1,
#                                  node-exporter, kube-state-metrics; NodePorts 30000/30001
#   Istio 1.30.4                   base, istiod (zipkin tracer), ingress gateway;
#                                  sidecar injection in namespace default
#   Jaeger, Kiali 2.31.0           tracing and mesh view; NodePorts 30002/30003
#   mub-monitor                    PodMonitor that scrapes the muBench pods (namespace default)
#   control-plane pinning          Prometheus, Grafana, kube-state-metrics and the operator
#                                  run on the control plane, so scaling a worker down never
#                                  interrupts the measurements
#
# Usage: ./install-monitoring.sh [MUBENCH_DIR]    (default: <repo>/muBench)
# WORKLOAD_KUBECONFIG (default ~/workload.kubeconfig). Safe to run again (helm upgrade --install).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUBENCH="$(cd "${1:-$HERE/../../muBench}" && pwd)"
export KUBECONFIG="${WORKLOAD_KUBECONFIG:-$HOME/workload.kubeconfig}"
PROMETHEUS_CHART=89.2.2
ISTIO_CHART=1.30.4
KIALI_CHART=2.31.0

say() { printf '\n==> %s\n' "$*"; }
cd "$MUBENCH/Monitoring/kubernetes-full-monitoring"

say "Prometheus and Grafana (kube-prometheus-stack $PROMETHEUS_CHART)"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null
helm repo add kiali https://kiali.org/helm-charts >/dev/null
helm repo update >/dev/null
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -n monitoring --version "$PROMETHEUS_CHART"
kubectl apply -n monitoring -f prometheus-nodeport.yaml -f grafana-nodeport.yaml

say "Istio $ISTIO_CHART"
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install istio-base istio/base -n istio-system --version "$ISTIO_CHART"
helm upgrade --install istiod istio/istiod -n istio-system --version "$ISTIO_CHART" \
  --set global.proxy.tracer="zipkin" --wait
helm upgrade --install istio-ingressgateway istio/gateway -n istio-system --version "$ISTIO_CHART"
kubectl label namespace default istio-injection=enabled --overwrite
kubectl apply -f istio-prometheus-operator.yaml

say "Jaeger and Kiali $KIALI_CHART"
kubectl apply -f jaeger.yaml -f jaeger-nodeport.yaml
helm upgrade --install kiali-server kiali/kiali-server -n istio-system --version "$KIALI_CHART" -f kiali-values.yaml
kubectl apply -f kiali-nodeport.yaml

say "muBench PodMonitor"
kubectl apply -n default -f mub-monitor.yaml

say "monitoring pinned to the control plane"
CP='{"node-role.kubernetes.io/control-plane": ""}'
TOL='[{"key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule"}]'
kubectl -n monitoring patch prometheus prometheus-kube-prometheus-prometheus --type=merge \
  -p "{\"spec\": {\"nodeSelector\": $CP, \"tolerations\": $TOL}}"
for d in prometheus-grafana prometheus-kube-state-metrics prometheus-kube-prometheus-operator; do
  kubectl -n monitoring patch deployment "$d" --type=merge \
    -p "{\"spec\": {\"template\": {\"spec\": {\"nodeSelector\": $CP, \"tolerations\": $TOL}}}}"
done
for d in prometheus-grafana prometheus-kube-state-metrics prometheus-kube-prometheus-operator; do
  kubectl -n monitoring rollout status deployment "$d" --timeout=10m
done

cat <<EOF

Prometheus: http://<node IP>:30000   Grafana: http://<node IP>:30001 (admin password:
  kubectl -n monitoring get secret prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
Next: $HERE/import-dashboard.sh
EOF
