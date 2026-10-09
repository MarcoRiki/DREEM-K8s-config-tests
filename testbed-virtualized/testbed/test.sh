#!/usr/bin/env bash
# DREEM arms (ENERGY, QOS) and the no-scaling BASELINE for ONE repetition of ONE
# scenario. Run test_CA.sh and test_Karpenter.sh afterwards with the same flags to add
# the Cluster Autoscaler and Karpenter arms to the same folder.
#
# Every call:
#   1. restores the fleet, also after a Cluster Autoscaler run deprovisioned nodes:
#      CA off, worker BMHs attached and registered in Ironic again, MachineDeployment
#      back to all workers, profiles and groups re-applied; then the worker BMHs are
#      detached, which removes their Ironic records (one that survives goes into
#      maintenance), because DREEM powers nodes through Redfish behind metal3's back.
#      DREEM's BMC secrets are rebuilt for the current node names.
#   2. deploys the workload: heavy services, anchors and probes (deploy-mubench.sh)
#   3. per arm: powers every VM on, uncordons, re-applies the profiles, sets and
#      verifies the latency between workers, resets the pod placement, runs the
#      workload with the probe traffic, and saves everything in
#      Result/anchors-<a>_delay-<d>/rep<N>/
#
# Usage:
#   ./test.sh --rep=1 [--arms="ENERGY QOS BASELINE BASELINE_N"] [--nodes=6 [--remove=big|small]]
#             [--anchors=big|small|any|mixed] [--latency=yes --delay=5ms | --latency=no]
#             [--probe-rate=2] [--repair=yes|no] [--repair-interval=600]
#             [--skip-provision] [--force]
#
# BASELINE_N is BASELINE on fewer workers: --nodes=N of them stay on, the others are
# switched off for that arm (cordoned, drained, powered off) before the placement reset,
# as many big as small. When an odd number goes, --remove=big or --remove=small says
# which size loses one more. The hosts come from profiles.json (baseline_n_hosts in
# run-lib.sh), so a given N always switches off the same ones, and the arm is named
# after the choice:
#   --nodes=6                  BASELINE_6         one big and one small off
#   --nodes=7 --remove=big     BASELINE_7_big     one big off
#   --nodes=5 --remove=small   BASELINE_5_small   one big and two small off
# The next arm powers them on again; after the last arm they stay off, like the nodes
# DREEM switches off. <arm>_switched_off.json records which hosts were off.
#
# --repair=yes brings a probe back to its anchor's node while the workload runs
# (repair-pairs.py): preferred affinity is only checked at scheduling, so without it a
# pair split by a drain stays split. Those runs land in a separate ...\_repair folder and
# must not be compared with runs made without it; use the same value for every arm.
#
# Alternate the order of --arms between repetitions. An arm already in the folder is
# never overwritten unless --force is given. DREEM must already run the image with
# cordon + drain, and the script refuses to start if its service account may not
# cordon and drain; the images in use are recorded in run_config_dreem.json.
#
# Clusters: MGMT_KUBECONFIG (default ~/.kube/config) and WORKLOAD_KUBECONFIG (default
# ~/workload.kubeconfig). The shell's KUBECONFIG is ignored.

set -euo pipefail
# shellcheck source=run-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-lib.sh"

ARMS="ENERGY QOS BASELINE"
NODES=""; REMOVE=""; ARGS=()
for arg in "$@"; do   # BASELINE_N's options; the others are shared with test_CA.sh and test_Karpenter.sh
  case "$arg" in
    --nodes=*)  NODES="${arg#--nodes=}" ;;
    --remove=*) REMOVE="${arg#--remove=}" ;;
    *)          ARGS+=("$arg") ;;
  esac
done
parse_args "${ARGS[@]}"
check_python
check_clusters || exit 1

# BASELINE_N becomes BASELINE_<nodes>[_<size>], with the hosts it switches off
BASELINE_N_ARM=""; BASELINE_N_HOSTS=()
if [[ " $ARMS " == *" BASELINE_N "* ]]; then
  [[ "$NODES" =~ ^[0-9]+$ ]] || die "BASELINE_N needs --nodes=<number of workers that stay on>"
  HOSTS_LINE=$(baseline_n_hosts "$NODES" "$REMOVE") || die "BASELINE_N: cannot choose the workers to switch off"
  read -ra BASELINE_N_HOSTS <<<"$HOSTS_LINE"
  if [ $(((EXPECTED_WORKERS - NODES) % 2)) -eq 0 ]; then
    [ -z "$REMOVE" ] || die "--nodes=$NODES switches off as many big as small workers: --remove is for an odd number"
    BASELINE_N_ARM="BASELINE_$NODES"
  else
    BASELINE_N_ARM="BASELINE_${NODES}_$REMOVE"
  fi
  ARMS=$(for a in $ARMS; do if [ "$a" = BASELINE_N ]; then echo "$BASELINE_N_ARM"; else echo "$a"; fi; done | xargs)
