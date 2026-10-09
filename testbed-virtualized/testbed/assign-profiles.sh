#!/usr/bin/env bash
# Writes the deterministic profiles from profiles.json onto the worker BMHs: size,
# consumption profile and group (the node-affinity group copied into kubelet's node
# labels when a worker is provisioned).
#
# Replaces the old $RANDOM loop: the values live in profiles.json and are
# identical for every arm of the experiment. The control-plane BMH is excluded
# and actively cleaned of any size / consumption-profile annotation left over
# from earlier runs.
#
# Usage: ./assign-profiles.sh [--dry-run]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

PROFILES="$HERE/profiles.json"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

CP="$(cp_bmh)"
echo "control-plane BMH (excluded): $CP"

mapfile -t WORKERS < <(worker_bmhs)
mapfile -t EXPECTED < <(jq -r '.assignments | keys[]' "$PROFILES" | sort)

# Fail loudly rather than silently reshuffling if the fleet changed.
if [ "$(printf '%s\n' "${WORKERS[@]}")" != "$(printf '%s\n' "${EXPECTED[@]}")" ]; then
  echo "ERROR: live worker BMHs do not match profiles.json" >&2
  echo "  live:     ${WORKERS[*]}" >&2
  echo "  expected: ${EXPECTED[*]}" >&2
  echo "Update profiles.json deliberately, then re-run." >&2
  exit 1
fi

# 1. Strip any stale annotation from the control plane.
CP_NS=${CP%%/*}; CP_NAME=${CP##*/}
if $DRY_RUN; then
  echo "[dry-run] would remove size/consumption-profile/group from bmh $CP"
else
  mgmt annotate bmh "$CP_NAME" -n "$CP_NS" \
    size- dreemk8s.io/size- dreemk8s.io/consumption-profile- dreemk8s.io/group- 2>/dev/null || true
  echo "cleaned control-plane BMH $CP"
fi

# 2. Apply the deterministic assignment to the workers.
for bmh in "${WORKERS[@]}"; do
  SIZE=$(jq -r --arg n "$bmh" '.assignments[$n].size' "$PROFILES")
  PROFILE=$(jq -r --arg n "$bmh" '.assignments[$n].consumption_profile' "$PROFILES")
  GROUP=$(jq -r --arg n "$bmh" '.assignments[$n].group // empty' "$PROFILES")
  if [ -z "$GROUP" ]; then
    echo "ERROR: $bmh has no 'group' in profiles.json" >&2
    exit 1
  fi

  if $DRY_RUN; then
    echo "[dry-run] $bmh -> size=$SIZE profile=$PROFILE group=$GROUP"
    continue
  fi

  # Write the prefixed keys and drop the legacy unprefixed "size" annotation.
  mgmt annotate bmh "$bmh" -n "$METAL3_NS" \
    dreemk8s.io/size="$SIZE" \
    dreemk8s.io/consumption-profile="$PROFILE" \
    dreemk8s.io/group="$GROUP" \
    --overwrite >/dev/null
  mgmt annotate bmh "$bmh" -n "$METAL3_NS" size- 2>/dev/null || true
  echo "$bmh -> size=$SIZE profile=$PROFILE group=$GROUP"
done

echo "done. verify with: ./export-mapping.sh --stdout"
