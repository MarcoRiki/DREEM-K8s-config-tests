#!/usr/bin/env bash
# Feasibility check: does Karpenter both add and remove Metal3 nodes on this testbed?
#
# Prerequisites (see README.md):
#   - Karpenter installed (CRDs, nodepool.yaml, karpenter.yaml);
#   - worker BareMetalHosts attached to Metal3, as for Cluster Autoscaler:
#       cd ../testbed && bash -c 'source ./run-lib.sh; provision_fleet ca'
#   - DREEM and Cluster Autoscaler off.
#
# Steps, each timed:
#   1. base MachineDeployment from 8 to 6 workers, so two hosts are free;
#   2. Karpenter's MachineDeployment created (0 replicas), controller on;
#   3. scale-up: smoke-test.yaml at 2 replicas, which only Karpenter nodes can host, one
#      per node: two NodeClaims must launch, register and get their node;
#   4. scale-down: smoke test at 0: Karpenter must remove both nodes after consolidateAfter
#      (10 min), and the Machines and replicas must follow;
#   5. clean-up: smoke test deleted, controller off, Karpenter's MachineDeployment deleted,
#      base MachineDeployment back to 8 workers.
#
# Usage: ./feasibility-check.sh [--keep]   (--keep: skip the clean-up, to inspect the state)
# Log: feasibility-check-<UTC time>.log next to this script.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MGMT_KUBECONFIG:=$HOME/.kube/config}"
: "${WORKLOAD_KUBECONFIG:=$HOME/workload.kubeconfig}"
: "${MD_NAME:=test-cluster-m3}"
: "${MD_NAMESPACE:=metal3}"
BASE_WORKERS=8
KEEP=false
[ "${1:-}" = --keep ] && KEEP=true

M="kubectl --kubeconfig=$MGMT_KUBECONFIG"
W="kubectl --kubeconfig=$WORKLOAD_KUBECONFIG"
LOG="$HERE/feasibility-check-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1

