#!/usr/bin/env bash
# Emulated network latency between the WORKER nodes of the workload cluster.
#
# A DaemonSet (namespace "netem", host network, privileged) runs on every worker and
# delays packets addressed to the other workers, on two addresses per peer: its node
# InternalIP (node-to-node traffic) and its Calico tunnel endpoint
# (projectcalico.org/IPv4Address). Pod-to-pod traffic is IPIP-encapsulated towards the
# tunnel endpoint, which in this testbed sits on the provisioning network, not on the
# InternalIP. Each rule goes on the interface the route to that address leaves through
# (for a bridge, its member ports). Pods on the same node, and traffic to or from the
# control plane (gateway, API server), are not delayed. The delay is added on the way
# out of every worker, so a round trip between two workers carries 2 x delay.
#
# The pod re-applies the rules whenever it starts, so they survive DREEM power
# cycles. After nodes are reprovisioned with new addresses (Cluster Autoscaler), run
# --refresh-peers; test_CA.sh does it every minute.
#
# Usage:
#   ./latency.sh --latency=yes --delay=2ms   # enable or change, wait, verify
#   ./latency.sh --latency=no                # remove, verify, delete the DaemonSet
#   ./latency.sh --check                     # verify what is applied now
#   ./latency.sh --refresh-peers             # update the peer address list, keep the delay
#
# --delay takes us, ms or s (500us, 0.5ms, 2ms); a bare number means ms.
# The check pings a neighbour from every Ready worker twice - its node address, and its
# IPIP tunnel address, which takes the same path as pod-to-pod traffic - and expects a
# round trip of about 2 x delay on both, or under 3 ms when the latency is off.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

NS=netem
IMAGE=${NETEM_IMAGE:-nicolaka/netshoot:latest}
TIMEOUT_S=${NETEM_TIMEOUT_S:-300}

usage() { awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; }

MODE=""; DELAY=""
for arg in "$@"; do
  case "$arg" in
    --latency=yes)   MODE=enable ;;
    --latency=no)    MODE=disable ;;
    --delay=*)       DELAY="${arg#--delay=}" ;;
    --check)         MODE=check ;;
    --refresh-peers) MODE=refresh ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 1 ;;
  esac
