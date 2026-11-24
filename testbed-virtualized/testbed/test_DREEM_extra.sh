#!/usr/bin/env bash
# Simplified DREEM arm for ONE repetition of ONE scenario: another baseline for DREEM,
# e.g. random node choice without feasibility checks, or Menouer et al.'s reactive node
# autoscaler (--selectionPolicy=MENOUER). Run it after test.sh with the same flags, like
# test_CA.sh, so its results land in the same folder as the other arms.
#
# WARNING: it deploys these images; the script checks that the registry has them first
# (set DREEM_SIMP_OPERATOR_IMAGE / DREEM_SIMP_FORECAST_IMAGE to run other versions):
#   harbor.ng.crownlabs.polito.it/marco-miracapillo/dreem-k8s-simplified/dreem-operator-simp:0.0.1
#   harbor.ng.crownlabs.polito.it/marco-miracapillo/dreem-k8s-simplified/forecaster-simp:0.0.1
# and with --selectionPolicy=MENOUER these, built from the DREEM-K8s branch
# MENOUER_reimplementation (MENOUER_OPERATOR_IMAGE / MENOUER_FORECAST_IMAGE to override):
#   harbor.ng.crownlabs.polito.it/marco-miracapillo/dreem-k8s-menouer/menouer-operator:0.0.1
#   harbor.ng.crownlabs.polito.it/marco-miracapillo/dreem-k8s-menouer/menouer-forecaster:0.0.1
#
# The simplified DREEM runs as two Deployments of its own next to the original, in
# namespace dreem: dreem-controller-manager-simp and forecast-deployment-simp, copies of
# the original two (service accounts, arguments) with the images above, created with 0
# replicas the first time. The original is found under either name (lib.sh): the
# manifests' dreem-controller-manager / forecast-deployment or the Helm chart's
# dreem-dreem-charts-operator / -forecast. Like Cluster Autoscaler and Karpenter it is
# switched on only for its arm. It shares the operator's leader lease, the ConfigMaps and
# the NodeSelecting objects with the original, so the two never run together: this script
# switches the original off, and every other test script switches the simplified one off.
#
# Its two settings go into ConfigMap cluster-configuration-parameters for the arm:
#   selectionPolicy: "TOPSIS"   # TOPSIS, or RANDOM as a baseline (selectionProfile is then ignored)
#   hardChecks: "true"          # false: scale-downs skip the feasibility checks, in the operator and in the forecaster
# and are put back to TOPSIS / true at the end. The Menouer images ignore selectionPolicy
# (it only records the arm) and read hardChecks in the operator: false is the published
# algorithm, true keeps only the nodes that can be drained. Menouer's parameters go into
# forecast-parameters, which DREEM ignores; the flags set them, the defaults are the paper's:
#   --menouerLoadUp=70           Menouer_load_up             scale up at this load, %
#   --menouerLoadDown=40         Menouer_load_down           scale down below this load, %
#   --menouerPendingSeconds=120  Menouer_pending_pod_seconds scale up for a pod pending this long
#   --menouerPeriod=60           Menouer_period_seconds      seconds between two decisions
# A value other than the paper's is added to the arm's name (MENOUER_nochecks_up65,
# MENOUER_checks_down30_per30, ...), so a sensitivity run never mixes with the published one.
#
# Every call: restores the fleet like test.sh (worker BMHs detached, DREEM powers nodes
# through Redfish), switches the original DREEM off and the simplified one on, deploys the
# workload, and runs the arm exactly like a DREEM arm of test.sh. The arm is named after
# the settings:
#   --selectionPolicy=RANDOM --hardCheck=FALSE                  RANDOM_nochecks
#   --selectionPolicy=RANDOM                                    RANDOM_checks
#   --selectionPolicy=TOPSIS --profile=ENERGY --hardCheck=FALSE TOPSIS_ENERGY_nochecks
#   --selectionPolicy=MENOUER --hardCheck=FALSE                 MENOUER_nochecks (as published)
#   --selectionPolicy=MENOUER                                   MENOUER_checks
#
# Usage:
#   ./test_DREEM_extra.sh --rep=1 --selectionPolicy=TOPSIS|RANDOM|MENOUER [--hardCheck=TRUE|FALSE]
#                         [--profile=ENERGY|QOS] [--menouerLoadUp=70] [--menouerLoadDown=40]
#                         [--menouerPendingSeconds=120] [--menouerPeriod=60] [--anchors=big|small|any|mixed]
#                         [--latency=yes --delay=5ms | --latency=no] [--probe-rate=2]
#                         [--repair=yes|no] [--repair-interval=600] [--seed=N] [--skip-provision] [--force]
#
# Without --seed the arm replays the trace the repetition already recorded (test.sh's --seed).
#
# --hardCheck defaults to TRUE, as in DREEM. --profile is the TOPSIS profile (DREEM's
# selectionProfile) and is required with TOPSIS; RANDOM and MENOUER have none. The
# --menouer* flags only go with --selectionPolicy=MENOUER.