T0=$(date +%s)
log()  { printf '[%s +%4ss] %s\n' "$(date -u +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }
fail() { log "FAIL: $*"; exit 1; }
# poll <timeout s> <description> <command...>: true as soon as the command succeeds
poll() {
  local timeout=$1 what=$2; shift 2
  local start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    (( $(date +%s) - start >= timeout )) && { log "timeout after ${timeout}s: $what"; return 1; }
    sleep 10
  done
  log "ok after $(( $(date +%s) - start ))s: $what"
}

nodeclaims()        { $W get nodeclaims --no-headers 2>/dev/null | wc -l; }
nodeclaims_cond()   { # <condition>: number of NodeClaims with that condition True
  $W get nodeclaims -o json | jq --arg c "$1" '[.items[] | select(any(.status.conditions[]?; .type == $c and .status == "True"))] | length'; }
md_ready()          { # <md> <replicas>
  [ "$($M get md "$1" -n "$MD_NAMESPACE" -o jsonpath='{.status.readyReplicas}')" = "$2" ] &&
  [ "$($M get machines -n "$MD_NAMESPACE" -l "cluster.x-k8s.io/deployment-name=$1" --no-headers | wc -l)" = "$2" ]; }
free_hosts()        { $M get bmh -n "$MD_NAMESPACE" -o json | jq '[.items[] | select(.status.provisioning.state == "available")] | length'; }
smoke_running()     { [ "$($W get pods -l app=karpenter-smoke --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)" = "$1" ]; }
karpenter_machines(){ $M get machines -n "$MD_NAMESPACE" -l nodepool=nodepool-karpenter --no-headers 2>/dev/null | wc -l; }

log "log: $LOG"
log "== 1. base MachineDeployment $MD_NAME: $BASE_WORKERS -> 6 workers"
$M scale md "$MD_NAME" -n "$MD_NAMESPACE" --replicas=6 >/dev/null
poll 1200 "base MachineDeployment at 6 ready Machines" md_ready "$MD_NAME" 6 || fail "base MachineDeployment did not reach 6"
poll 1200 "2 hosts available" bash -c "[ \$($M get bmh -n $MD_NAMESPACE -o json | jq '[.items[] | select(.status.provisioning.state == \"available\")] | length') -ge 2 ]" \
  || fail "no free hosts"

log "== 2. Karpenter's MachineDeployment and controller"
"$HERE/machinedeployment.sh" create
$M -n kube-system scale deployment karpenter --replicas=1 >/dev/null
$M -n kube-system rollout status deployment karpenter --timeout=180s >/dev/null || fail "controller not running"
log "controller running"

log "== 3. scale-up: smoke test at 2 replicas"
$W apply -f "$HERE/smoke-test.yaml" >/dev/null
$W scale deployment karpenter-smoke --replicas=2 >/dev/null
poll 300  "2 NodeClaims created"          bash -c "[ \$($W get nodeclaims --no-headers 2>/dev/null | wc -l) -ge 2 ]" || fail "Karpenter created no NodeClaims"
poll 600  "2 NodeClaims Launched"         bash -c "[ \$($W get nodeclaims -o json | jq '[.items[] | select(any(.status.conditions[]?; .type == \"Launched\" and .status == \"True\"))] | length') -ge 2 ]" || fail "NodeClaims not launched"
poll 1200 "2 NodeClaims Registered"       bash -c "[ \$($W get nodeclaims -o json | jq '[.items[] | select(any(.status.conditions[]?; .type == \"Registered\" and .status == \"True\"))] | length') -ge 2 ]" || fail "nodes did not register"
poll 600  "2 NodeClaims Initialized"      bash -c "[ \$($W get nodeclaims -o json | jq '[.items[] | select(any(.status.conditions[]?; .type == \"Initialized\" and .status == \"True\"))] | length') -ge 2 ]" || fail "nodes not initialized"
poll 300  "2 smoke-test pods Running"     smoke_running 2 || fail "smoke-test pods not running"
log "NodeClaims:"; $W get nodeclaims -o wide
log "Karpenter's Machines:"; "$HERE/machinedeployment.sh" show | sed -n '/^MACHINE/,$p'
log "Karpenter's nodes:"; $W get nodes -l karpenter.sh/nodepool=metal3 -L karpenter.sh/nodepool,node.kubernetes.io/instance-type,topology.kubernetes.io/zone,karpenter.sh/capacity-type,size,group
log "NodeClaim events:"; $W get events -A --field-selector involvedObject.kind=NodeClaim --sort-by=.lastTimestamp 2>/dev/null | tail -12

log "== 4. scale-down: smoke test at 0, consolidateAfter 10m"
$W scale deployment karpenter-smoke --replicas=0 >/dev/null
poll 2400 "all NodeClaims removed"         bash -c "[ \$($W get nodeclaims --no-headers 2>/dev/null | wc -l) -eq 0 ]" || fail "Karpenter did not remove its nodes"
poll 1200 "Karpenter's Machines removed"   bash -c "[ \$($M get machines -n $MD_NAMESPACE -l nodepool=nodepool-karpenter --no-headers 2>/dev/null | wc -l) -eq 0 ]" || fail "Machines left behind"
log "Karpenter's MachineDeployment replicas: $($M get md "$MD_NAME-karpenter" -n "$MD_NAMESPACE" -o jsonpath='{.spec.replicas}')"
log "disruption events:"; $W get events -A --sort-by=.lastTimestamp 2>/dev/null | grep -i -E 'disrupt|consolidat|Unconsolidatable|DisruptionTerminating' | tail -10 || true

log "PASS: Karpenter added and removed Metal3 nodes"

if $KEEP; then log "--keep: clean-up skipped"; exit 0; fi
log "== 5. clean-up"
$W delete -f "$HERE/smoke-test.yaml" --ignore-not-found >/dev/null
# the controller's log lives only as long as its pod: keep it before switching it off
$M -n kube-system logs deploy/karpenter > "${LOG%.log}.controller.log" 2>&1 || true
log "controller log: ${LOG%.log}.controller.log"
$M -n kube-system scale deployment karpenter --replicas=0 >/dev/null
"$HERE/machinedeployment.sh" delete
$M scale md "$MD_NAME" -n "$MD_NAMESPACE" --replicas="$BASE_WORKERS" >/dev/null
poll 1800 "base MachineDeployment back at $BASE_WORKERS ready Machines" md_ready "$MD_NAME" "$BASE_WORKERS" || fail "fleet not restored"
log "done: controller off, Karpenter's MachineDeployment deleted, $BASE_WORKERS workers"
