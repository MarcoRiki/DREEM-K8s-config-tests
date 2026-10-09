#!/usr/bin/env bash
# Karpenter arm for ONE repetition of ONE scenario. Run it after test.sh with the same
# flags, like test_CA.sh, so its results land in the same folder as the other arms.
# Karpenter must be installed, with its controller off: see ../Karpenter/README.md.
#
# Karpenter only removes nodes it created, so the fleet is split in two:
#   base       the base MachineDeployment keeps BASE workers on fixed hosts, never removed.
#              BASE is Cluster Autoscaler's min size (3, also DREEM's minNodes). The hosts
#              come from profiles.json: one per group, both sizes, mean consumption profile
#              closest to the fleet's, ties broken by name; --base-hosts picks them by hand.
#   Karpenter  a MachineDeployment of its own, from 0 to the other hosts (NodePool limit).
#
# Every call:
#   1. restores the fleet like test_CA.sh (DREEM, Cluster Autoscaler and Karpenter off,
#      worker BMHs attached and registered, every worker on), then shrinks the base
#      MachineDeployment to the base hosts;
#   2. warm start: Karpenter adds one node per remaining host (one placeholder pod each,
#      ../Karpenter/warmup.yaml), so the arm starts with every worker on, like the others;
#      the controller then stays off until the workload starts, like Cluster Autoscaler;
#   3. deploys the workload, re-applies the profiles, sets the latency, resets the
#      placement; every minute it re-applies the profiles, refreshes the latency peers and
#      appends a node-map and a NodeClaim snapshot (KARPENTER_node_map.jsonl,
#      KARPENTER_nodeclaims.jsonl);
#   4. switches the controller on and runs the workload with the probes. The controller
#      restarts its consolidation timers when it starts: no node goes in the first
#      consolidateAfter (10 min), as with Cluster Autoscaler;
#   5. saves the controller log, the NodeClaims and Karpenter's events, removes Karpenter's
#      nodes, switches it off and deletes its MachineDeployment. The next test.sh restores
#      the fleet.
#
# Usage:
#   ./test_Karpenter.sh --rep=1 [--anchors=big|small|any|mixed] [--latency=yes --delay=5ms | --latency=no]
#                       [--probe-rate=2] [--repair=yes|no] [--repair-interval=600]
#                       [--base-hosts=<bmh>,<bmh>,<bmh>] [--skip-provision] [--force]
#
# --skip-provision keeps the fleet as it is: the worker BMHs must be attached (so not right
# after a DREEM run) and the base hosts must be workers of the base MachineDeployment.

set -euo pipefail
# shellcheck source=run-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-lib.sh"

ARM=KARPENTER
BASE_HOSTS_ARG=""; ARGS=()
for arg in "$@"; do
  case "$arg" in
    --base-hosts=*) BASE_HOSTS_ARG="${arg#--base-hosts=}" ;;
    *)              ARGS+=("$arg") ;;
  esac
done
parse_args "${ARGS[@]}"
check_python
check_clusters || exit 1
[ -z "$ARMS" ] || die "test_Karpenter.sh runs only the Karpenter arm; --arms belongs to test.sh"
[ -n "$KARPENTER_DIR" ] || die "no Karpenter folder at $TESTBED/../Karpenter"
karpenter_installed || die "Karpenter's controller is not in the management cluster: see $KARPENTER_DIR/README.md"
workload get nodepool metal3 >/dev/null 2>&1 || die "no NodePool metal3 in the workload cluster: see $KARPENTER_DIR/README.md"
guard_arm "$ARM"

# --- base hosts --------------------------------------------------------------------------

# the floor every arm shares: Cluster Autoscaler's min size (DREEM's minNodes is the same)
BASE_WORKERS=$(mgmt get machinedeployment "$MD_NAME" -n "$METAL3_NS" \
                 -o jsonpath='{.metadata.annotations.cluster\.x-k8s\.io/cluster-api-autoscaler-node-group-min-size}')
BASE_WORKERS=${BASE_WORKERS:-3}
KARPENTER_NODES=$((EXPECTED_WORKERS - BASE_WORKERS))
[ "$KARPENTER_NODES" -gt 0 ] || die "no host left for Karpenter: $EXPECTED_WORKERS workers, base $BASE_WORKERS"