set -euo pipefail
# shellcheck source=run-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-lib.sh"

LEASE=db2bcae8.dreemk8s   # the operator's leader-election lease, the same in every version

# Menouer et al.'s published parameters (FRAME'24 Alg. 1, TPDS'26 Alg. 3)
MENOUER_PAPER_UP=70; MENOUER_PAPER_DOWN=40; MENOUER_PAPER_PENDING=120; MENOUER_PAPER_PERIOD=60
POLICY=""; HARD_CHECK=TRUE; PROFILE=""; ARGS=()
M_UP=""; M_DOWN=""; M_PENDING=""; M_PERIOD=""
for arg in "$@"; do   # this arm's options; the others are shared with the other test scripts
  case "$arg" in
    --selectionPolicy=*)        POLICY="${arg#--selectionPolicy=}" ;;
    --hardCheck=*)              HARD_CHECK="${arg#--hardCheck=}" ;;
    --profile=*)                PROFILE="${arg#--profile=}" ;;
    --menouerLoadUp=*)          M_UP="${arg#--menouerLoadUp=}" ;;
    --menouerLoadDown=*)        M_DOWN="${arg#--menouerLoadDown=}" ;;
    --menouerPendingSeconds=*)  M_PENDING="${arg#--menouerPendingSeconds=}" ;;
    --menouerPeriod=*)          M_PERIOD="${arg#--menouerPeriod=}" ;;
    *)                          ARGS+=("$arg") ;;
  esac
done
parse_args "${ARGS[@]}"
POLICY=${POLICY^^}; HARD_CHECK=${HARD_CHECK,,}; PROFILE=${PROFILE^^}
case "$POLICY" in
  TOPSIS)  case "$PROFILE" in ENERGY|QOS) ;; *) die "--selectionPolicy=TOPSIS needs --profile=ENERGY or --profile=QOS" ;; esac ;;
  RANDOM)  [ -z "$PROFILE" ] || die "--selectionPolicy=RANDOM ignores the profile: drop --profile" ;;
  MENOUER) [ -z "$PROFILE" ] || die "--selectionPolicy=MENOUER has no profile: drop --profile" ;;
  *)       die "--selectionPolicy=TOPSIS, RANDOM or MENOUER is required (see --help)" ;;
