#!/usr/bin/env bash
# Cluster Autoscaler arm for ONE repetition of ONE scenario: same flags and same
# result folder as test.sh, so all the arms of a repetition sit side by side.
#
# Same preparation as test.sh (fleet, workload, latency, placement reset, probes).
# The differences are the CA ones: DREEM is switched off; the BMHs stay attached and
# Ironic maintenance stays off, because CA scales through Cluster API and metal3
# (deprovisioning and reprovisioning hosts); while CA runs, the profiles, the node
# map timeline and the latency peer list are refreshed every minute, because a
# reprovisioned node comes back with a new name and often a new IP.
#
# Usage:
#   ./test_CA.sh --rep=1 [--anchors=big|small|any|mixed] [--latency=yes --delay=5ms | --latency=no]
#                [--probe-rate=2] [--repair=yes|no] [--repair-interval=600]
#                [--skip-provision] [--force]
#
# Pass the same --repair as test.sh: the repair changes placement and restarts, so an
# arm run with it cannot be compared with one run without it.
#
# CA is switched off again at the end; the next test.sh restores the fleet.

set -euo pipefail
# shellcheck source=run-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-lib.sh"

parse_args "$@"
check_python
check_clusters || exit 1
[ -z "$ARMS" ] || die "test_CA.sh runs only the CA arm; --arms belongs to test.sh"
guard_arm CA

exec > >(tee -a "$RUN_DIR/logs/test_CA.log") 2>&1
trap cleanup_background EXIT
log "Scenario $TAG, repetition $REP, arm: CA"
echo "results: $RUN_DIR"

log "Disabling DREEM"
forecast_enabled false
workload delete clusterconfiguration -n "$DREEM_NS" --all >/dev/null
dreem_scale 0

if $SKIP_PROVISION; then
  log "Fleet provisioning skipped (--skip-provision)"
else
  provision_fleet ca
fi
ready_fleet
deploy_workload
write_run_config ca CA

wait_workers_ready
uncordon_workers
"$TESTBED/apply-profiles.sh"
apply_latency
reset_placement CA

NODE_MAP_TIMELINE="$RUN_DIR/CA_node_map.jsonl"
: > "$NODE_MAP_TIMELINE"
"$TESTBED/export-mapping.sh" --append "$NODE_MAP_TIMELINE" --run-id CA

# every worker schedulable when the workload starts; done before Cluster Autoscaler is
# enabled, so a drain it has already started is never undone
log "CA: uncordoning the workers before the workload"
uncordon_workers

log "CA: enabling Cluster Autoscaler"
ca_scale 1
mgmt rollout restart deployment cluster-autoscaler -n kube-system >/dev/null

# A reprovisioned node gets a new name and often a new DHCP lease: keep its profile,
# the node map timeline and the latency peer list current for the whole run.
(
  set +e
  while true; do
    sleep 60
    "$TESTBED/apply-profiles.sh" >/dev/null 2>&1
    "$TESTBED/export-mapping.sh" --append "$NODE_MAP_TIMELINE" --run-id CA >/dev/null 2>&1
    if [ "$LATENCY" = yes ]; then "$TESTBED/latency.sh" --refresh-peers >/dev/null 2>&1; fi
  done
) &
EXTRA_PID=$!

start_watcher "$RUN_DIR/CA_pods.jsonl"
start_repair CA
run_workload CA
stop_repair
stop_watcher
kill "$EXTRA_PID" 2>/dev/null || true
EXTRA_PID=""
"$TESTBED/export-mapping.sh" --append "$NODE_MAP_TIMELINE" --run-id CA || true

log "CA: switching Cluster Autoscaler off (the next test.sh restores the fleet)"
ca_scale 0

log "Done: $RUN_DIR"
ls -1 "$RUN_DIR"
cat <<EOF

Still to do for this repetition:
  * export the dashboard data for the CA arm, Node info.csv included - it resolves each
    IP to the host that held it while CA reprovisioned nodes. CSVs already exported for
    the other arms are kept. Prometheus keeps 10 days:
      ./export-metrics.py --run-dir $RUN_DIR
$(base_latency_hint)
EOF
