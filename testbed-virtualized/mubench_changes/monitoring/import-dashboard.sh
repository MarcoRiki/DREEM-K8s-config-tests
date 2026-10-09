#!/usr/bin/env bash
# Imports the µBench dashboard (mubench-dashboard.json) into the cluster's Grafana.
#
# The dashboard is a Grafana 13 export in the v2 resource format (dashboard.grafana.app/v2,
# name 6IBeJ-b7k, data source "prometheus"); it is created, or replaced, through Grafana's
# resource API, so it keeps its name and layout.
# Its panels (Service delay, Service rate, N worker, Avg CPU usage, Node CPU usage,
# Pending Application Pods, Node info) are the queries testbed/export-metrics.py exports.
#
# Grafana is reached with a temporary port-forward; the admin credentials are read from
# the prometheus-grafana secret and never printed.
#
# Usage: ./import-dashboard.sh [--dry-run]   (--dry-run: Grafana validates, stores nothing)
# WORKLOAD_KUBECONFIG (default ~/workload.kubeconfig).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD="$HERE/mubench-dashboard.json"
KC="${WORKLOAD_KUBECONFIG:-$HOME/workload.kubeconfig}"
PORT=${GRAFANA_LOCAL_PORT:-38000}
API=/apis/dashboard.grafana.app/v2/namespaces/default/dashboards
QUERY=""
[ "${1:-}" = --dry-run ] && QUERY="?dryRun=All"

k() { kubectl --kubeconfig="$KC" "$@"; }
NAME=$(jq -r '.metadata.name' "$DASHBOARD")
USER_=$(k -n monitoring get secret prometheus-grafana -o jsonpath='{.data.admin-user}' | base64 -d)
PASS_=$(k -n monitoring get secret prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d)

OUT=$(mktemp); BODY=$(mktemp)
k -n monitoring port-forward svc/prometheus-grafana "$PORT:80" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true; rm -f "$OUT" "$BODY"' EXIT
for _ in $(seq 30); do curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null && break; sleep 1; done

grafana() {   # method path [body-file] -> HTTP status, response body in $OUT
  curl -s -o "$OUT" -w '%{http_code}' -u "$USER_:$PASS_" -X "$1" -H 'Content-Type: application/json' \
       ${3:+--data-binary @"$3"} "http://127.0.0.1:$PORT$2"
}

if [ "$(grafana GET "$API/$NAME")" = 200 ]; then
  # replace: the live object's resourceVersion makes it an update
  jq --arg rv "$(jq -r '.metadata.resourceVersion' "$OUT")" '.metadata.resourceVersion = $rv' "$DASHBOARD" > "$BODY"
  code=$(grafana PUT "$API/$NAME$QUERY" "$BODY"); action=replaced
else
  cp "$DASHBOARD" "$BODY"
  code=$(grafana POST "$API$QUERY" "$BODY"); action=created
fi
case "$code" in
  200|201) echo "dashboard $NAME ($(jq -r '.spec.title' "$DASHBOARD")) $action${QUERY:+ (dry run, nothing stored)}" ;;
  *) echo "ERROR: Grafana answered $code: $(head -c 400 "$OUT")" >&2; exit 1 ;;
esac
