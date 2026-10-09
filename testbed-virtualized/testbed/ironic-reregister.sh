#!/usr/bin/env bash
# Makes a BareMetalHost and its Ironic record agree again, without touching the running OS.
#
# Why: after many detach/attach cycles a BMH can remember an Ironic node ID
# (status.provisioning.ID) that no longer exists, while Ironic holds a different record
# under the same name. On re-attach the operator adopts the host through that record but
# does not manage to store its ID, and its BIOS/firmware checks keep failing on the old one.
#
# How, per host:
#   1. detach the BMH, so the operator stops acting on it
#   2. put the Ironic record in maintenance and delete it - Ironic only deletes an active
#      node in maintenance; deleting the record neither powers off nor reinstalls the host
#   3. re-attach the BMH: the operator registers the host again, adopts the running OS
#      (no reinstall) and stores the new ID
#   4. wait until the BMH ID equals the Ironic ID, Ironic says active and the BMH is OK
#
# The host is left attached with Ironic maintenance off (the normal metal3 state);
# test.sh detaches the hosts and turns maintenance on again before the DREEM arms.
#
# Usage: ./ironic-reregister.sh node-2 [node-3 ...] [--timeout=600] [--include-control-plane]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

IRONIC_NS=${IRONIC_NAMESPACE:-baremetal-operator-system}
TENANT=${IRONIC_TENANT:-metal3}
TIMEOUT_S=600
INCLUDE_CP=false
HOSTS=()
for arg in "$@"; do
  case "$arg" in
    --timeout=*)             TIMEOUT_S="${arg#--timeout=}" ;;
    --include-control-plane) INCLUDE_CP=true ;;
    -h|--help)               awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;;
    -*)                      echo "unknown option: $arg" >&2; exit 1 ;;
    *)                       HOSTS+=("$arg") ;;
  esac
done
[ "${#HOSTS[@]}" -gt 0 ] || { echo "name at least one BMH, e.g. node-2" >&2; exit 1; }

CP="$(cp_bmh)"
if ! $INCLUDE_CP; then
  for h in "${HOSTS[@]}"; do
    [ "$METAL3_NS/$h" = "$CP" ] && { echo "$h is the control-plane host; add --include-control-plane to touch it" >&2; exit 1; }
  done
fi

POD=$(mgmt -n "$IRONIC_NS" get pod -l name=ironic \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | awk '{print $1}')
SECRET=$(mgmt -n "$IRONIC_NS" get secret -o name | sed 's|^secret/||' | grep '^ironic-credentials' | head -1)
IRONIC_USER=$(mgmt -n "$IRONIC_NS" get secret "$SECRET" -o jsonpath='{.data.username}' | base64 -d)
IRONIC_PASS=$(mgmt -n "$IRONIC_NS" get secret "$SECRET" -o jsonpath='{.data.password}' | base64 -d)

api() {   # method path [json] -> body, then "HTTP <code>" on the last line
  local method=$1 path=$2 body=${3:-}
  {
    printf 'insecure\nsilent\nshow-error\n'
    printf 'user = "%s:%s"\n' "$IRONIC_USER" "$IRONIC_PASS"
    printf 'request = "%s"\n' "$method"
    printf 'header = "X-OpenStack-Ironic-API-Version: 1.87"\n'
    if [ -n "$body" ]; then
      printf 'header = "Content-Type: application/json"\n'
      printf 'data = "%s"\n' "${body//\"/\\\"}"
    fi
    printf 'url = "https://localhost:6385%s"\n' "$path"
    printf 'write-out = "\\nHTTP %%{http_code}\\n"\n'
  } | mgmt -n "$IRONIC_NS" exec -i "$POD" -c ironic -- curl -K -
}

ironic_record() {   # bmh -> "uuid provision_state maintenance", empty if Ironic has no record
  api GET '/v1/nodes?fields=name,uuid,provision_state,maintenance' | sed '$d' \
    | jq -r --arg n "$TENANT~$1" '.nodes[] | select(.name == $n) | "\(.uuid) \(.provision_state) \(.maintenance)"'
}

bmh_field() { mgmt get bmh "$1" -n "$METAL3_NS" -o jsonpath="$2"; }

wait_for() {   # seconds description command...
  local timeout=$1 what=$2 deadline; shift 2
  deadline=$((SECONDS + timeout))
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "  timed out waiting for: $what" >&2; return 1; }
    sleep 5
  done
}

is_detached()   { [ "$(bmh_field "$1" '{.status.operationalStatus}')" = detached ]; }
record_gone()   { [ -z "$(ironic_record "$1")" ]; }
is_consistent() {
  local id op state err rec
  id=$(bmh_field "$1" '{.status.provisioning.ID}')
  op=$(bmh_field "$1" '{.status.operationalStatus}')
  state=$(bmh_field "$1" '{.status.provisioning.state}')
  err=$(bmh_field "$1" '{.status.errorType}')
  rec=$(ironic_record "$1")
  [ "$op" = OK ] && [ "$state" = provisioned ] && [ -z "$err" ] && [ "$rec" = "$id active false" ]
}

reregister() {
  local bmh=$1 rec uuid code
  echo "== $bmh: BMH ID $(bmh_field "$bmh" '{.status.provisioning.ID}'), Ironic: ${rec:-$(ironic_record "$bmh")}"
  rec=$(ironic_record "$bmh")

  if ! is_detached "$bmh"; then
    mgmt annotate bmh "$bmh" -n "$METAL3_NS" baremetalhost.metal3.io/detached="" --overwrite >/dev/null
    wait_for 120 "$bmh detached" is_detached "$bmh" || return 1
    echo "  detached"
    rec=$(ironic_record "$bmh")   # detaching can remove the record already
  fi

  if [ -n "$rec" ]; then
    uuid=${rec%% *}
    code=$(api PUT "/v1/nodes/$uuid/maintenance" '{"reason": "re-registering"}' | tail -1)
    echo "  Ironic maintenance on for $uuid: $code"
    code=$(api DELETE "/v1/nodes/$uuid" | tail -1)
    echo "  Ironic record $uuid deleted: $code"
    wait_for 120 "Ironic record of $bmh removed" record_gone "$bmh" || return 1
  fi

  mgmt annotate bmh "$bmh" -n "$METAL3_NS" baremetalhost.metal3.io/detached- >/dev/null
  echo "  re-attached, waiting for register + adopt"
  if wait_for "$TIMEOUT_S" "$bmh consistent" is_consistent "$bmh"; then
    echo "  OK: BMH ID $(bmh_field "$bmh" '{.status.provisioning.ID}') = Ironic record, active"
  else
    echo "  NOT consistent: BMH $(bmh_field "$bmh" '{.status.operationalStatus}') / $(bmh_field "$bmh" '{.status.errorMessage}'); Ironic: $(ironic_record "$bmh")" >&2
    return 1
  fi
}

rc=0
for h in "${HOSTS[@]}"; do reregister "$h" || rc=1; done
exit "$rc"