esac
case "$HARD_CHECK" in true|false) ;; *) die "--hardCheck must be TRUE or FALSE" ;; esac
ARM="${POLICY}${PROFILE:+_$PROFILE}_$([ "$HARD_CHECK" = true ] && echo checks || echo nochecks)"
if [ "$POLICY" = MENOUER ]; then
  M_UP=${M_UP:-$MENOUER_PAPER_UP}; M_DOWN=${M_DOWN:-$MENOUER_PAPER_DOWN}
  M_PENDING=${M_PENDING:-$MENOUER_PAPER_PENDING}; M_PERIOD=${M_PERIOD:-$MENOUER_PAPER_PERIOD}
  for v in "--menouerLoadUp=$M_UP" "--menouerLoadDown=$M_DOWN" "--menouerPendingSeconds=$M_PENDING" "--menouerPeriod=$M_PERIOD"; do
    [[ "${v#*=}" =~ ^[0-9]+$ ]] || die "$v: a whole number is needed"
  done
  { [ "$M_UP" -le 100 ] && [ "$M_DOWN" -ge 1 ]; } || die "--menouerLoadUp and --menouerLoadDown are percentages: 1 to 100"
  [ "$M_DOWN" -lt "$M_UP" ] || die "--menouerLoadDown=$M_DOWN must be below --menouerLoadUp=$M_UP"
  [ "$M_PERIOD" -ge 1 ] || die "--menouerPeriod must be at least 1 second"
  # values other than the paper's go into the arm's name
  [ "$M_UP" = "$MENOUER_PAPER_UP" ]           || ARM+="_up$M_UP"
  [ "$M_DOWN" = "$MENOUER_PAPER_DOWN" ]       || ARM+="_down$M_DOWN"
  [ "$M_PENDING" = "$MENOUER_PAPER_PENDING" ] || ARM+="_pend$M_PENDING"
  [ "$M_PERIOD" = "$MENOUER_PAPER_PERIOD" ]   || ARM+="_per$M_PERIOD"
elif [ -n "$M_UP$M_DOWN$M_PENDING$M_PERIOD" ]; then
  die "--menouerLoadUp, --menouerLoadDown, --menouerPendingSeconds and --menouerPeriod only go with --selectionPolicy=MENOUER"
fi
if [ "$POLICY" = MENOUER ]; then
  OPERATOR_IMAGE=${MENOUER_OPERATOR_IMAGE:-harbor.ng.crownlabs.polito.it/marco-miracapillo/dreem-k8s-menouer/menouer-operator:0.0.1}
  FORECAST_IMAGE=${MENOUER_FORECAST_IMAGE:-harbor.ng.crownlabs.polito.it/marco-miracapillo/dreem-k8s-menouer/menouer-forecaster:0.0.1}
else
  OPERATOR_IMAGE=${DREEM_SIMP_OPERATOR_IMAGE:-harbor.ng.crownlabs.polito.it/marco-miracapillo/dreem-k8s-simplified/dreem-operator-simp:0.0.1}
  FORECAST_IMAGE=${DREEM_SIMP_FORECAST_IMAGE:-harbor.ng.crownlabs.polito.it/marco-miracapillo/dreem-k8s-simplified/forecaster-simp:0.0.1}
fi

check_python
check_clusters || exit 1
[ -z "$ARMS" ] || die "test_DREEM_extra.sh runs one arm, set by its flags; --arms belongs to test.sh"
guard_arm "$ARM"

# --- the images --------------------------------------------------------------------------

image_in_registry() {   # image: 0 there, 1 the registry does not have it, 2 cannot tell
  local out
  out=$(timeout 60 docker manifest inspect "$1" 2>&1) && return 0
  grep -qiE 'no such manifest|manifest unknown|not found' <<<"$out" && return 1
  return 2
}
for image in "$OPERATOR_IMAGE" "$FORECAST_IMAGE"; do
  rc=0; image_in_registry "$image" || rc=$?
  case "$rc" in
    0) echo "image in the registry: $image" ;;
    1) die "the registry does not have $image: push it, or set DREEM_SIMP_OPERATOR_IMAGE / DREEM_SIMP_FORECAST_IMAGE" \
           "(MENOUER_OPERATOR_IMAGE / MENOUER_FORECAST_IMAGE with --selectionPolicy=MENOUER)" ;;
    *) echo "WARNING: could not check whether the registry has $image (no docker, or no network);" \
            "if it is missing, the rollout below fails" ;;
  esac
