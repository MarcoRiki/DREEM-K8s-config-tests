#!/usr/bin/env bash
# Steps shared by test.sh (DREEM ENERGY/QOS and BASELINE), test_CA.sh (Cluster
# Autoscaler) and test_Karpenter.sh (Karpenter), so every arm prepares the fleet, the
# workload, the network and the result folder in exactly the same way. Sourced by those
# scripts, not run directly.

TESTBED="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$TESTBED/lib.sh"
export MGMT_KUBECONFIG WORKLOAD_KUBECONFIG
MUBENCH="$(cd "$TESTBED/../muBench" && pwd)"
# muBench's Runner needs the environment muBench was installed into (no need to activate it)
PYTHON=${PYTHON:-$MUBENCH/.venv/bin/python3}

MD_NAME=${MD_NAME:-test-cluster-m3}
DREEM_NS=dreem
APP_NS=$(jq -r '.K8sParameters.namespace' "$MUBENCH/Configs/K8sParameters.json")
RUNNER_PARAMS="$MUBENCH/Configs/RunnerParameters.json"
EXPECTED_WORKERS=$(jq '.assignments | length' "$TESTBED/profiles.json")
# DREEM's forecaster must see the application traffic only: without the filter the
# probes, and the ten calls each probe request makes to its anchor, would dominate
# the request rate it scales on.
HEAVY_RATE_QUERY='sum(rate(mub_request_processing_latency_milliseconds_count{app_name=~"s[0-9]+"}[2m]))'

REP=""; ARMS=""; ANCHORS=big; LATENCY=yes; DELAY=5ms; PROBE_RATE=2
REPAIR=no; REPAIR_INTERVAL=600
FORCE=false; SKIP_PROVISION=false
TAG=""; RUN_DIR=""; WORKMODEL=""
HEAVY=(); ANCHOR=(); PROBE=()
WATCHER_PID=""; EXTRA_PID=""; REPAIR_PID=""; PROBE_PIDS=()
HELD_OFF=()   # workers switched off for the current arm (BASELINE_N): kept cordoned

log()   { printf '\n[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
to_terminal() {   # stdin to the terminal only, not to the run log; discarded when there is no terminal
  if { : >/dev/tty; } 2>/dev/null; then cat >/dev/tty; else cat >/dev/null; fi
}
die()   { echo "ERROR: $*" >&2; exit 1; }
check_python() {
  [ -x "$PYTHON" ] || die "no Python at $PYTHON: create muBench's .venv or set PYTHON=/path/to/python3"
  "$PYTHON" -c 'import argcomplete, requests' 2>/dev/null \
    || die "$PYTHON lacks the muBench Runner dependencies (argcomplete, requests)"
}
usage() { awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; }

# --- arguments and result folder -----------------------------------------------------

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --rep=*)          REP="${arg#--rep=}" ;;
      --arms=*)         ARMS="${arg#--arms=}" ;;
      --anchors=*)      ANCHORS="${arg#--anchors=}" ;;
      --latency=*)      LATENCY="${arg#--latency=}" ;;
      --delay=*)        DELAY="${arg#--delay=}" ;;
      --probe-rate=*)   PROBE_RATE="${arg#--probe-rate=}" ;;
      --repair=*)       REPAIR="${arg#--repair=}" ;;
      --repair-interval=*) REPAIR_INTERVAL="${arg#--repair-interval=}" ;;
      --skip-provision) SKIP_PROVISION=true ;;
      --force)          FORCE=true ;;
      -h|--help)        usage; exit 0 ;;
      *) die "unknown argument: $arg (see --help)" ;;
    esac
  done
  [[ "$REP" =~ ^[0-9]+$ ]] || die "--rep=<number> is required (see --help)"
  case "$ANCHORS" in big|small|any|mixed) ;; *) die "--anchors must be big, small, any or mixed" ;; esac
  case "$LATENCY" in yes|no) ;; *) die "--latency must be yes or no" ;; esac
  [[ "$PROBE_RATE" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--probe-rate must be a number of requests/s"
  case "$REPAIR" in yes|no) ;; *) die "--repair must be yes or no" ;; esac
  [[ "$REPAIR_INTERVAL" =~ ^[0-9]+$ ]] || die "--repair-interval must be a number of seconds"
  if [ "$LATENCY" = yes ]; then
    [[ "$DELAY" =~ ^[0-9]+([.][0-9]+)?(us|ms|s)?$ ]] || die "invalid --delay: $DELAY"
    [[ "$DELAY" =~ (us|ms|s)$ ]] || DELAY="${DELAY}ms"
    TAG="anchors-${ANCHORS}_delay-${DELAY}"
  else
    TAG="anchors-${ANCHORS}_delay-none"
  fi
  # the repair changes placement, restarts and latency: its runs get their own folder,
  # so they are never mixed with the runs that let a split pair stay split
  [ "$REPAIR" = yes ] && TAG="${TAG}_repair"
  RUN_DIR="$TESTBED/Result/$TAG/rep$REP"
  mkdir -p "$RUN_DIR/logs" "$RUN_DIR/runner"
}

guard_arm() {   # arm: refuse to overwrite a finished arm unless --force
  [ -e "$RUN_DIR/${1}_window.json" ] || return 0
  $FORCE || die "$RUN_DIR already holds a $1 run: use another --rep, or --force to replace it"
  # [!0-9]: replacing BASELINE must leave BASELINE_6_* (another arm) alone
  rm -rf "$RUN_DIR/${1}"_[!0-9]*
}

