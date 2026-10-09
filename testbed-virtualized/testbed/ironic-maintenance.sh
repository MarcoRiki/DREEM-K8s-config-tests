#!/usr/bin/env bash
#
# Control Ironic maintenance and power state for metal3-dev-env nodes.
#
# Why this exists: ironic-conductor runs a periodic _sync_power_states task.
# With [conductor]force_power_state_during_sync = true (the Ironic default, and
# not overridden in this deployment's ironic.conf) it powers a node back ON
# whenever the sync finds it off but its own database says it should be on.
# So any power change made BEHIND Ironic's back gets undone within ~60s:
#   - virsh shutdown / virsh destroy
#   - Redfish calls sent straight to sushy-tools
# Both are reverted, because neither updates Ironic's stored power state.
#
# Detaching the BareMetalHost (baremetalhost.metal3.io/detached) stops the
# baremetal-operator from reconciling, and the operator deletes the host's Ironic
# record ("deleting host for detachment" in its log), so the sync leaves it alone.
# Only when the BMH remembers a stale Ironic ID does the record survive, in state
# `active`, and keep being synced.
#
# Two ways to make a shutdown stick:
#   poweroff  - ask Ironic to power the node off, so its database agrees and the
#               sync has nothing to correct. Preferred.
#   on        - flag the node for maintenance; the sync skips it entirely, and
#               you can then use virsh or sushy-tools directly.
#
# Usage:
#   ./ironic-maintenance.sh status [node ...]        # default: all nodes
#   ./ironic-maintenance.sh on  <node|all> [reason]  # maintenance on
#   ./ironic-maintenance.sh off <node|all>           # maintenance off
#   ./ironic-maintenance.sh poweroff <node|all>      # graceful, via Ironic
#   ./ironic-maintenance.sh poweron  <node|all>
#   ./ironic-maintenance.sh records                  # name uuid provision_state maintenance, for scripts
#
# Nodes may be named node-4, node_4 or metal3~node-4.

set -euo pipefail
# mgmt: kubectl on the management cluster, whatever KUBECONFIG the shell exported
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

NS=${IRONIC_NAMESPACE:-baremetal-operator-system}
TENANT=${IRONIC_TENANT:-metal3}                  # BMH namespace: the part before '~'
API_VERSION=${IRONIC_API_VERSION:-1.87}
API_URL=${IRONIC_API_URL:-https://localhost:6385}

die() { echo "error: $*" >&2; exit 1; }

# --- discover the ironic pod and its API credentials -------------------------

POD=$(mgmt -n "$NS" get pod -l name=ironic \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' \
      | awk '{print $1}')
[[ -n $POD ]] || die "no running ironic pod found in namespace $NS"

SECRET=$(mgmt -n "$NS" get secret -o name \
         | sed 's|^secret/||' | grep '^ironic-credentials' | head -1)
[[ -n $SECRET ]] || die "no ironic-credentials secret found in namespace $NS"

IRONIC_USER=$(mgmt -n "$NS" get secret "$SECRET" -o jsonpath='{.data.username}' | base64 -d)
IRONIC_PASS=$(mgmt -n "$NS" get secret "$SECRET" -o jsonpath='{.data.password}' | base64 -d)

# --- API helper ---------------------------------------------------------------
# Credentials reach curl through a config file on stdin, never the command line,
# so they stay out of the container's process list.

api() {
  local method=$1 path=$2 body=${3:-}
  {
    printf 'insecure\nsilent\nshow-error\n'
    printf 'user = "%s:%s"\n' "$IRONIC_USER" "$IRONIC_PASS"
    printf 'request = "%s"\n' "$method"
    printf 'header = "X-OpenStack-Ironic-API-Version: %s"\n' "$API_VERSION"
    if [[ -n $body ]]; then
      printf 'header = "Content-Type: application/json"\n'
      printf 'data = "%s"\n' "${body//\"/\\\"}"
    fi
    printf 'url = "%s%s"\n' "$API_URL" "$path"
  } | mgmt -n "$NS" exec -i "$POD" -c ironic -- curl -K -
}

# node-4 | node_4 | metal3~node-4  ->  metal3~node-4
ironic_name() {
  case $1 in
    *~*) printf '%s' "$1" ;;
    *)   printf '%s~%s' "$TENANT" "${1//_/-}" ;;
  esac
}

LIST_PY='
import json, sys
for n in json.load(sys.stdin)["nodes"]:
    print(n["name"])
'

STATUS_PY='
import json, os, sys
want = set(filter(None, os.environ["WANT"].split(",")))
rows = [n for n in json.load(sys.stdin)["nodes"] if n["name"] in want]
rows.sort(key=lambda n: n["name"])
fmt = "%-16s %-10s %-11s %-12s %s"
print(fmt % ("NODE", "POWER", "PROVISION", "MAINTENANCE", "REASON"))
for n in rows:
    print(fmt % (n["name"], n["power_state"] or "-", n["provision_state"],
                 n["maintenance"], n["maintenance_reason"] or ""))
'

RECORDS_PY='
import json, sys
for n in json.load(sys.stdin)["nodes"]:
    print(n["name"], n["uuid"], n["provision_state"], n["maintenance"])
'

all_nodes() { api GET '/v1/nodes?fields=name' | python3 -c "$LIST_PY" | sort; }

# expand the node arguments ("all", or nothing, means every node)
resolve() {
  if [[ $# -eq 0 || $1 == all ]]; then
    all_nodes
  else
    local n; for n in "$@"; do ironic_name "$n"; echo; done
  fi
}

# --- subcommands --------------------------------------------------------------

cmd_status() {
  local want; want=$(resolve "$@" | paste -sd,)
  api GET '/v1/nodes?fields=name,power_state,provision_state,maintenance,maintenance_reason' \
    | WANT="$want" python3 -c "$STATUS_PY"
}

# apply an API call to each resolved node, then show the resulting status
foreach() {
  local label=$1 method=$2 path_tmpl=$3 body=$4 target=$5
  local node
  for node in $(resolve "$target"); do
    echo "==> $label $node"
    api "$method" "${path_tmpl//NODE/$node}" "$body"
  done
  echo
  cmd_status "$target"
}

case ${1:-status} in
  status)
    shift || true; cmd_status "$@" ;;
  on)
    node=${2:-all}; reason=${*:3}
    foreach "maintenance ON " PUT '/v1/nodes/NODE/maintenance' \
            "{\"reason\": \"${reason:-pinned off by ironic-maintenance.sh}\"}" "$node" ;;
  off)
    foreach "maintenance OFF" DELETE '/v1/nodes/NODE/maintenance' '' "${2:-all}" ;;
  poweroff)
    foreach "power off" PUT '/v1/nodes/NODE/states/power' \
            '{"target": "power off"}' "${2:-all}" ;;
  poweron)
    foreach "power on " PUT '/v1/nodes/NODE/states/power' \
            '{"target": "power on"}' "${2:-all}" ;;
  records)
    api GET '/v1/nodes?fields=name,uuid,provision_state,maintenance' | python3 -c "$RECORDS_PY" ;;
  *)
    awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0" >&2; exit 1 ;;
esac