done
check_dreem_rbac || exit 1   # the copies run with the original service accounts

# --- the simplified DREEM ------------------------------------------------------------------

copy_deployment() {   # source copy image labels-json: the copy, with 0 replicas
  workload get deployment "$1" -n "$DREEM_NS" -o json | jq --arg name "$2" --arg image "$3" --argjson labels "$4" '
    {apiVersion, kind,
     metadata: {name: $name, namespace: .metadata.namespace, labels: $labels},
     spec: (.spec
            | .replicas = 0
            | .selector = {matchLabels: $labels}
            | .template.metadata.labels = $labels
            | del(.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"])
            | .template.spec.containers[0].image = $image)}' \
    | workload apply -f - >/dev/null
}

install_simp() {   # copies of the original Deployments with the simplified images, 0 replicas
  need_dreem   # DREEM_OPERATOR / DREEM_FORECAST: the installed original, under either name
  # labels of their own: the original Deployments and the metrics Service must not select them
  copy_deployment "$DREEM_OPERATOR" dreem-controller-manager-simp "$OPERATOR_IMAGE" \
    '{"app.kubernetes.io/name": "operators-simp", "control-plane": "controller-manager-simp"}'
  copy_deployment "$DREEM_FORECAST" forecast-deployment-simp "$FORECAST_IMAGE" '{"app": "forecast-simp"}'
}

simp_leads() {   # the simplified operator holds the leader lease
  [[ "$(workload get lease "$LEASE" -n "$DREEM_NS" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)" == dreem-controller-manager-simp-* ]]
}

simp_on() {
  dreem_scale 0   # the original off first: one operator, one forecaster
  dreem_simp_scale 1
  local d
  for d in "${DREEM_SIMP_DEPLOYMENTS[@]}"; do
    workload rollout status deployment "$d" -n "$DREEM_NS" --timeout=5m >/dev/null
  done
  poll_until 180 simp_leads || die "the simplified operator did not take the leader lease $LEASE"
  echo "simplified DREEM running: $(workload get deploy "${DREEM_SIMP_DEPLOYMENTS[@]}" -n "$DREEM_NS" \
         -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image} {end}')"
}

simp_forecast_restart() {   # the forecaster reads its settings when it starts
  workload rollout restart deployment forecast-deployment-simp -n "$DREEM_NS" >/dev/null
  workload rollout status deployment forecast-deployment-simp -n "$DREEM_NS" --timeout=5m >/dev/null
}

set_extra_keys() {   # selectionPolicy hardChecks, in cluster-configuration-parameters
  workload patch configmap cluster-configuration-parameters -n "$DREEM_NS" --type merge \
    -p "$(jq -n --arg p "$1" --arg h "$2" '{data: {selectionPolicy: $p, hardChecks: $h}}')" >/dev/null
}

set_menouer_keys() {   # Algorithm 1 of Menouer et al., with the values of the --menouer* flags
  workload patch configmap forecast-parameters -n "$DREEM_NS" --type merge \
    -p "$(jq -n --arg up "$M_UP" --arg down "$M_DOWN" --arg pending "$M_PENDING" --arg period "$M_PERIOD" \
          '{data: {Menouer_load_up: $up, Menouer_load_down: $down,
                   Menouer_pending_pod_seconds: $pending, Menouer_period_seconds: $period}}')" >/dev/null
}

simp_off() {   # the simplified DREEM off, its settings back to DREEM's defaults
  forecast_enabled false
  dreem_simp_scale 0
  set_extra_keys TOPSIS true
}

on_exit() {
  local rc=$?
  cleanup_background
  if [ "$rc" -ne 0 ]; then
    simp_off || true
    echo "test_DREEM_extra.sh stopped early: the simplified DREEM is off, selectionPolicy/hardChecks back to TOPSIS/true"
  fi
}

# --- run -----------------------------------------------------------------------------------