write_run_config() {   # name arm...
  local name=$1; shift
  jq -n --arg tag "$TAG" --arg rep "$REP" --arg arms "$*" --arg anchors "$ANCHORS" \
        --arg latency "$LATENCY" --arg delay "$DELAY" --arg rate "$PROBE_RATE" \
        --arg repair "$REPAIR" --arg repair_interval "$REPAIR_INTERVAL" \
        --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson images "$(workload get deploy -n "$DREEM_NS" -o json \
                             | jq '[.items[] | {(.metadata.name): .spec.template.spec.containers[0].image}] | add // {}')" \
        '{tag: $tag, rep: ($rep | tonumber), arms: ($arms | split(" ")), anchors: $anchors,
          latency_one_way: (if $latency == "yes" then $delay else null end),
          probe_rate_per_s: ($rate | tonumber),
          pair_repair_every_s: (if $repair == "yes" then ($repair_interval | tonumber) else null end),
          dreem_images: $images, started: $started}' \
        > "$RUN_DIR/run_config_${name}.json"
  cp "$TESTBED/profiles.json" "$RUN_DIR/profiles.json"
}

# --- fleet ---------------------------------------------------------------------------

ca_scale()    { mgmt scale deployment cluster-autoscaler -n kube-system --replicas="$1" >/dev/null; }
dreem_scale() { workload scale deployment forecast-deployment dreem-controller-manager -n "$DREEM_NS" --replicas="$1" >/dev/null; }

forecast_enabled() {   # true|false
  workload patch configmap forecast-parameters -n "$DREEM_NS" --type merge \
    -p "{\"data\": {\"Enabled\": \"$1\"}}" >/dev/null
}

forecast_restart() {
  workload rollout restart deployment forecast-deployment -n "$DREEM_NS" >/dev/null
  workload rollout status deployment forecast-deployment -n "$DREEM_NS" --timeout=5m >/dev/null
}

set_forecast_query() {
  local current
  current=$(workload get configmap forecast-parameters -n "$DREEM_NS" -o jsonpath='{.data.Request_rate_query}')
  [ "$current" = "$HEAVY_RATE_QUERY" ] && return 0
  workload patch configmap forecast-parameters -n "$DREEM_NS" --type merge \
    -p "$(jq -n --arg q "$HEAVY_RATE_QUERY" '{data: {Request_rate_query: $q}}')" >/dev/null
  echo "forecast request-rate query restricted to the heavy services: $HEAVY_RATE_QUERY"
}

check_dreem_rbac() {   # DREEM cordons (patch nodes) and drains (Eviction API) before powering a node off
  local sa missing=()
  [ "${DREEM_RBAC_CHECK:-yes}" = no ] && { echo "DREEM RBAC check skipped (DREEM_RBAC_CHECK=no)"; return 0; }
  sa=$(workload get deployment dreem-controller-manager -n "$DREEM_NS" -o jsonpath='{.spec.template.spec.serviceAccountName}')
  sa="system:serviceaccount:$DREEM_NS:${sa:-default}"
  workload auth can-i patch nodes --as="$sa" >/dev/null 2>&1 || missing+=("patch nodes (cordon, uncordon)")
  # a subresource needs --subresource: "pods/eviction" alone is read as the pod named "eviction"
  workload auth can-i create pods --subresource=eviction -n "$APP_NS" --as="$sa" >/dev/null 2>&1 \
    || missing+=("create pods/eviction in namespace $APP_NS (drain)")
  [ "${#missing[@]}" -eq 0 ] && return 0
  echo "ERROR: DREEM's service account $sa may not:" >&2
  printf '         %s\n' "${missing[@]}" >&2
  cat >&2 <<'EOF'
       A new image does not update the ClusterRole: regenerate it from the kubebuilder RBAC
       markers (make manifests) and deploy it (make deploy IMG=...). If the controller really
       needs other verbs, run with DREEM_RBAC_CHECK=no.
EOF
  return 1
}

set_selection_profile() {   # ENERGY|QOS
  workload patch configmap cluster-configuration-parameters -n "$DREEM_NS" --type merge \
    -p "{\"data\": {\"selectionProfile\": \"$1\"}}" >/dev/null
}