done
[ -n "$MODE" ] || { echo "nothing to do: pass --latency=yes|no, --check or --refresh-peers" >&2; exit 1; }
if [ "$MODE" = enable ]; then
  [ -n "$DELAY" ] || { echo "--latency=yes needs --delay, e.g. --delay=2ms" >&2; exit 1; }
  if [[ "$DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]]; then DELAY="${DELAY}ms"; fi
  [[ "$DELAY" =~ ^[0-9]+([.][0-9]+)?(us|ms|s)$ ]] || { echo "invalid --delay: $DELAY" >&2; exit 1; }
fi

# --- what runs inside every netem pod ----------------------------------------------

pod_script() {
  cat <<'EOF'
#!/bin/sh
# Installed by testbed/latency.sh. Keeps the netem rules on this node in line with
# /etc/netem (enabled, delay, peers) and removes them when the pod stops. Every peer
# address is delayed on the interface its route leaves through (for a bridge, on the
# bridge's member ports). The rules are recognised by the netem qdisc handle 40:.
CONF=/etc/netem
STATE=/tmp/netem-state

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

is_local() { ip -o -4 addr show | awk '{split($4, a, "/"); print a[1]}' | grep -qxF "$1"; }

egress_devs() {   # interfaces a packet to $1 leaves through
  dev=$(ip route get "$1" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
  [ -n "$dev" ] || return 0
  if [ -d "/sys/class/net/$dev/brif" ]; then
    ls "/sys/class/net/$dev/brif"
  else
    echo "$dev"
  fi
}

clear_rules() {
  for dev in $(ls /sys/class/net); do
    if tc qdisc show dev "$dev" 2>/dev/null | grep -q "netem 40:"; then
      tc qdisc del dev "$dev" root 2>/dev/null
    fi
  done
  return 0
}

apply_rules() {   # enabled delay peers
  clear_rules
  rm -f "$STATE"
  if [ "$1" != "true" ]; then
    echo "enabled=false" > "$STATE"
    log "latency off"
    return 0
  fi
  n=0
  devs=""
  for peer in $3; do
    is_local "$peer" && continue
    for dev in $(egress_devs "$peer"); do
      case " $devs " in
        *" $dev "*) ;;
        *)
          # bands 1:1-1:3 keep the default priority map; only filtered traffic reaches 1:4
          tc qdisc add dev "$dev" root handle 1: prio bands 4 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 || return 1
          tc qdisc add dev "$dev" parent 1:4 handle 40: netem delay "$2" limit 100000 || return 1
          devs="$devs $dev"
          ;;
      esac
      tc filter add dev "$dev" parent 1:0 protocol ip prio 1 u32 match ip dst "$peer/32" flowid 1:4 || return 1
    done
    n=$((n + 1))
  done
  devs=$(echo $devs | tr ' ' ',')
  echo "enabled=true delay=$2 peers=$n devs=$devs" > "$STATE"
  log "delay $2 towards $n peer addresses on $devs"
}

intact() {   # every interface listed in the state still carries the netem qdisc
  for dev in $(sed -n 's/.* devs=\([^ ]*\).*/\1/p' "$STATE" 2>/dev/null | tr ',' ' '); do
    tc qdisc show dev "$dev" | grep -q "netem 40:" || return 1
  done
  return 0
}

trap 'log "stopping: removing the rules"; clear_rules; exit 0' TERM INT

clear_rules   # nothing left over from an earlier pod
applied=""
while true; do
  enabled=$(cat "$CONF/enabled" 2>/dev/null || echo false)
  delay=$(cat "$CONF/delay" 2>/dev/null || echo 0ms)
  peers=$(cat "$CONF/peers" 2>/dev/null)
  want="$enabled|$delay|$peers"
  if [ "$want" != "$applied" ] || { [ "$enabled" = "true" ] && ! intact; }; then
    if apply_rules "$enabled" "$delay" "$peers"; then
      applied="$want"
    else
      log "failed to apply the rules, retrying"
      applied=""
      clear_rules
    fi
  fi
  sleep 15 &
  wait $!
done
EOF
}

daemonset_manifest() {   # config hash
  cat <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: netem
  namespace: $NS
  labels:
    app: netem
spec:
  selector:
    matchLabels:
      app: netem
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: "100%"
  template:
    metadata:
      labels:
        app: netem
      annotations:
        netem/config-hash: "$1"
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      terminationGracePeriodSeconds: 20
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role.kubernetes.io/control-plane
                    operator: DoesNotExist
      containers:
        - name: netem
          image: $IMAGE
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "/scripts/netem.sh"]
          env:
            - name: NODE_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
          securityContext:
            privileged: true
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
          readinessProbe:
            exec:
              command: ["/bin/sh", "-c", "test -f /tmp/netem-state"]
            periodSeconds: 5
          volumeMounts:
            - name: config
              mountPath: /etc/netem
            - name: scripts
              mountPath: /scripts
      volumes:
        - name: config
          configMap:
            name: netem-config
        - name: scripts
          configMap:
            name: netem-script
EOF
}

# --- helpers -----------------------------------------------------------------------

peer_addresses() {   # every worker's InternalIP and Calico tunnel endpoint
  workload get nodes -l '!node-role.kubernetes.io/control-plane' -o json | jq -r '
    [.items[]
     | ([.status.addresses[] | select(.type == "InternalIP") | .address] | first),
       (.metadata.annotations["projectcalico.org/IPv4Address"] // empty | split("/")[0])]
    | map(select(. != null)) | unique | join(" ")'
}

ready_workers() {   # "name internal-ip ipip-tunnel-address" per Ready worker
  workload get nodes -l '!node-role.kubernetes.io/control-plane' -o json | jq -r '
    .items[]
    | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))
    | "\(.metadata.name) \([.status.addresses[] | select(.type == "InternalIP") | .address] | first) \(.metadata.annotations["projectcalico.org/IPv4IPIPTunnelAddr"] // "-")"'
}

