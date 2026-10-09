#!/usr/bin/env bash
# Rebuilds DREEM's per-node BMC secrets (dreem/bmc-credentials-<node name>) from the
# BareMetalHosts, so DREEM can power-cycle every current worker.
#
# DREEM looks the secret up by NODE NAME, and Cluster API gives a node a new random
# name every time it is (re)provisioned: after a Cluster Autoscaler run the old
# secrets match no node. Everything needed is on the BMH - the Redfish address
# (host:port and system id) and the credentials secret it references.
#
# Usage: ./sync-bmc-secrets.sh [--dry-run] [--prune]
#   --prune   also delete bmc-credentials-* secrets whose node no longer exists

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

DRY_RUN=false; PRUNE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --prune)   PRUNE=true ;;
    -h|--help) awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

TMP=$(mktemp -d); chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
CP_NODE="$(cp_node)"
WANTED=()

while IFS=$'\t' read -r node address creds bmh; do
  [ -n "$node" ] || continue
  [ "$node" = "$CP_NODE" ] && continue
  # redfish+https://192.168.111.1:8000/redfish/v1/Systems/<system id>
  hostport=$(sed -E 's#^[^:]+://([^/]+)/.*#\1#' <<<"$address")
  system_id=$(sed -E 's#.*/Systems/([^/]+)/?$#\1#' <<<"$address")
  if [ "$hostport" = "$address" ] || [ "$system_id" = "$address" ]; then
    echo "ERROR: cannot parse the BMC address of $bmh: $address" >&2
    exit 1
  fi
  WANTED+=("bmc-credentials-$node")
  if $DRY_RUN; then
    echo "[dry-run] $bmh -> bmc-credentials-$node (bmc_address=$hostport id=$system_id, credentials from $creds)"
    continue
  fi
  mgmt get secret "$creds" -n "$METAL3_NS" -o jsonpath='{.data.username}' | base64 -d > "$TMP/username"
  mgmt get secret "$creds" -n "$METAL3_NS" -o jsonpath='{.data.password}' | base64 -d > "$TMP/password"
  printf '%s' "$hostport" > "$TMP/bmc_address"
  printf '%s' "$system_id" > "$TMP/id"
  workload create secret generic "bmc-credentials-$node" -n dreem \
    --from-file=username="$TMP/username" --from-file=password="$TMP/password" \
    --from-file=bmc_address="$TMP/bmc_address" --from-file=id="$TMP/id" \
    --dry-run=client -o yaml | workload apply -f - >/dev/null
  echo "$bmh -> bmc-credentials-$node"
done < <(mgmt get bmh -n "$METAL3_NS" -o json | jq -r '
  .items[] | select(.spec.consumerRef.name != null)
  | [.spec.consumerRef.name, .spec.bmc.address, .spec.bmc.credentialsName, .metadata.name] | @tsv')

if $PRUNE; then
  for s in $(workload get secrets -n dreem -o name | sed 's#^secret/##' | grep '^bmc-credentials-' || true); do
    printf '%s\n' "${WANTED[@]}" | grep -qx "$s" && continue
    if $DRY_RUN; then echo "[dry-run] would delete stale $s"; else workload delete secret "$s" -n dreem >/dev/null; echo "deleted stale $s"; fi
  done
fi
