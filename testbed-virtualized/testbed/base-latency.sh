#!/usr/bin/env bash
# Base latency of the heavy services: the reference the analysis notebook divides their
# latency by (normalized latency). muBench's Configs/RunnerParametersS.json sends 100
# requests to one service at a time (s0, then s1 ... s5, about 5 s apart, so no request
# waits for another), and the "Service delay" panel over that window is exported to
# base_latency_services.csv: columns Time, s0 ... s5, in the layout the notebook reads
# (Grafana's "Download CSV", the same query as export-metrics.py).
#
# Run it right after a test script, on the calm cluster: the scenario's network delay is
# still applied, and DREEM, Cluster Autoscaler and Karpenter are off (the test scripts
# leave them off; it refuses to run otherwise, or while another Runner is sending load).
# It first waits until every service is back at its HPA minimum. About 50 minutes.
#
# In the run folder:
#   base_latency_services.csv          the export (elsewhere with --out)
#   base_latency/window.json           UTC start and end of the load, network delay applied
#   base_latency/Result/               the Runner's result files
#   base_latency/RunnerParametersS.json, logs/base_latency.log, logs/base_latency_runner.log
#
# Usage:
#   ./base-latency.sh --run-dir Result/<scenario>/rep<N> [--out FILE] [--force]
#                     [--export-only] [--no-wait] [--dry-run]
#
#   --out FILE      where the CSV goes. The notebook also looks one folder up, so
#                   Result/<scenario>/base_latency_services.csv serves every repetition
#   --force         replace an earlier base-latency run and its CSV
#   --export-only   export again from base_latency/window.json, without sending load
#                   (within Prometheus's 10 days)
#   --no-wait       start without waiting for the services to be back at their HPA minimum
#   --dry-run       run the checks and show the plan; sends nothing, writes nothing

set -euo pipefail
# shellcheck source=run-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-lib.sh"

RUNNER_S=Configs/RunnerParametersS.json
RESULTS="$MUBENCH/SimulationWorkspace/Result"   # where the Runner writes (OutputPath)
BEFORE_S=60; AFTER_S=120   # export margins: the panel averages over 2 minutes
OUT=""; EXPORT_ONLY=false; WAIT=true; DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)     RUN_DIR="${2:-}"; shift ;;
    --run-dir=*)   RUN_DIR="${1#--run-dir=}" ;;
    --out)         OUT="${2:-}"; shift ;;
    --out=*)       OUT="${1#--out=}" ;;
    --force)       FORCE=true ;;
    --export-only) EXPORT_ONLY=true ;;
    --no-wait)     WAIT=false ;;
    --dry-run)     DRY_RUN=true ;;
    -h|--help)     usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[ -n "$RUN_DIR" ] || die "--run-dir is required (see --help)"
[ -d "$RUN_DIR" ] || die "no folder $RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
BASE_DIR="$RUN_DIR/base_latency"
OUT=${OUT:-$RUN_DIR/base_latency_services.csv}
check_clusters || exit 1

[ "$(jq -r '.OutputPath' "$MUBENCH/$RUNNER_S")" = SimulationWorkspace/Result ] \
  || die "$RUNNER_S must write to SimulationWorkspace/Result (OutputPath)"
mapfile -t FILES < <(jq -r '.RunnerParameters.workload_files_path_list[]' "$MUBENCH/$RUNNER_S")
for f in "${FILES[@]}"; do [ -s "$MUBENCH/$f" ] || die "missing workload file $MUBENCH/$f"; done
SERVICES=$(cd "$MUBENCH" && jq -r '.[].service' "${FILES[@]}" | sort -u | xargs)
DURATION=$( (cd "$MUBENCH" && python3 - "${FILES[@]}" <<'EOF'
import json, sys
files = sys.argv[1:]
print(int(sum(max(e["time"] for e in json.load(open(f))) / 1000 for f in files) + 10 * (len(files) - 1)))
EOF
) )

# --- checks ------------------------------------------------------------------------------