base_hosts() {   # [bmh,bmh,...]: those, checked against profiles.json, or the ones chosen from it
  python3 - "$TESTBED/profiles.json" "$BASE_WORKERS" "${1:-}" <<'EOF'
import itertools, json, re, sys
hosts = json.load(open(sys.argv[1]))["assignments"]
k, wanted = int(sys.argv[2]), [h for h in sys.argv[3].split(",") if h]
if wanted:
    if len(set(wanted)) != k or any(h not in hosts for h in wanted):
        sys.exit(f"--base-hosts needs {k} distinct worker BMHs of profiles.json: {', '.join(sorted(hosts))}")
    print(" ".join(wanted))
    sys.exit()
natural = lambda name: [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", name)]
mean = sum(h["consumption_profile"] for h in hosts.values()) / len(hosts)
groups = len({h["group"] for h in hosts.values()})
sizes = len({h["size"] for h in hosts.values()})
# one host per group and both sizes, as far as k allows
candidates = [c for c in itertools.combinations(sorted(hosts, key=natural), k)
              if len({hosts[h]["group"] for h in c}) == min(k, groups)
              and len({hosts[h]["size"] for h in c}) == min(k, sizes)]
if not candidates:
    sys.exit("no set of base hosts has distinct groups and both sizes")
print(" ".join(min(candidates, key=lambda c: (abs(sum(hosts[h]["consumption_profile"] for h in c) / k - mean),
                                             [natural(h) for h in c]))))
EOF
}

describe_hosts() {   # bmh...: their size, group and profile, and their mean profile
  python3 - "$TESTBED/profiles.json" "$@" <<'EOF'
import json, sys
hosts, chosen = json.load(open(sys.argv[1]))["assignments"], sys.argv[2:]
fleet = sum(h["consumption_profile"] for h in hosts.values()) / len(hosts)
mean = sum(hosts[h]["consumption_profile"] for h in chosen) / len(chosen) if chosen else float("nan")
print(", ".join(f"{h} ({hosts[h]['size']} {hosts[h]['group']} {hosts[h]['consumption_profile']})" for h in chosen)
      + f"; mean profile {mean:.0f}, fleet {fleet:.0f}")
EOF
}

BASE_LINE=$(base_hosts "$BASE_HOSTS_ARG") || die "cannot choose the base hosts"
read -ra BASE_HOSTS <<<"$BASE_LINE"

# --- fleet ---------------------------------------------------------------------------------

workers_attached() {   # no worker BMH detached from Metal3 (DREEM detaches them)
  local workers
  mapfile -t workers < <(worker_bmhs)
  mgmt get bmh "${workers[@]}" -n "$METAL3_NS" -o json \
    | jq -e '[.items[] | select(.status.operationalStatus == "detached")] | length == 0' >/dev/null
}

base_machines() {   # "machine bmh deleting" for every Machine of the base MachineDeployment
  { mgmt get machines -n "$METAL3_NS" -l "cluster.x-k8s.io/deployment-name=$MD_NAME" -o json
    mgmt get bmh -n "$METAL3_NS" -o json; } | jq -rs '
    .[0] as $machines | .[1] as $bmhs
    | ($bmhs.items | map(select(.spec.consumerRef.name != null)
                         | {key: .spec.consumerRef.name, value: .metadata.name}) | from_entries) as $host
    | $machines.items[]
    | "\(.metadata.name) \($host[.spec.infrastructureRef.name] // "-") \(.metadata.deletionTimestamp != null)"'
}

base_md_settled() {   # only the base hosts left in the base MachineDeployment, all ready
  local hosts ready
  hosts=$(base_machines | awk '{print $2}' | sort | xargs)
  ready=$(mgmt get machinedeployment "$MD_NAME" -n "$METAL3_NS" -o jsonpath='{.status.readyReplicas}')
  [ "$hosts" = "$(printf '%s\n' "${BASE_HOSTS[@]}" | sort | xargs)" ] && [ "${ready:-0}" -eq "$BASE_WORKERS" ]
}

free_hosts() {   # BMHs Metal3 can give to a new Machine
  mgmt get bmh -n "$METAL3_NS" -o json | jq '[.items[] | select(.status.provisioning.state == "available"
    and .spec.consumerRef == null and (.status.operationalStatus // "") != "detached")] | length'
}
hosts_available() { [ "$(free_hosts)" -ge "$1" ]; }

shrink_base_md() {   # the base MachineDeployment down to the base hosts; the others free
  local list machine host deleting h victims=() kept=() missing=()
  list=$(base_machines) || die "cannot list the Machines of $MD_NAME"
  while read -r machine host deleting; do
    [ -n "$machine" ] && [ "$deleting" = false ] || continue
    if [[ " ${BASE_HOSTS[*]} " == *" $host "* ]]; then kept+=("$host"); else victims+=("$machine"); fi
  done <<<"$list"
  for h in "${BASE_HOSTS[@]}"; do
    [[ " ${kept[*]} " == *" $h "* ]] || missing+=("$h")
  done
  [ "${#missing[@]}" -eq 0 ] \
    || die "base host(s) ${missing[*]} not workers of $MD_NAME: run without --skip-provision, which brings every worker back"
  log "Base: $MD_NAME down to $BASE_WORKERS workers"
  # Cluster API deletes the Machines marked delete-machine first
  if [ "${#victims[@]}" -gt 0 ]; then
    mgmt annotate machine "${victims[@]}" -n "$METAL3_NS" cluster.x-k8s.io/delete-machine=yes --overwrite >/dev/null
  fi
  mgmt scale machinedeployment "$MD_NAME" -n "$METAL3_NS" --replicas="$BASE_WORKERS" >/dev/null
  poll_until 1800 base_md_settled || die "$MD_NAME not down to ${BASE_HOSTS[*]} after 1800s"
  poll_until 1200 hosts_available "$KARPENTER_NODES" || die "fewer than $KARPENTER_NODES hosts available after 1200s"
  echo "$MD_NAME on ${BASE_HOSTS[*]}; $(free_hosts) hosts available"
}

# --- Karpenter -----------------------------------------------------------------------------

check_nodepool_limit() {   # the NodePool stops Karpenter at the hosts the base leaves free
  local limit want
  limit=$(workload get nodepool metal3 -o jsonpath='{.spec.limits.cpu}')
  want=$((KARPENTER_NODES * $(jq '.cores_per_node' "$TESTBED/profiles.json")))
  [ "$limit" = "$want" ] \
    || die "NodePool metal3 allows ${limit:-unlimited} CPUs, the $KARPENTER_NODES free hosts have $want: fix limits.cpu in $KARPENTER_DIR/nodepool.yaml"
}

nodeclaim_stages() {   # "created launched registered initialized"
  workload get nodeclaims -o json | jq -r '
    def with($c): [.items[] | select(any(.status.conditions[]?; .type == $c and .status == "True"))] | length;
    "\(.items | length) \(with("Launched")) \(with("Registered")) \(with("Initialized"))"'
}

warmup_running() {
  workload get pods -n karpenter-warmup -l app=karpenter-warmup --field-selector=status.phase=Running \
    -o name 2>/dev/null | grep -c . || true
}

WARM_HOSTS=(); WARM_START_S=""
warm_start() {   # one Karpenter node per free host, then the controller off
  local start=$SECONDS stages created launched registered initialized running progress last=""
  log "Karpenter: warm start, $KARPENTER_NODES nodes with one placeholder pod each"
  workload apply -f "$KARPENTER_DIR/warmup.yaml" >/dev/null
  workload scale deployment karpenter-warmup -n karpenter-warmup --replicas="$KARPENTER_NODES" >/dev/null
  karpenter_scale 1
  # a NodeClaim not registered within 15 min is replaced by Karpenter: 30 min leave room for one retry
  while :; do
    stages=$(nodeclaim_stages 2>/dev/null) || stages=""
    read -r created launched registered initialized <<<"${stages:-0 0 0 0}"
    running=$(warmup_running)
    progress="$created NodeClaims: $launched launched, $registered registered, $initialized initialized; $running/$KARPENTER_NODES placeholder pods running"
    if [ "$progress" != "$last" ]; then echo "  +$((SECONDS - start))s  $progress"; last=$progress; fi
    [ "$initialized" -ge "$KARPENTER_NODES" ] && [ "$running" -ge "$KARPENTER_NODES" ] && break
    [ "$((SECONDS - start))" -lt 1800 ] || die "warm start not done after 1800s: $progress"
    sleep 15
  done
  WARM_START_S=$((SECONDS - start))
  read -ra WARM_HOSTS <<<"$(workload get nodeclaims -o json \
    | jq -r '[.items[].status.providerID // "" | split("/") | .[3] // empty] | sort | join(" ")')"
  echo "Karpenter's nodes up after ${WARM_START_S}s, on $(describe_hosts "${WARM_HOSTS[@]}")"
  # the controller's log lives as long as its pod
  mgmt logs -n kube-system deploy/karpenter --timestamps > "$RUN_DIR/logs/${ARM}_controller_warmstart.log" 2>&1 || true
  log "Karpenter: controller off until the workload starts, as Cluster Autoscaler"
  karpenter_scale 0
  workload delete namespace karpenter-warmup --timeout=180s >/dev/null \
    || echo "WARNING: namespace karpenter-warmup not deleted yet"
}

record_karpenter_config() {   # what the arm ran with, next to the workload in deploy/
  local dir="$RUN_DIR/deploy/karpenter" image pool
  mkdir -p "$dir"
  workload get nodepool metal3 -o yaml > "$dir/nodepool.yaml"
  workload get clusterapinodeclass metal3 -o yaml > "$dir/nodeclass.yaml"
  mgmt get machinedeployment "$KARPENTER_MD" -n "$METAL3_NS" -o yaml > "$dir/machinedeployment.yaml"
  image=$(mgmt get deployment karpenter -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}')
  pool=$(workload get nodepool metal3 -o json | jq '{limits: .spec.limits, disruption: .spec.disruption}')
  jq -n --arg image "$image" --arg md "$KARPENTER_MD" --argjson pool "$pool" \
        --argjson max "$KARPENTER_NODES" --argjson warm_s "$WARM_START_S" \
        --argjson base "$(printf '%s\n' "${BASE_HOSTS[@]}" | jq -R . | jq -s .)" \
        --argjson warm "$(printf '%s\n' "${WARM_HOSTS[@]}" | jq -R . | jq -s .)" \
        --slurpfile profiles "$TESTBED/profiles.json" '
    $profiles[0].assignments as $a
    | {controller_image: $image, machinedeployment: $md, nodepool: $pool, karpenter_nodes_max: $max,
       base_hosts: [$base[] | {bmh: ., size: $a[.].size, group: $a[.].group, consumption_profile: $a[.].consumption_profile}],
       base_mean_profile: ([$base[] | $a[.].consumption_profile] | add / length),
       fleet_mean_profile: ([$a[].consumption_profile] | add / length),
       warm_start: {seconds: $warm_s, hosts: $warm}}' > "$dir/karpenter.json"
  echo "Karpenter's configuration recorded in $dir"
}

snapshot_nodeclaims() {   # one JSON line: Karpenter's NodeClaims, their node, host and conditions
  workload get nodeclaims -o json | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
    ts: $ts,
    nodeclaims: [.items[] | {
      name: .metadata.name,
      created: .metadata.creationTimestamp,
      deleting: (.metadata.deletionTimestamp // null),
      node: (.status.nodeName // null),
      bmh: ((.status.providerID // "") | split("/") | .[3] // null),
      last_pod_event: (.status.lastPodEventTime // null),
      conditions: ([.status.conditions[]? | {(.type): {status, reason, since: .lastTransitionTime}}] | add // {})
    }]}'
}

save_karpenter_record() {   # the controller's log lives only as long as its pod
  local pod restarts
  pod=$(mgmt get pods -n kube-system -l app=karpenter -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$pod" ]; then
    mgmt logs -n kube-system "$pod" --timestamps > "$RUN_DIR/logs/${ARM}_controller.log" 2>&1 || true
    restarts=$(mgmt get pod "$pod" -n kube-system -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)
    if [ "${restarts:-0}" -gt 0 ]; then
      echo "WARNING: Karpenter's controller restarted $restarts time(s) during the arm"
      mgmt logs -n kube-system "$pod" --previous --timestamps > "$RUN_DIR/logs/${ARM}_controller.previous.log" 2>&1 || true
    fi
  fi
  workload get nodeclaims -o json > "$RUN_DIR/${ARM}_nodeclaims_end.json" 2>/dev/null || true
  # events last an hour: only the end of the arm; the controller log holds all of it
  workload get events -A -o json 2>/dev/null \
    | jq '[.items[] | select(.source.component == "karpenter" or .reportingComponent == "karpenter")]' \
    > "$RUN_DIR/${ARM}_events.json" || true
  echo "Karpenter: logs/${ARM}_controller.log, ${ARM}_nodeclaims.jsonl, ${ARM}_nodeclaims_end.json, ${ARM}_events.json"
}

on_exit() {
  local rc=$?
  cleanup_background
  if [ "$rc" -ne 0 ] && karpenter_installed; then
    karpenter_scale 0 || true
    cat <<EOF
test_Karpenter.sh stopped early: Karpenter's controller is off. Its nodes stay until the next
test.sh, test_CA.sh or test_Karpenter.sh removes them, or now with:
  bash -c 'source $TESTBED/run-lib.sh; karpenter_off'
EOF
  fi
}

# --- run -----------------------------------------------------------------------------------

exec > >(tee -a "$RUN_DIR/logs/test_Karpenter.log") 2>&1
trap on_exit EXIT
log "Scenario $TAG, repetition $REP, arm: $ARM"
echo "results: $RUN_DIR"
echo "base: $(describe_hosts "${BASE_HOSTS[@]}"); Karpenter: up to $KARPENTER_NODES nodes"

log "Disabling DREEM"
forecast_enabled false
workload delete clusterconfiguration -n "$DREEM_NS" --all >/dev/null
dreem_scale 0

if $SKIP_PROVISION; then
  log "Fleet provisioning skipped (--skip-provision); Cluster Autoscaler and Karpenter off"
  ca_scale 0
  karpenter_off
  workers_attached || die "worker BMHs detached (DREEM mode): run without --skip-provision"
else
  provision_fleet ca   # switches Karpenter off and removes what an earlier run left
fi
shrink_base_md

log "Karpenter: MachineDeployment $KARPENTER_MD, NodePool metal3"
workload apply -f "$KARPENTER_DIR/nodepool.yaml" >/dev/null
check_nodepool_limit
MD_NAME="$MD_NAME" MD_NAMESPACE="$METAL3_NS" "$KARPENTER_DIR/machinedeployment.sh" create
warm_start
wait_workers_ready
uncordon_workers
"$TESTBED/apply-profiles.sh"

deploy_workload
write_run_config karpenter "$ARM"
record_karpenter_config

wait_workers_ready
uncordon_workers
"$TESTBED/apply-profiles.sh"
apply_latency
reset_placement "$ARM"
NODE_MAP_TIMELINE="$RUN_DIR/${ARM}_node_map.jsonl"
NODECLAIM_TIMELINE="$RUN_DIR/${ARM}_nodeclaims.jsonl"
: > "$NODE_MAP_TIMELINE"
: > "$NODECLAIM_TIMELINE"
"$TESTBED/export-mapping.sh" --append "$NODE_MAP_TIMELINE" --run-id "$ARM"
snapshot_nodeclaims >> "$NODECLAIM_TIMELINE" || echo "WARNING: no NodeClaim snapshot"

# every worker schedulable when the workload starts, before Karpenter can act
log "$ARM: uncordoning the workers before the workload"
uncordon_workers

log "$ARM: enabling Karpenter"
karpenter_scale 1
# Karpenter's nodes are new machines with new names and addresses: profiles, node map,
# NodeClaims and latency peers refreshed every minute, as for Cluster Autoscaler
( set +e; while true; do sleep 60
    "$TESTBED/apply-profiles.sh" >/dev/null 2>&1
    "$TESTBED/export-mapping.sh" --append "$NODE_MAP_TIMELINE" --run-id "$ARM" >/dev/null 2>&1
    snapshot_nodeclaims >> "$NODECLAIM_TIMELINE" 2>/dev/null
    if [ "$LATENCY" = yes ]; then "$TESTBED/latency.sh" --refresh-peers >/dev/null 2>&1; fi
  done ) &
EXTRA_PID=$!

start_watcher "$RUN_DIR/${ARM}_pods.jsonl"
start_repair "$ARM"
run_workload "$ARM"
stop_repair
stop_watcher
kill "$EXTRA_PID" 2>/dev/null || true
EXTRA_PID=""
"$TESTBED/export-mapping.sh" --append "$NODE_MAP_TIMELINE" --run-id "$ARM" || true
snapshot_nodeclaims >> "$NODECLAIM_TIMELINE" || true

save_karpenter_record
log "$ARM: removing Karpenter's nodes and switching it off (the next test.sh restores the fleet)"
karpenter_off

log "Done: $RUN_DIR"
ls -1 "$RUN_DIR"
cat <<EOF

Still to do for this repetition:
  * export the dashboard data the notebook reads (Prometheus keeps 10 days):
      ./export-metrics.py --run-dir $RUN_DIR
$(base_latency_hint)
EOF
