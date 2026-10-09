#!/usr/bin/env bash
# Exports the node mapping for ONE run, keyed on the stable identifier.
#
# metal3.io/uuid on a Node is exactly the BareMetalHost's metadata.uid, so it
# survives deprovision/reprovision cycles. Node names do not (CAPI generates a
# new random suffix) and neither does the IP<->host binding (it is a DHCP lease
# and has been observed to change between runs). Every consumer of this file
# must therefore join on uuid, and must use a mapping exported for THAT run.
#
# group is a second, independent node label (A/B/C/D), used for a second
# muBench node-affinity axis alongside size (see profiles.json and
# apply-profiles.sh for why). Captured here the same way size is: a bare Node
# label, required on every worker, forbidden on the control plane.
#
# Usage:
#   ./export-mapping.sh [-o node_map.json] [--run-id NAME]
#   ./export-mapping.sh --stdout
#   ./export-mapping.sh --append timeline.jsonl   # one snapshot per call, for CA churn

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

OUT="node_map.json"; MODE="file"; RUN_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o)        OUT="$2"; shift 2 ;;
    --run-id)  RUN_ID="$2"; shift 2 ;;
    --stdout)  MODE="stdout"; shift ;;
    --append)  MODE="append"; OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

CP_NODE="$(cp_node)"
BASELINE=$(jq -r '.baseline_profile' "$HERE/profiles.json")
CORES=$(jq -r '.cores_per_node' "$HERE/profiles.json")

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
workload get nodes -o json                > "$TMPD/nodes.json"
mgmt get bmh -n "$METAL3_NS" -o json      > "$TMPD/bmhs.json"

SNAPSHOT=$(jq -n \
  --slurpfile nodes "$TMPD/nodes.json" \
  --slurpfile bmhs "$TMPD/bmhs.json" \
  --arg cp "$CP_NODE" \
  --arg run "$RUN_ID" \
  --argjson baseline "$BASELINE" \
  --argjson cores "$CORES" '
  ($nodes[0]) as $nodes | ($bmhs[0]) as $bmhs
  |
  # BMH uid -> BMH name, so every Node can name its physical host.
  ($bmhs.items | map({key: .metadata.uid, value: .metadata.name}) | from_entries) as $uid2bmh
  |
  ($nodes.items | map({
      bmh:  ($uid2bmh[.metadata.labels["metal3.io/uuid"] // ""] // null),
      uuid: (.metadata.labels["metal3.io/uuid"] // null),
      system_uuid: (.status.nodeInfo.systemUUID // null),
      node: .metadata.name,
      ip:   ([.status.addresses[] | select(.type=="InternalIP") | .address] | first // null),
      size: (.metadata.labels.size // null),
      group: (.metadata.labels.group // null),
      consumption_profile:
        ((.metadata.annotations["dreemk8s.io/consumption-profile"] // null)
         | if . == null then null else tonumber end),
      power_cycle_count:
        ((.metadata.annotations["dreemk8s.io/power-cycle-count"] // null)
         | if . == null then null else tonumber end),
      control_plane: (.metadata.name == $cp)
    })) as $all
  |
  {
    exported_at: (now | todate),
    run_id: (if $run == "" then null else $run end),
    baseline_profile: $baseline,
    cores_per_node: $cores,
    control_plane: ($all | map(select(.control_plane)) | first // null),
    nodes: ($all | map(select(.control_plane | not)) | sort_by(.bmh))
  }')

# Refuse to emit a mapping that the analysis cannot use.
echo "$SNAPSHOT" | jq -e '
  (.nodes | length) as $n
  | if $n == 0 then error("no worker nodes found")
    elif (.nodes | map(select(.uuid == null)) | length) > 0 then error("a worker Node has no metal3.io/uuid label")
    elif (.nodes | map(select(.system_uuid == null)) | length) > 0 then error("a worker Node has no status.nodeInfo.systemUUID")
    elif (.nodes | map(select(.consumption_profile == null)) | length) > 0 then error("a worker Node has no consumption-profile - run ./apply-profiles.sh")
    elif (.nodes | map(select(.size == null)) | length) > 0 then error("a worker Node has no size label - run ./apply-profiles.sh")
    elif (.nodes | map(select(.group == null)) | length) > 0 then error("a worker Node has no group label - run ./apply-profiles.sh")
    elif (.nodes | map(select(.ip == null)) | length) > 0 then error("a worker Node has no InternalIP")
    elif (.control_plane != null and .control_plane.consumption_profile != null) then error("control plane still carries a consumption-profile - run ./apply-profiles.sh")
    elif (.control_plane != null and .control_plane.size != null) then error("control plane still carries a size label - run ./apply-profiles.sh")
    elif (.control_plane != null and .control_plane.group != null) then error("control plane still carries a group label - run ./apply-profiles.sh")
    else . end' >/dev/null

case "$MODE" in
  stdout) echo "$SNAPSHOT" | jq . ;;
  append) echo "$SNAPSHOT" | jq -c . >> "$OUT"; echo "appended snapshot to $OUT" ;;
  file)   echo "$SNAPSHOT" | jq . > "$OUT"
          echo "wrote $OUT"
          echo "$SNAPSHOT" | jq -r '.nodes[] | "  \(.bmh)  \(.node)  \(.ip)  \(.size)/\(.group)  \(.consumption_profile)"' ;;
esac