elif [ -n "$NODES$REMOVE" ]; then
  die "--nodes and --remove belong to the BASELINE_N arm: add it to --arms"
fi

for ARM in $ARMS; do
  case "$ARM" in
    ENERGY|QOS|BASELINE|"$BASELINE_N_ARM") ;;
    *) die "unknown arm '$ARM' (ENERGY, QOS, BASELINE or BASELINE_N; CA is test_CA.sh, KARPENTER test_Karpenter.sh)" ;;
  esac
  guard_arm "$ARM"
done
case " $ARMS " in
  *" ENERGY "*|*" QOS "*) check_dreem_rbac || exit 1 ;;
esac

exec > >(tee -a "$RUN_DIR/logs/test.log") 2>&1
trap cleanup_background EXIT
log "Scenario $TAG, repetition $REP, arms: $ARMS"
echo "results: $RUN_DIR"
[ -z "$BASELINE_N_ARM" ] || echo "$BASELINE_N_ARM switches off: ${BASELINE_N_HOSTS[*]}"

if $SKIP_PROVISION; then
  log "Fleet provisioning skipped (--skip-provision)"
else
  provision_fleet dreem
fi
"$TESTBED/sync-bmc-secrets.sh"
dreem_scale 1
forecast_enabled false
set_forecast_query
ready_fleet
deploy_workload
# shellcheck disable=SC2086
write_run_config dreem $ARMS

for ARM in $ARMS; do
  log "==================== $ARM ===================="
  HELD_OFF=()
  workload delete clusterconfiguration -n "$DREEM_NS" --all >/dev/null
  forecast_enabled false
  power_on_vms
  wait_workers_ready
  uncordon_workers
  "$TESTBED/apply-profiles.sh"
  if [ "$ARM" = "$BASELINE_N_ARM" ]; then
    switch_off_hosts "$ARM" "${BASELINE_N_HOSTS[@]}"   # they stay cordoned and off for the arm
  fi
  apply_latency
  reset_placement "$ARM"
  "$TESTBED/export-mapping.sh" -o "$RUN_DIR/${ARM}_node_map.json" --run-id "$ARM"

  # every worker schedulable when the workload starts; done before scaling is enabled,
  # so a drain DREEM has already started is never undone
  log "$ARM: uncordoning the workers before the workload"
  uncordon_workers

  case "$ARM" in
    ENERGY|QOS)
      log "$ARM: DREEM selection profile $ARM, scaling enabled"
      set_selection_profile "$ARM"
      forecast_restart
      forecast_enabled true
      ;;
    *)
      log "$ARM: scaling stays disabled, $((EXPECTED_WORKERS - ${#HELD_OFF[@]})) workers on"
      ;;
  esac

  start_watcher "$RUN_DIR/${ARM}_pods.jsonl"
  start_repair "$ARM"
  run_workload "$ARM"
  stop_repair
  stop_watcher

  case "$ARM" in
    ENERGY|QOS)
      forecast_enabled false
      save_dreem_decisions "$ARM"
      ;;
  esac
done
[ "${#HELD_OFF[@]}" -eq 0 ] || echo "${HELD_OFF[*]} stay off after the last arm; the next test script powers them on"

log "Done: $RUN_DIR"
ls -1 "$RUN_DIR"
cat <<EOF

Still to do for this repetition:
  * export the dashboard data the notebook reads (Prometheus keeps 10 days):
      ./export-metrics.py --run-dir $RUN_DIR
$(base_latency_hint)
  * add the Cluster Autoscaler and Karpenter arms:
      ./test_CA.sh --rep=$REP --anchors=$ANCHORS --latency=$LATENCY$([ "$LATENCY" = yes ] && echo " --delay=$DELAY") --repair=$REPAIR$([ "$REPAIR" = yes ] && echo " --repair-interval=$REPAIR_INTERVAL")
      ./test_Karpenter.sh --rep=$REP --anchors=$ANCHORS --latency=$LATENCY$([ "$LATENCY" = yes ] && echo " --delay=$DELAY") --repair=$REPAIR$([ "$REPAIR" = yes ] && echo " --repair-interval=$REPAIR_INTERVAL")
EOF

# ./test_CA.sh --rep=$REP --anchors=$ANCHORS --latency=$LATENCY$([ "$LATENCY" = yes ] && echo " --delay=$DELAY") --repair=$REPAIR$([ "$REPAIR" = yes ] && echo " --repair-interval=$REPAIR_INTERVAL")