current_setting() {   # "enabled delay", empty when latency.sh never ran
  workload get configmap netem-config -n "$NS" -o json 2>/dev/null \
    | jq -r '"\(.data.enabled) \(.data.delay)"'
}

to_ms() {
  awk -v d="$1" 'BEGIN {
    if (d ~ /us$/)      { sub(/us$/, "", d); print d / 1000 }
    else if (d ~ /ms$/) { sub(/ms$/, "", d); print d + 0 }
    else if (d ~ /s$/)  { sub(/s$/, "", d);  print d * 1000 }
    else                { print d + 0 } }'
}

rtt_ok() {   # rtt_ms enabled delay_ms
  awk -v r="$1" -v e="$2" -v d="$3" 'BEGIN {
    if (r == "") exit 1
    if (e == "true") { slack = (0.5 * d > 3) ? 0.5 * d : 3; exit !(r >= 1.8 * d && r <= 2 * d + slack) }
    exit !(r < 3) }'
}

ping_avg() {   # pod address -> average round trip in ms, empty on failure
  workload exec -n "$NS" "$1" -- ping -c 10 -i 0.2 -q "$2" 2>/dev/null | awk -F/ '/^rtt/ {print $5}' || true
}

apply_config() {   # enabled delay -> prints the config hash
  local enabled=$1 delay=$2 peers hash tmp
  peers=$(peer_addresses)
  tmp=$(mktemp -d)
  pod_script > "$tmp/netem.sh"
  # The peers are part of the hash: a new peer list (nodes replaced, new addresses) restarts
  # the netem pods, so wait_rollout returns only once every Ready worker runs a pod that has
  # applied the current list (a pod is Ready after it applied its rules). Without them, the
  # old pods kept the old list until kubelet refreshed the mounted ConfigMap (up to a
  # minute), and the check ran against stale rules. --refresh-peers only patches the
  # ConfigMap: no restart during a run.
  hash=$({ printf '%s|%s|%s|' "$enabled" "$delay" "$peers"; cat "$tmp/netem.sh"; } | sha256sum | cut -c1-16)
  workload create namespace "$NS" --dry-run=client -o yaml | workload apply -f - >/dev/null
  workload label namespace "$NS" istio-injection=disabled --overwrite >/dev/null
  workload create configmap netem-script -n "$NS" --from-file=netem.sh="$tmp/netem.sh" \
    --dry-run=client -o yaml | workload apply -f - >/dev/null
  workload create configmap netem-config -n "$NS" \
    --from-literal=enabled="$enabled" --from-literal=delay="$delay" --from-literal=peers="$peers" \
    --dry-run=client -o yaml | workload apply -f - >/dev/null
  daemonset_manifest "$hash" | workload apply -f - >/dev/null
  rm -rf "$tmp"
  echo "$hash"
}

wait_rollout() {   # hash: every Ready worker runs a Ready pod with this config
  local hash=$1 deadline=$((SECONDS + TIMEOUT_S)) missing pods_json node
  while :; do
    missing=0
    pods_json=$(workload get pods -n "$NS" -l app=netem -o json)
    while read -r node _ _; do
      [ -n "$node" ] || continue
      if ! jq -e --arg n "$node" --arg h "$hash" '
            any(.items[]; .spec.nodeName == $n
                and .metadata.annotations["netem/config-hash"] == $h
                and .metadata.deletionTimestamp == null
                and any(.status.conditions[]?; .type == "Ready" and .status == "True"))' \
            <<<"$pods_json" >/dev/null; then
        missing=$((missing + 1))
      fi
    done < <(ready_workers)
    [ "$missing" -eq 0 ] && return 0
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "ERROR: netem pods not ready on $missing worker(s) after ${TIMEOUT_S}s" >&2
      workload get pods -n "$NS" -o wide >&2
      return 1
    fi
    sleep 5
  done
}

