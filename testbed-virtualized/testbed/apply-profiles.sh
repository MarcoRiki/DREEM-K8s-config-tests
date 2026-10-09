#!/usr/bin/env bash
# Pushes size + consumption-profile + group from the BMHs (management cluster)
# onto the Nodes (workload cluster), and resets the power-cycle counter.
#
# Needed because Cluster Autoscaler deletes Node objects on scale-down: the BMH
# survives, so it is the durable home for the hardware profile. Run this after
# every (re)provisioning and before every arm of the experiment.
#
# GROUP is new: a second node label (A/B/C/D), independent of size, used for a
# second muBench node-affinity axis (see K8sYamlBuilder.py's preferred_group
# handling). Unlike size/consumption-profile - which assign-profiles.sh writes
# once onto the BMH - group is written here, directly from profiles.json, the
# first time this script sees a BMH without it. It is idempotent: once a BMH
# has a group annotation this script never overwrites it, so group stays fixed
# across every arm exactly like size and consumption-profile do, and calling
# this script repeatedly (once per arm, as test.sh does) cannot re-roll it.
#
# The control-plane Node/BMH is excluded and actively cleaned of all three.
#
# Usage: ./apply-profiles.sh [--dry-run]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

PROFILES="$HERE/profiles.json"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

CP="$(cp_bmh)"
CP_NS=${CP%%/*}; CP_NAME=${CP##*/}
CP_NODE="$(cp_node)"
echo "control plane (excluded): bmh=$CP  node=${CP_NODE:-<none>}"

# 0. Assign group on the BMHs, once, from profiles.json. Skipped entirely for
#    any BMH that already carries the annotation, so this step is a no-op on
#    every call after the first.
mapfile -t WORKERS < <(worker_bmhs)
mapfile -t EXPECTED < <(jq -r '.assignments | keys[]' "$PROFILES" | sort)
if [ "$(printf '%s\n' "${WORKERS[@]}")" != "$(printf '%s\n' "${EXPECTED[@]}")" ]; then
  echo "ERROR: live worker BMHs do not match profiles.json" >&2
  echo "  live:     ${WORKERS[*]}" >&2
  echo "  expected: ${EXPECTED[*]}" >&2
  exit 1
fi

for bmh in "${WORKERS[@]}"; do
  EXISTING=$(mgmt get bmh "$bmh" -n "$METAL3_NS" \
    -o jsonpath='{.metadata.annotations.dreemk8s\.io/group}' 2>/dev/null || true)
  [ -n "$EXISTING" ] && continue   # already assigned - never re-roll it

  GROUP=$(jq -r --arg n "$bmh" '.assignments[$n].group // empty' "$PROFILES")
  if [ -z "$GROUP" ]; then
    echo "ERROR: $bmh has no 'group' entry in profiles.json" >&2
    exit 1
  fi

  if $DRY_RUN; then
    echo "[dry-run] would set bmh $bmh group=$GROUP (currently unset)"
    continue
  fi
  mgmt annotate bmh "$bmh" -n "$METAL3_NS" dreemk8s.io/group="$GROUP" >/dev/null
  echo "bmh $bmh: assigned group=$GROUP"
done

# 1. Clean the control-plane BMH and Node of anything a previous run left.
if $DRY_RUN; then
  echo "[dry-run] would remove size/consumption-profile/group from bmh $CP"
  [ -n "$CP_NODE" ] && echo "[dry-run] would remove size/consumption-profile/group from node $CP_NODE"
else
  mgmt annotate bmh "$CP_NAME" -n "$CP_NS" \
    size- dreemk8s.io/size- dreemk8s.io/consumption-profile- dreemk8s.io/group- \
    2>/dev/null || true
  if [ -n "$CP_NODE" ]; then
    workload label    node "$CP_NODE" size- group- 2>/dev/null || true
    workload annotate node "$CP_NODE" dreemk8s.io/consumption-profile- 2>/dev/null || true
  fi
  echo "cleaned control plane"
fi

# 2. Copy BMH -> Node for the workers only: size, consumption-profile, group.
mgmt get bmh -n "$METAL3_NS" -o json | jq -c '
  .items[] | select(.spec.consumerRef.name != null) | {
    bmh:     .metadata.name,
    node:    .spec.consumerRef.name,
    size:    (.metadata.annotations["dreemk8s.io/size"] // .metadata.annotations["size"] // null),
    profile: (.metadata.annotations["dreemk8s.io/consumption-profile"] // null),
    group:   (.metadata.annotations["dreemk8s.io/group"] // null)
  }' | while read -r row; do
  NODE=$(jq -r '.node'    <<<"$row")
  BMH=$(jq  -r '.bmh'     <<<"$row")
  SIZE=$(jq -r '.size'    <<<"$row")
  PROFILE=$(jq -r '.profile' <<<"$row")
  GROUP=$(jq -r '.group'  <<<"$row")

  [ "$NODE" = "$CP_NODE" ] && { echo "skip $BMH ($NODE) - control plane"; continue; }
  # A host that is still provisioning already has a consumer but no Node yet. Skip it
  # instead of failing: under set -e a failed label would stop the whole script and
  # leave every host after it in the list unlabeled until this one joins.
  if ! workload get node "$NODE" >/dev/null 2>&1; then
    echo "skip $BMH ($NODE) - node not registered yet"
    continue
  fi
  if [ "$SIZE" = "null" ] || [ "$PROFILE" = "null" ] || [ "$GROUP" = "null" ]; then
    echo "ERROR: $BMH is missing size/profile/group - run this script again or check profiles.json" >&2
    exit 1
  fi

  if $DRY_RUN; then
    echo "[dry-run] $BMH -> node $NODE: size=$SIZE profile=$PROFILE group=$GROUP power-cycle-count=0"
    continue
  fi

  # group is a bare label, like size: DREEM's PreferredNodeAffinity scoring
  # (GetPreferredNodeAffinity in selection_utils.go) matches a pod's preferred
  # nodeAffinity term against node.Labels by whatever key the term names, so a
  # workmodel entry using "group" must find a Node LABEL called "group".
  workload label    node "$NODE" size="$SIZE" group="$GROUP" --overwrite >/dev/null
  workload annotate node "$NODE" \
    dreemk8s.io/consumption-profile="$PROFILE" \
    dreemk8s.io/power-cycle-count="0" --overwrite >/dev/null
  echo "$BMH -> $NODE: size=$SIZE profile=$PROFILE group=$GROUP"
done

echo "done."