exec > >(tee -a "$RUN_DIR/logs/test_DREEM_extra.log") 2>&1
trap on_exit EXIT
log "Scenario $TAG, repetition $REP, arm: $ARM (selectionPolicy $POLICY, hardChecks $HARD_CHECK${PROFILE:+, profile $PROFILE}$([ "$POLICY" = MENOUER ] && echo ", load up $M_UP%, load down $M_DOWN%, pending ${M_PENDING}s, period ${M_PERIOD}s"))"
echo "results: $RUN_DIR"

if $SKIP_PROVISION; then
  log "Fleet provisioning skipped (--skip-provision)"
else
  provision_fleet dreem
fi
"$TESTBED/sync-bmc-secrets.sh"
forecast_enabled false
log "Simplified DREEM: $OPERATOR_IMAGE, $FORECAST_IMAGE"
install_simp
set_extra_keys "$POLICY" "$HARD_CHECK"
simp_on
set_forecast_query
ready_fleet
deploy_workload
write_run_config "dreem_extra_$ARM" "$ARM"
jq -n --arg arm "$ARM" --arg policy "$POLICY" --arg checks "$HARD_CHECK" --arg profile "$PROFILE" \
      --arg operator "$OPERATOR_IMAGE" --arg forecaster "$FORECAST_IMAGE" \
      --arg up "$M_UP" --arg down "$M_DOWN" --arg pending "$M_PENDING" --arg period "$M_PERIOD" \
  '{arm: $arm, selectionPolicy: $policy, hardChecks: $checks,
    selectionProfile: (if $profile == "" then null else $profile end),
    menouer: (if $policy == "MENOUER" then {load_up_pct: ($up | tonumber), load_down_pct: ($down | tonumber),
                                             pending_pod_seconds: ($pending | tonumber),
                                             period_seconds: ($period | tonumber)} else null end),
    operator_image: $operator, forecaster_image: $forecaster}' > "$RUN_DIR/deploy/dreem_extra_${ARM}.json"

log "==================== $ARM ===================="
workload delete clusterconfiguration -n "$DREEM_NS" --all >/dev/null
forecast_enabled false
power_on_vms
wait_workers_ready
uncordon_workers
"$TESTBED/apply-profiles.sh"
apply_latency
reset_placement "$ARM"
"$TESTBED/export-mapping.sh" -o "$RUN_DIR/${ARM}_node_map.json" --run-id "$ARM"

# every worker schedulable when the workload starts; done before scaling is enabled,
# so a drain DREEM has already started is never undone
log "$ARM: uncordoning the workers before the workload"
uncordon_workers

log "$ARM: simplified DREEM, selectionPolicy $POLICY, hardChecks $HARD_CHECK, scaling enabled"
case "$POLICY" in
  TOPSIS)  set_selection_profile "$PROFILE" ;;
  MENOUER) set_menouer_keys
           workload get configmap forecast-parameters -n "$DREEM_NS" -o yaml \
             > "$RUN_DIR/deploy/forecast-parameters_${ARM}.yaml" ;;
esac
workload get configmap cluster-configuration-parameters -n "$DREEM_NS" -o yaml \
  > "$RUN_DIR/deploy/cluster-configuration-parameters_${ARM}.yaml"
simp_forecast_restart
forecast_enabled true

start_watcher "$RUN_DIR/${ARM}_pods.jsonl"
start_repair "$ARM"
run_workload "$ARM"
stop_repair
stop_watcher

forecast_enabled false
save_dreem_decisions "$ARM"
log "$ARM: simplified DREEM off, selectionPolicy/hardChecks back to TOPSIS/true (the next test.sh switches the original on)"
simp_off

log "Done: $RUN_DIR"
ls -1 "$RUN_DIR"
cat <<EOF

Still to do for this repetition:
  * export the dashboard data the notebook reads (Prometheus keeps 10 days):
      ./export-metrics.py --run-dir $RUN_DIR
$(base_latency_hint)
EOF