scalers_on() {   # one line per scaler that is on
  local enabled replicas
  enabled=$(workload get configmap forecast-parameters -n "$DREEM_NS" -o jsonpath='{.data.Enabled}' 2>/dev/null || true)
  [ "$enabled" != true ] || echo "DREEM's forecaster is enabled (forecast-parameters Enabled=true)"
  replicas=$(mgmt get deployment cluster-autoscaler -n kube-system -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  [ "${replicas:-0}" = 0 ] || echo "Cluster Autoscaler runs ($replicas replicas)"
  replicas=$(mgmt get deployment karpenter -n kube-system -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  [ "${replicas:-0}" = 0 ] || echo "Karpenter runs ($replicas replicas)"
}

at_hpa_minimum() {   # every service at its HPA minimum, all replicas ready
  local svc min want ready
  for svc in $SERVICES; do
    min=$(workload get hpa "$svc" -n "$APP_NS" -o jsonpath='{.spec.minReplicas}' 2>/dev/null || true)
    read -r want ready <<<"$(workload get deployment "$svc" -n "$APP_NS" -o jsonpath='{.spec.replicas} {.status.readyReplicas}' 2>/dev/null || true)"
    [ -n "$want" ] && [ "$want" = "${min:-$want}" ] && [ "${ready:-0}" = "$want" ] || return 1
  done
}

replicas_now() {   # "s0 2/2 s1 3/2 ...": ready/minimum per service
  local svc
  for svc in $SERVICES; do
    printf '%s %s/%s ' "$svc" \
      "$(workload get deployment "$svc" -n "$APP_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)" \
      "$(workload get hpa "$svc" -n "$APP_NS" -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo -)"
  done
}

network_delay() {   # the delay latency.sh applied, or "none"
  workload get configmap netem-config -n netem -o json 2>/dev/null \
    | jq -r 'if .data.enabled == "true" then .data.delay else "none" end' 2>/dev/null || echo none
}

export_csv() {   # the Service delay panel over base_latency/window.json, s0 ... s5 only
  # written aside, then moved over $OUT: a symlink there (the run folders link a shared
  # file) is replaced, never written through
  python3 - "$TESTBED/export-metrics.py" "$BASE_DIR/window.json" "$OUT.partial" "$WORKLOAD_KUBECONFIG" \
            "$BEFORE_S" "$AFTER_S" $SERVICES <<'EOF'
import csv, importlib.util, io, json, math, statistics, sys
from datetime import datetime, timezone

script, window_file, out, kubeconfig, before, after, *services = sys.argv[1:]
spec = importlib.util.spec_from_file_location("export_metrics", script)
em = importlib.util.module_from_spec(spec)
spec.loader.exec_module(em)

window = json.load(open(window_file))
start, end = (datetime.strptime(window[k], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
              for k in ("start", "end"))
first = math.floor((start - int(before)) / em.STEP_S) * em.STEP_S
last = math.ceil((end + int(after)) / em.STEP_S) * em.STEP_S
prometheus = em.Prometheus(None, kubeconfig, "monitoring", "prometheus-kube-prometheus-prometheus:9090")
oldest = prometheus.oldest_sample_s()
if oldest and first < oldest:
    sys.exit(f"Prometheus only holds data since {em.utc(oldest)} UTC, the load started at {em.utc(start)}")
# the same panel as export-metrics.py; only the services that received the load, since the
# notebook takes every column but Time as a service
panel = next(p for p in em.panels("") if p["file"].startswith("Service delay"))
series = [s for s in prometheus.range(panel["expr"], first, last, em.STEP_S)
          if s["metric"].get("app_name") in services]
text, stats = em.to_csv(series, panel)

rows = list(csv.DictReader(io.StringIO(text)))
values = {s: [float(r[s]) for r in rows if r.get(s) not in (None, "NaN", "undefined")] for s in services}
missing = [s for s in services if not values[s]]
if missing:
    sys.exit(f"no Service delay data for {', '.join(missing)} between {em.utc(first)} and {em.utc(last)} UTC")
open(out, "w").write(text)
print(f"{stats['rows']} rows, {em.utc(first)} -> {em.utc(last)} UTC")
print("median latency per service (ms): "
      + ", ".join(f"{s} {statistics.median(values[s]):.0f} ({len(values[s])} samples)" for s in services))
EOF
  mv -f "$OUT.partial" "$OUT"
  echo "wrote $OUT"
}

# --- export only -------------------------------------------------------------------------

if $EXPORT_ONLY; then
  [ -s "$BASE_DIR/window.json" ] || die "no $BASE_DIR/window.json: run without --export-only first"
  [ ! -e "$OUT" ] || $FORCE || die "$OUT exists: --force to replace it"
  if $DRY_RUN; then echo "would export the Service delay of $SERVICES over $(jq -c . "$BASE_DIR/window.json") to $OUT"; exit 0; fi
  export_csv
  exit 0
fi

# --- run ---------------------------------------------------------------------------------

if [ -e "$BASE_DIR/window.json" ] || [ -e "$OUT" ]; then
  $FORCE || die "$RUN_DIR already holds a base-latency run ($OUT): --force to replace it, --export-only to export it again"
fi
check_python
problems=$(scalers_on)
[ -z "$problems" ] || die "the cluster is not calm: $problems. Switch it off first (the test scripts do at their end)."
! pgrep -f 'Benchmarks/Runner/Runner.py' >/dev/null || die "a muBench Runner is already sending load"
for svc in $SERVICES; do
  [ "$(workload get deployment "$svc" -n "$APP_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)" -ge 1 ] \
    || die "service $svc has no ready replica: deploy the workload first (a test script, or deploy-mubench.sh)"
done
DELAY_NOW=$(network_delay)
run_delay=$(jq -r 'select(.latency_one_way != null) | .latency_one_way' "$RUN_DIR"/run_config_*.json 2>/dev/null | head -1 || true)
if [ -n "$run_delay" ] && [ "$run_delay" != "$DELAY_NOW" ]; then
  echo "WARNING: the runs in $RUN_DIR used a $run_delay delay, the cluster has $DELAY_NOW now"
fi

if $DRY_RUN; then
  cat <<EOF
plan: ${#FILES[@]} workloads from $RUNNER_S to $SERVICES, ~$((DURATION / 60)) min
  network delay now: $DELAY_NOW; scalers: off
  replicas (ready/HPA minimum): $(replicas_now)
  at the HPA minimum: $(at_hpa_minimum && echo yes || echo "no, it would wait (--no-wait to skip)")
  would write $OUT, $BASE_DIR/
EOF
  exit 0
fi

mkdir -p "$RUN_DIR/logs" "$BASE_DIR"
exec > >(tee -a "$RUN_DIR/logs/base_latency.log") 2>&1
log "Base latency: ${#FILES[@]} workloads ($SERVICES), ~$((DURATION / 60)) min, network delay $DELAY_NOW"
echo "results: $OUT"
if $WAIT && ! at_hpa_minimum; then
  echo "waiting for every service to be back at its HPA minimum: $(replicas_now)"
  poll_until 900 at_hpa_minimum || die "services not at their HPA minimum after 15 min: $(replicas_now) (--no-wait to start anyway)"
fi

rm -rf "$RESULTS"; mkdir -p "$RESULTS"   # no result file of an earlier run in the copy below
cp -p "$MUBENCH/$RUNNER_S" "$BASE_DIR/"
echo "Runner: progress on the terminal, saved in $RUN_DIR/logs/base_latency_runner.log"
start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
(cd "$MUBENCH" && "$PYTHON" -u Benchmarks/Runner/Runner.py -c "$RUNNER_S") 2>&1 \
  | tee "$RUN_DIR/logs/base_latency_runner.log" | to_terminal
end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg start "$start" --arg end "$end" --arg delay "$DELAY_NOW" --arg services "$SERVICES" \
      --arg params "$RUNNER_S" \
  '{start: $start, end: $end, runner_parameters: $params, services: ($services | split(" ")),
    network_delay_one_way: $delay}' > "$BASE_DIR/window.json"
rm -rf "$BASE_DIR/Result"
cp -r "$RESULTS" "$BASE_DIR/Result"
log "Load done ($start -> $end), exporting the Service delay"
sleep "$AFTER_S"   # the last requests' 2-minute average must be in Prometheus
export_csv