worker_names() {
  workload get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

ready_worker_count() {
  workload get nodes -l '!node-role.kubernetes.io/control-plane' -o json | jq '
    [.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length'
}

wait_workers_ready() {   # [timeout s]
  local timeout=${1:-1800} deadline n
  deadline=$((SECONDS + timeout))
  while :; do
    n=$(ready_worker_count 2>/dev/null || echo 0)
    if [ "$n" -ge "$EXPECTED_WORKERS" ]; then echo "$n/$EXPECTED_WORKERS workers Ready"; return 0; fi
    [ "$SECONDS" -lt "$deadline" ] || die "only $n/$EXPECTED_WORKERS workers Ready after ${timeout}s"
    sleep 15
  done
}

wait_md_ready() {   # [timeout s]
  local timeout=${1:-5400} deadline ready
  deadline=$((SECONDS + timeout))
  while :; do
    ready=$(mgmt get machinedeployment "$MD_NAME" -n "$METAL3_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    if [ "${ready:-0}" -ge "$EXPECTED_WORKERS" ]; then echo "MachineDeployment $MD_NAME: $ready machines ready"; return 0; fi
    [ "$SECONDS" -lt "$deadline" ] || die "MachineDeployment $MD_NAME: ${ready:-0}/$EXPECTED_WORKERS ready after ${timeout}s"
    sleep 30
  done
}

power_on_vms() {
  local vm
  for vm in $(sudo -n virsh list --all --name); do
    sudo -n virsh start "$vm" >/dev/null 2>&1 || true   # already running is fine
  done
}

uncordon_workers() {   # nodes drained by DREEM stay cordoned until DREEM powers them on
  local node cordoned done_="" left
  cordoned=$(workload get nodes -l '!node-role.kubernetes.io/control-plane' \
               -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{" "}{end}')
  for node in $cordoned; do
    held_off "$node" && continue   # switched off for this arm (BASELINE_N)
    workload uncordon "$node" >/dev/null
    done_="$done_ $node"
  done
  [ -z "$done_" ] || echo "uncordoned:$done_"
  left=$(workload get nodes -l '!node-role.kubernetes.io/control-plane' \
           -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{" "}{end}')
  cordoned=""
  for node in $left; do held_off "$node" || cordoned="$cordoned $node"; done
  [ -z "$cordoned" ] || die "workers still cordoned:$cordoned"
}

held_off() { [[ " ${HELD_OFF[*]} " == *" $1 "* ]]; }   # node: switched off for the arm

ironic_records() {   # "name uuid provision_state maintenance" for every Ironic node
  bash "$TESTBED/ironic-maintenance.sh" records
}

worker_records() {   # True|False bmh...: Ironic names of these hosts' records with that maintenance flag
  local flag=$1; shift
  ironic_records | awk -v flag="$flag" -v prefix="$METAL3_NS~" -v hosts=" $* " '
    $4 == flag && index(hosts, " " substr($1, length(prefix) + 1) " ") {print $1}'
}

workers_registered() {   # bmh...: attached, provisioned, no error, Ironic record active under the BMH's ID
  local records bmhs h rec
  records=$(ironic_records) || return 1
  bmhs=$(mgmt get bmh -n "$METAL3_NS" -o json) || return 1
  for h in "$@"; do
    rec=$(awk -v n="$METAL3_NS~$h" '$1 == n {print $2, $3}' <<<"$records")
    jq -e --arg h "$h" --arg rec "$rec" '
      .items[] | select(.metadata.name == $h)
      | .status.operationalStatus == "OK" and .status.provisioning.state == "provisioned"
        and (.status.errorType // "") == "" and $rec == "\(.status.provisioning.ID) active"' \
      <<<"$bmhs" >/dev/null || return 1
  done
}

workers_detached() {   # bmh...: the operator has finished detaching them
  local bmhs h
  bmhs=$(mgmt get bmh -n "$METAL3_NS" -o json) || return 1
  for h in "$@"; do
    jq -e --arg h "$h" '.items[] | select(.metadata.name == $h) | .status.operationalStatus == "detached"' \
      <<<"$bmhs" >/dev/null || return 1
  done
}

poll_until() {   # timeout-s command...: true once the command succeeds, false on timeout
  local deadline=$((SECONDS + $1)); shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 10
  done
}

ready_fleet() {   # every worker on, Ready and schedulable
  # The workload is deployed once, before the arms. A worker left cordoned and off by
  # a previous run (DREEM cordons before it powers a node down) would otherwise be
  # missing from that first placement, and the rollouts would wait for capacity.
  log "Fleet: all workers on, Ready and schedulable"
  power_on_vms
  wait_workers_ready
  uncordon_workers
}

provision_fleet() {   # dreem|ca
  local mode=$1 workers rec leftover
  mapfile -t workers < <(worker_bmhs)
  log "Fleet: Cluster Autoscaler and Karpenter off, ${#workers[@]} worker BMHs attached and registered in Ironic, $EXPECTED_WORKERS workers"
  ca_scale 0
  # a Karpenter run that stopped early leaves hosts in Karpenter's MachineDeployment:
  # the base one could not get every worker back
  karpenter_off
  # a record that survived an earlier detach is in maintenance: lift it before re-attaching
  leftover=$(worker_records True "${workers[@]}")
  for rec in $leftover; do bash "$TESTBED/ironic-maintenance.sh" off "$rec"; done
  # the control-plane BMH is left as it is: neither DREEM nor Cluster Autoscaler acts on it
  mgmt annotate bmh "${workers[@]}" -n "$METAL3_NS" baremetalhost.metal3.io/detached- >/dev/null 2>&1 || true
  mgmt scale machinedeployment "$MD_NAME" -n "$METAL3_NS" --replicas="$EXPECTED_WORKERS" >/dev/null
  wait_md_ready
  wait_workers_ready
  # Re-attaching makes the operator register and adopt every host again (no reinstall).
  # Detaching before that has finished is how a BMH and Ironic end up with different IDs.
  if ! poll_until 900 workers_registered "${workers[@]}"; then
    mgmt get bmh -n "$METAL3_NS"
    bash "$TESTBED/ironic-maintenance.sh" status
    die "worker BMHs not registered in Ironic after 900s; repair a host with ./ironic-reregister.sh <bmh>"
  fi
  echo "worker BMHs attached, their Ironic records active under the BMH IDs"
  "$TESTBED/apply-profiles.sh"
  if [ "$mode" = dreem ]; then
    # DREEM switches nodes off through Redfish behind metal3's and Ironic's back. Detaching
    # makes the operator delete the workers' Ironic records, so Ironic's power sync cannot
    # switch the nodes on again; a record that survives the detach goes into maintenance.
    mgmt annotate bmh "${workers[@]}" -n "$METAL3_NS" baremetalhost.metal3.io/detached="" --overwrite >/dev/null
    poll_until 600 workers_detached "${workers[@]}" || die "worker BMHs not detached after 600s"
    leftover=$(worker_records False "${workers[@]}")
    for rec in $leftover; do bash "$TESTBED/ironic-maintenance.sh" on "$rec" "DREEM experiment"; done
    leftover=$(worker_records True "${workers[@]}" | tr '\n' ' ')
    echo "worker BMHs detached; worker records still in Ironic, all in maintenance: ${leftover:-none}"
  fi
}

# --- Karpenter -----------------------------------------------------------------------
# Installed once (../Karpenter/README.md) with the controller off; test_Karpenter.sh
# switches it on for its arm and off again at the end, as test_CA.sh does with CA.

KARPENTER_DIR="$(cd "$TESTBED/../Karpenter" 2>/dev/null && pwd || true)"
KARPENTER_MD="${MD_NAME}-karpenter"
KARPENTER_POOL_LABEL=nodepool-karpenter   # selects Karpenter's MachineDeployment and Machines

karpenter_installed() { mgmt get deployment karpenter -n kube-system >/dev/null 2>&1; }

karpenter_scale() {   # replicas: the controller, in the management cluster
  mgmt scale deployment karpenter -n kube-system --replicas="$1" >/dev/null
  if [ "$1" -gt 0 ]; then
    mgmt rollout status deployment karpenter -n kube-system --timeout=300s >/dev/null
  else
    mgmt wait --for=delete pod -l app=karpenter -n kube-system --timeout=120s >/dev/null 2>&1 || true
  fi
}

nodeclaim_count() {   # Karpenter's NodeClaims in the workload cluster
  local out
  if out=$(workload get nodeclaims -o name 2>&1); then
    grep -c . <<<"$out" || true
  elif grep -q "doesn't have a resource type" <<<"$out"; then
    echo 0   # CRDs not installed
  else
    echo "cannot list NodeClaims: $out" >&2
    return 1
  fi
}
no_nodeclaims() { [ "$(nodeclaim_count)" = 0 ]; }

karpenter_machines() {   # Machines of Karpenter's MachineDeployment
  mgmt get machines -n "$METAL3_NS" -l "nodepool=$KARPENTER_POOL_LABEL" -o name 2>/dev/null | grep -c . || true
}
no_karpenter_machines() { [ "$(karpenter_machines)" = 0 ]; }

karpenter_off() {   # Karpenter's nodes removed, controller off, its MachineDeployment deleted
  karpenter_installed || return 0
  if ! no_nodeclaims; then
    log "Karpenter: removing the $(nodeclaim_count) nodes it created"
    # no new node for the pods the removed ones leave Pending
    workload patch nodepool metal3 --type merge -p '{"spec": {"limits": {"cpu": "0"}}}' >/dev/null
    # only the controller can drain its nodes and give their Machines back
    karpenter_scale 1
    workload delete nodeclaims --all --wait=false >/dev/null
    poll_until 1800 no_nodeclaims || die "Karpenter's NodeClaims still there after 1800s: workload get nodeclaims"
  fi
  karpenter_scale 0
  workload delete namespace karpenter-warmup --ignore-not-found --wait=false >/dev/null
  if mgmt get machinedeployment "$KARPENTER_MD" -n "$METAL3_NS" >/dev/null 2>&1; then
    MD_NAME="$MD_NAME" MD_NAMESPACE="$METAL3_NS" "$KARPENTER_DIR/machinedeployment.sh" delete >/dev/null
    poll_until 1200 no_karpenter_machines || die "Machines of $KARPENTER_MD still there after 1200s"
    echo "Karpenter: controller off, $KARPENTER_MD deleted"
  fi
  # limits and disruption budget as in the file again
  workload apply -f "$KARPENTER_DIR/nodepool.yaml" >/dev/null || echo "WARNING: could not re-apply $KARPENTER_DIR/nodepool.yaml"
}

# --- BASELINE_N: no scaling, on fewer workers -----------------------------------------
# test.sh's BASELINE_N arm runs like BASELINE on N workers. The others are cordoned,
# drained and powered off before the placement reset, the way DREEM leaves the nodes it
# switches off, and the next arm powers them on again (power_on_vms).

baseline_n_hosts() {   # workers-kept [size]: the worker BMHs to switch off, chosen from profiles.json
  # As many big as small; an odd one comes from [size]. Among those, the removed hosts are
  # in distinct groups (every group keeps a host, so preferred group affinity can still be
  # met), and the kept fleet's mean consumption profile is the closest to the whole
  # fleet's; ties go to the lowest host names. The same N always removes the same hosts.
  python3 - "$TESTBED/profiles.json" "$1" "${2:-}" <<'EOF'
import collections, itertools, json, re, sys
hosts = json.load(open(sys.argv[1]))["assignments"]
keep, extra = int(sys.argv[2]), sys.argv[3]
off = len(hosts) - keep
sizes = sorted({h["size"] for h in hosts.values()})
if not 0 < off < len(hosts):
    sys.exit(f"--nodes must be between 1 and {len(hosts) - 1}")
if len(sizes) != 2:
    sys.exit(f"profiles.json has sizes {sizes}, BASELINE_N splits the removal between two")
if off % 2 and extra not in sizes:
    sys.exit(f"--nodes={keep} switches off {off} of {len(hosts)} workers, an odd number: "
             f"--remove={' or --remove='.join(sizes)} says which size loses one more")
want = collections.Counter({s: off // 2 + (off % 2 if s == extra else 0) for s in sizes})
have = collections.Counter(h["size"] for h in hosts.values())
if any(want[s] > have[s] for s in sizes):
    sys.exit(f"cannot remove {dict(want)}: the fleet has {dict(have)}")
natural = lambda name: [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", name)]
total = sum(h["consumption_profile"] for h in hosts.values())
candidates = [c for c in itertools.combinations(sorted(hosts, key=natural), off)
              if collections.Counter(hosts[h]["size"] for h in c) == want]
spread = max(len({hosts[h]["group"] for h in c}) for c in candidates)
candidates = [c for c in candidates if len({hosts[h]["group"] for h in c}) == spread]
# |kept mean - fleet mean|, scaled to integers
distance = lambda c: abs((total - sum(hosts[h]["consumption_profile"] for h in c)) * len(hosts) - total * keep)
print(" ".join(min(candidates, key=lambda c: (distance(c), [natural(h) for h in c]))))
EOF
}

switch_off_hosts() {   # arm bmh...: cordon, drain and power off their nodes for this arm
  local arm=$1 bmh node uuid deadline; shift
  local -a nodes=() uuids=()
  workers_detached "$@" || die "$arm: worker BMHs attached to Metal3, so Ironic would power them on again (test.sh detaches them; do not use --skip-provision after a CA or Karpenter run)"
  for bmh in "$@"; do
    node=$(mgmt get bmh "$bmh" -n "$METAL3_NS" -o jsonpath='{.spec.consumerRef.name}')
    [ -n "$node" ] && workload get node "$node" >/dev/null 2>&1 || die "$arm: no node for host $bmh"
    nodes+=("$node")
    uuids+=("$(workload get node "$node" -o jsonpath='{.status.nodeInfo.systemUUID}')")
  done
  log "$arm: switching off ${nodes[*]} ($*), $((EXPECTED_WORKERS - $#)) workers stay on"
  jq -n --arg arm "$arm" --argjson kept "$((EXPECTED_WORKERS - $#))" --slurpfile p "$TESTBED/profiles.json" \
        --argjson off "$(paste -d' ' <(printf '%s\n' "$@") <(printf '%s\n' "${nodes[@]}") \
                         | jq -R 'split(" ") | {bmh: .[0], node: .[1]}' | jq -s .)" '
    $p[0].assignments as $a
    | {arm: $arm, workers_on: $kept,
       switched_off: [$off[] | . + {size: $a[.bmh].size, group: $a[.bmh].group, consumption_profile: $a[.bmh].consumption_profile}],
       kept_mean_profile: ((([$a[].consumption_profile] | add) - ([$off[] | $a[.bmh].consumption_profile] | add)) / $kept),
       fleet_mean_profile: ([$a[].consumption_profile] | add / length)}' > "$RUN_DIR/${arm}_switched_off.json"
  jq -r '.switched_off[] | "  \(.bmh) \(.node): \(.size) \(.group) \(.consumption_profile)"' "$RUN_DIR/${arm}_switched_off.json"
  HELD_OFF+=("${nodes[@]}")
  for node in "${nodes[@]}"; do workload cordon "$node" >/dev/null; done
  for node in "${nodes[@]}"; do
    workload drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=10m >/dev/null \
      || die "$arm: could not drain $node"
  done
  # the node's systemUUID is its libvirt domain's UUID; a clean shutdown, forced after 3 min
  for uuid in "${uuids[@]}"; do sudo -n virsh shutdown "$uuid" >/dev/null; done
  for uuid in "${uuids[@]}"; do
    deadline=$((SECONDS + 180))
    until [ "$(sudo -n virsh domstate "$uuid" 2>/dev/null)" = "shut off" ]; do
      if [ "$SECONDS" -ge "$deadline" ]; then sudo -n virsh destroy "$uuid" >/dev/null; break; fi
      sleep 5
    done
  done
  # wait until Kubernetes sees them gone, so no pod is placed on them from now on
  poll_until 300 nodes_not_ready "${nodes[@]}" || die "$arm: ${nodes[*]} still Ready after power-off"
  echo "switched off: ${nodes[*]}"
}

nodes_not_ready() {   # node...: none reports Ready
  local node
  for node in "$@"; do
    workload get node "$node" -o json | jq -e 'any(.status.conditions[]; .type == "Ready" and .status == "True")' \
      >/dev/null && return 1
  done
  return 0
}

apply_latency() {
  if [ "$LATENCY" = yes ]; then
    "$TESTBED/latency.sh" --latency=yes --delay="$DELAY"
  else
    "$TESTBED/latency.sh" --latency=no
  fi
}

# --- workload ------------------------------------------------------------------------

deploy_workload() {
  log "Workload: heavy services, anchors (--anchors=$ANCHORS) and probes"
  "$TESTBED/deploy-mubench.sh" --anchors="$ANCHORS" --out="$RUN_DIR/deploy"
  WORKMODEL="$RUN_DIR/deploy/workmodel.json"
  mapfile -t HEAVY  < <(jq -r 'keys[] | select(test("^s[0-9]+$"))' "$WORKMODEL")
  mapfile -t ANCHOR < <(jq -r 'keys[] | select(test("^a[a-z]$"))' "$WORKMODEL")
  mapfile -t PROBE  < <(jq -r 'keys[] | select(test("^p[a-z]$"))' "$WORKMODEL")
  record_load
  record_dreem_config
}

record_dreem_config() {   # the forecaster's settings as deployed, for reproducibility
  local cm=forecast-parameters out="$RUN_DIR/deploy/forecast-parameters.yaml"
  {
    echo "# $cm from the workload cluster, copied at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
    echo "# Enabled is the value at deployment time: test.sh and test_CA.sh switch the"
    echo "# forecaster on and off per arm, the other keys are what DREEM scaled with."
    workload get configmap "$cm" -n "$DREEM_NS" -o yaml
  } > "$out" 2>/dev/null || { rm -f "$out"; echo "WARNING: could not save the $cm ConfigMap"; }
}

record_load() {   # the load the arms inject, saved in deploy/load/ with a readable summary
  local dir="$RUN_DIR/deploy/load"
  rm -rf "$dir"; mkdir -p "$dir"
  refresh_rampdown_copies
  cp -p "$RUNNER_PARAMS" "$dir/"
  python3 - "$MUBENCH" "$RUNNER_PARAMS" "$dir" <<'EOF'
import collections, json, shutil, sys
from pathlib import Path

mubench, runner_params, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
runner = json.loads(runner_params.read_text())["RunnerParameters"]

# every TrafficParameters file names the workload file it generated (OutputFile)
generated_by = collections.defaultdict(list)
for path in sorted((mubench / "Configs").glob("TrafficParameters*.json")):
    try:
        doc = json.loads(path.read_text())
    except ValueError:
        continue
    if doc.get("OutputFile"):
        generated_by[doc["OutputFile"]].append((path, doc))

lines = [f"Runner: {runner['workload_type']} workload, {runner['workload_rounds']} round(s), "
         f"{runner['thread_pool_size']} threads, gateway {runner['ms_access_gateway']}",
         "The workload files are what the Runner sends; a TrafficParameters file is only their",
         "recipe, and is flagged when its stop_event no longer matches the file's request count.",
         "", f"{'#':>2}  {'file':20} {'requests':>8} {'minutes':>7} {'req/s':>6} {'mean gap ms':>11}  "
             "generated by (mean interarrival ms, stop event, ingress)"]
total_requests = total_s = 0
stale = False
for number, name in enumerate(runner["workload_files_path_list"], 1):
    source = mubench / name
    events = json.loads(source.read_text())
    shutil.copy2(source, out / source.name)
    duration_s = max(e["time"] for e in events) / 1000
    total_requests += len(events)
    total_s += duration_s
    # workload-<n>d.json is a copy of workload-<n>.json, refreshed before every arm
    base = source.name[:-len("d.json")] + ".json" if source.name.endswith("d.json") else source.name
    origin = []
    for path, doc in generated_by.get(base, []):
        shutil.copy2(path, out / path.name)
        params = doc["TrafficParameters"]
        request = params.get("request_parameters", {})
        mismatch = request.get("stop_event") != len(events)
        stale |= mismatch
        origin.append(f"{path.name} ({request.get('mean_interarrival_time')}, {request.get('stop_event')}, "
                      f"{','.join(params.get('ingress_service', []))})"
                      + (" - DOES NOT MATCH this file" if mismatch else ""))
    note = "" if base == source.name else f"copy of {base}: "
    gap_ms = duration_s * 1000 / (len(events) - 1) if len(events) > 1 else 0
    lines.append(f"{number:>2}  {source.name:20} {len(events):>8} {duration_s / 60:>7.1f} {len(events) / duration_s:>6.2f} "
                 f"{gap_ms:>11.0f}  {note}{'; '.join(origin) or 'no TrafficParameters names it'}")
lines += ["", f"total: {total_requests} requests over {total_s / 60:.0f} minutes (plus 10 s between files)"]
if stale:
    lines += ["WARNING: some TrafficParameters no longer describe the workload file they name - they",
              "were changed after the file was generated. The workload files above are what was sent."]
(out / "load_summary.txt").write_text("\n".join(lines) + "\n")
print("\n".join(lines))
EOF
  echo "load recorded in $dir"
}

restart_and_wait() {   # deployment...
  [ "$#" -gt 0 ] || return 0
  workload rollout restart deployment -n "$APP_NS" "$@" >/dev/null
  local d
  for d in "$@"; do workload rollout status deployment "$d" -n "$APP_NS" --timeout=15m >/dev/null; done
}

wait_pods_settled() {   # app...: wait until no pod of these apps is still terminating
  local deadline=$((SECONDS + 300)) selector
  selector="app in ($(IFS=,; echo "$*"))"
  while workload get pods -n "$APP_NS" -l "$selector" -o json \
        | jq -e 'any(.items[]; .metadata.deletionTimestamp != null)' >/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || die "pods of $* still terminating after 300s"
    sleep 5
  done
}

wait_hpa_minimum() {   # deployment...: ready replicas reach the HPA minimum
  local d min ready deadline=$((SECONDS + 600))
  for d in "$@"; do
    min=$(workload get hpa "$d" -n "$APP_NS" -o jsonpath='{.spec.minReplicas}' 2>/dev/null || true)
    while :; do
      ready=$(workload get deployment "$d" -n "$APP_NS" -o jsonpath='{.status.readyReplicas}')
      [ "${ready:-0}" -ge "${min:-1}" ] && break
      [ "$SECONDS" -lt "$deadline" ] || die "$d has ${ready:-0} ready replicas, its HPA minimum is $min"
      sleep 5
    done
  done
}

node_of() {   # pods-json app -> node(s) running that app
  jq -r --arg a "$2" '[.items[] | select(.metadata.labels.app == $a and .metadata.deletionTimestamp == null)
                       | .spec.nodeName] | unique | join(",")' <<<"$1"
}

pairs_together() {   # one line per probe; fails if a probe is away from its anchor
  local pods probe target pnode tnode rc=0
  pods=$(workload get pods -n "$APP_NS" -o json)
  for probe in "${PROBE[@]}"; do
    target=$(jq -r --arg p "$probe" '.[$p].preferred_pod_affinity | keys[0]' "$WORKMODEL")
    pnode=$(node_of "$pods" "$probe")
    tnode=$(node_of "$pods" "$target")
    if [ -n "$pnode" ] && [ "$pnode" = "$tnode" ]; then
      echo "  $probe with $target on $pnode"
    else
      echo "  $probe on ${pnode:-?}, $target on ${tnode:-?}"
      rc=1
    fi
  done
  return "$rc"
}

spread_anchors() {   # start with every anchor on its own node, without a lasting constraint:
                     # nodes already holding an anchor stay cordoned until all anchors are placed
  local a node pods held=()
  for a in "${ANCHOR[@]}"; do
    restart_and_wait "$a"
    wait_pods_settled "$a"
    pods=$(workload get pods -n "$APP_NS" -o json)
    node=$(node_of "$pods" "$a")
    [ -n "$node" ] || continue
    workload cordon "$node" >/dev/null
    held+=("$node")
  done
  for node in "${held[@]}"; do workload uncordon "$node" >/dev/null; done
}

reset_placement() {   # arm
  local arm=$1 attempt pods together=false distinct=true a
  log "$arm: placement reset (heavy services, then one anchor per node, then the probes so they join their anchor)"
  uncordon_workers
  restart_and_wait "${HEAVY[@]}"
  wait_hpa_minimum "${HEAVY[@]}"
  spread_anchors
  for attempt in 1 2 3; do
    restart_and_wait "${PROBE[@]}"
    wait_pods_settled "${PROBE[@]}"
    if pairs_together; then together=true; break; fi
    echo "  a probe did not land next to its anchor (attempt $attempt/3)"
  done
  pods=$(workload get pods -n "$APP_NS" -o json)
  if [ "$(for a in "${ANCHOR[@]}"; do node_of "$pods" "$a"; done | sort -u | wc -l)" -ne "${#ANCHOR[@]}" ]; then
    distinct=false
  fi
  $together || echo "WARNING: $arm starts with a probe away from its anchor"
  $distinct || echo "WARNING: $arm starts with two anchors on the same node"
  echo "pods per node:"
  jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | .spec.nodeName]
         | group_by(.) | .[] | "  \(.[0]): \(length)"' <<<"$pods"
  jq -n --arg arm "$arm" --argjson together "$together" --argjson distinct "$distinct" \
        --argjson pods "$(jq '[.items[] | select(.metadata.deletionTimestamp == null)
                               | {app: .metadata.labels.app, pod: .metadata.name, node: .spec.nodeName}]' <<<"$pods")" \
        '{arm: $arm, pairs_together: $together, anchors_on_distinct_nodes: $distinct, pods: $pods}' \
        > "$RUN_DIR/${arm}_start_placement.json"
}

# --- run -----------------------------------------------------------------------------

start_watcher() {   # jsonl file: pod placement and node state every 30 s
  local out=$1
  (
    set +e
    while true; do
      { workload get pods -n "$APP_NS" -o json; workload get nodes -o json; } 2>/dev/null \
        | jq -cs --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
            select(length == 2) | .[0] as $pods | .[1] as $nodes | {
              ts: $ts,
              nodes: [$nodes.items[] | {name: .metadata.name,
                        ready: any(.status.conditions[]; .type == "Ready" and .status == "True"),
                        unschedulable: (.spec.unschedulable // false)}],
              pods: [$pods.items[] | {app: .metadata.labels.app, pod: .metadata.name, node: .spec.nodeName,
                       phase: .status.phase, terminating: (.metadata.deletionTimestamp != null),
                       ready: any(.status.conditions[]?; .type == "Ready" and .status == "True")}]
            }' >> "$out"
      sleep 30
    done
  ) &
  WATCHER_PID=$!
}

start_repair() {   # arm: bring a probe back to its anchor's node while the workload runs
  [ "$REPAIR" = yes ] || return 0
  local arm=$1
  "$TESTBED/repair-pairs.py" --workmodel "$RUN_DIR/deploy/workmodel.json" \
      --kubeconfig "$WORKLOAD_KUBECONFIG" --namespace "$APP_NS" \
      --interval="$REPAIR_INTERVAL" >> "$RUN_DIR/logs/${arm}_repair.log" 2>&1 &
  REPAIR_PID=$!
  log "$arm: probe/anchor repair running every ${REPAIR_INTERVAL}s (logs/${arm}_repair.log)"
}

stop_repair() {
  [ -n "$REPAIR_PID" ] || return 0
  kill "$REPAIR_PID" 2>/dev/null || true
  wait "$REPAIR_PID" 2>/dev/null || true
  REPAIR_PID=""
}

stop_watcher() {
  [ -n "$WATCHER_PID" ] || return 0
  kill "$WATCHER_PID" 2>/dev/null || true
  wait "$WATCHER_PID" 2>/dev/null || true
  WATCHER_PID=""
}

refresh_rampdown_copies() {   # workload-<n>d.json are copies of workload-<n>.json
  local f
  for f in $(jq -r '.RunnerParameters.workload_files_path_list[]' "$RUNNER_PARAMS"); do
    [[ "$f" =~ ^(.*)d\.json$ ]] || continue
    cp -f "$MUBENCH/${BASH_REMATCH[1]}.json" "$MUBENCH/$f"
  done
}

workload_duration_s() {   # expected length of the main Runner, from its workload files
  (cd "$MUBENCH" && python3 - "$RUNNER_PARAMS" <<'EOF'
import json, sys
files = json.load(open(sys.argv[1]))["RunnerParameters"]["workload_files_path_list"]
total = sum(max(e["time"] for e in json.load(open(f))) / 1000.0 for f in files)
print(int(total + 10 * (len(files) - 1)))   # the Runner sleeps 10 s between workloads
EOF
  )
}

probe_runner_config() {   # service events gateway first-workload-file
  # result_file must not start with "result_": the energy analysis reads result_*.txt
  jq -n --arg svc "$1" --argjson ev "$2" --arg gw "$3" --arg wl "$4" --argjson rate "$PROBE_RATE" '{
    RunnerParameters: {ms_access_gateway: $gw, workload_type: "periodic", rate: $rate,
                       ingress_service: $svc, workload_events: $ev,
                       workload_files_path_list: [$wl], workload_rounds: 1,
                       thread_pool_size: 50, result_file: ("probe_" + $svc)},
    OutputPath: "SimulationWorkspace/Result"}'
}

start_probe_runners() {   # arm duration_s: one periodic Runner per probe, 5 min longer than the main one
  local arm=$1 events gateway first cfg p
  events=$(python3 -c 'import math, sys; print(math.ceil((int(sys.argv[1]) + 300) * float(sys.argv[2])))' "$2" "$PROBE_RATE")
  gateway=$(jq -r '.RunnerParameters.ms_access_gateway' "$RUNNER_PARAMS")
  first=$(jq -r '.RunnerParameters.workload_files_path_list[0]' "$RUNNER_PARAMS")
  PROBE_PIDS=()
  for p in "${PROBE[@]}"; do
    cfg="$RUN_DIR/runner/${arm}_probe_${p}.json"
    probe_runner_config "$p" "$events" "$gateway" "$first" > "$cfg"
    (cd "$MUBENCH" && exec "$PYTHON" -u Benchmarks/Runner/Runner.py -c "$cfg") \
      > "$RUN_DIR/logs/${arm}_probe_${p}.log" 2>&1 &
    PROBE_PIDS+=("$!")
  done
}

run_workload() {   # arm
  local arm=$1 results="$MUBENCH/SimulationWorkspace/Result" duration start end pid
  rm -rf "$results"; mkdir -p "$results"   # no result file of an earlier run leaks into this arm
  refresh_rampdown_copies
  # the Runner reads RunnerParameters.json now: keep the copy this arm used
  cp -p "$RUNNER_PARAMS" "$RUN_DIR/runner/${arm}_RunnerParameters.json"
  if ! cmp -s "$RUNNER_PARAMS" "$RUN_DIR/deploy/load/RunnerParameters.json"; then
    echo "WARNING: $RUNNER_PARAMS differs from the copy recorded at deployment (deploy/load/)"
  fi
  duration=$(workload_duration_s)
  log "$arm: main workload ~$((duration / 60)) min; ${#PROBE[@]} probes at $PROBE_RATE req/s each"
  echo "main Runner: progress on the terminal, saved in $RUN_DIR/logs/${arm}_runner.log"
  echo "probes:      tail -f $RUN_DIR/logs/${arm}_probe_*.log"
  start_probe_runners "$arm" "$duration"
  start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # -u: unbuffered, so the progress shows up as it happens instead of in blocks
  (cd "$MUBENCH" && "$PYTHON" -u Benchmarks/Runner/Runner.py -c Configs/RunnerParameters.json) 2>&1 \
    | tee "$RUN_DIR/logs/${arm}_runner.log" | to_terminal
  end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"arm":"%s","start":"%s","end":"%s"}\n' "$arm" "$start" "$end" > "$RUN_DIR/${arm}_window.json"
  log "$arm: main workload done, waiting for the probe runners to write their results"
  for pid in "${PROBE_PIDS[@]}"; do
    wait "$pid" || echo "WARNING: a probe runner failed, see $RUN_DIR/logs/${arm}_probe_*.log"
  done
  PROBE_PIDS=()
  rm -rf "$RUN_DIR/${arm}_Result"
  cp -r "$results" "$RUN_DIR/${arm}_Result"
}

base_latency_hint() {   # closing note of the test scripts: the base latency to measure, if missing
  local f
  for f in "$RUN_DIR/base_latency_services.csv" "$(dirname "$RUN_DIR")/base_latency_services.csv"; do
    if [ -e "$f" ]; then echo "  * base latency for the notebook: already in $f"; return 0; fi
  done
  cat <<EOF
  * measure the base latency the notebook normalizes with, now that the cluster is calm
    (~50 min; one per scenario is enough, see ./base-latency.sh --help):
      ./base-latency.sh --run-dir $RUN_DIR
EOF
}

save_dreem_decisions() {   # arm
  workload get nodeselecting -n "$DREEM_NS" -o json > "$RUN_DIR/${1}_nodeselecting_CR.json"
  workload delete clusterconfiguration -n "$DREEM_NS" --all >/dev/null
}

cleanup_background() {
  stop_watcher
  stop_repair
  local pid
  for pid in "${PROBE_PIDS[@]}" "$EXTRA_PID"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
}