check() {   # enabled delay
  local want_enabled=$1 want_delay=$2 delay_ms pods_json fail=0 i node peer_ip peer_tun pod state rtt_node rtt_pod verdict
  delay_ms=$(to_ms "$want_delay")
  pods_json=$(workload get pods -n "$NS" -l app=netem -o json)
  mapfile -t READY < <(ready_workers)
  [ "${#READY[@]}" -gt 0 ] || { echo "ERROR: no Ready worker" >&2; return 1; }
  printf '%-30s %-16s %-9s %-9s %s\n' NODE PEER NODE_RTT POD_RTT "APPLIED  RESULT"
  for i in "${!READY[@]}"; do
    read -r node _ _ <<<"${READY[$i]}"
    read -r _ peer_ip peer_tun <<<"${READY[$(( (i + 1) % ${#READY[@]} ))]}"
    pod=$(jq -r --arg n "$node" '[.items[] | select(.spec.nodeName == $n and .metadata.deletionTimestamp == null)
                                 | .metadata.name] | first // empty' <<<"$pods_json")
    if [ -z "$pod" ]; then
      printf '%-30s %s\n' "$node" "no netem pod  FAIL"
      fail=1
      continue
    fi
    state=$(workload exec -n "$NS" "$pod" -- cat /tmp/netem-state 2>/dev/null || echo none)
    rtt_node=""; rtt_pod=""
    if [ "${#READY[@]}" -gt 1 ]; then
      rtt_node=$(ping_avg "$pod" "$peer_ip")
      [ "$peer_tun" = "-" ] || rtt_pod=$(ping_avg "$pod" "$peer_tun")
    fi
    verdict=OK
    if [ "$want_enabled" = true ]; then
      if [[ "$state" =~ ^enabled=true\ delay=$want_delay\ peers=([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -gt 0 ]; then :; else verdict=FAIL; fi
    else
      [[ "$state" == enabled=false* ]] || verdict=FAIL
    fi
    if [ "${#READY[@]}" -gt 1 ]; then
      rtt_ok "$rtt_node" "$want_enabled" "$delay_ms" || verdict=FAIL
      rtt_ok "$rtt_pod" "$want_enabled" "$delay_ms" || verdict=FAIL
    fi
    [ "$verdict" = OK ] || fail=1
    printf '%-30s %-16s %-9s %-9s %s  %s\n' "$node" "$peer_ip" "${rtt_node:--}" "${rtt_pod:--}" "$state" "$verdict"
  done
  return "$fail"
}

disable() {
  if ! workload get daemonset netem -n "$NS" >/dev/null 2>&1; then
    echo "latency is already off (no netem DaemonSet)"
    return 0
  fi
  echo "removing the delay between workers"
  local hash
  hash=$(apply_config false 0ms)
  wait_rollout "$hash"
  if ! check false 0ms; then
    echo "ERROR: some worker still delays traffic; the DaemonSet is kept for inspection" >&2
    return 1
  fi
  workload delete namespace "$NS" --wait=true >/dev/null
  echo "latency off, DaemonSet removed"
}

refresh() {
  if ! workload get configmap netem-config -n "$NS" >/dev/null 2>&1; then
    echo "latency is off, nothing to refresh"
    return 0
  fi
  local peers
  peers=$(peer_addresses)
  workload patch configmap netem-config -n "$NS" --type merge \
    -p "$(jq -n --arg p "$peers" '{data: {peers: $p}}')" >/dev/null
  echo "peer addresses updated: $peers"
}

# --- main --------------------------------------------------------------------------

case "$MODE" in
  enable)
    echo "setting a $DELAY delay (one way) between workers"
    HASH=$(apply_config true "$DELAY")
    wait_rollout "$HASH"
    if ! check true "$DELAY"; then
      echo "ERROR: the latency check failed" >&2
      exit 1
    fi
    echo "latency OK: $DELAY one way, about 2 x $DELAY round trip between workers, node and pod network"
    ;;
  disable)
    disable
    ;;
  check)
    SETTING=$(current_setting || true)
    if [ -z "$SETTING" ]; then
      echo "latency is off (no netem DaemonSet)"
      exit 0
    fi
    read -r ENABLED CUR_DELAY <<<"$SETTING"
    check "$ENABLED" "$CUR_DELAY"
    ;;
  refresh)
    refresh
    ;;
esac
