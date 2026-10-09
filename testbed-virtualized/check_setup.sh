#!/usr/bin/env bash
# Checks that everything the tests need is in place, without changing anything:
#
#   host            tools, passwordless sudo, libvirt VMs, provisioning bridge
#   checkouts       metal3-dev-env and muBench at the pinned commits with the changes
#                   applied, muBench's traces, inputs and .venv
#   management      Cluster API / Metal3 / Ironic, BareMetalHosts, the worker
#                   MachineDeployment (Cluster Autoscaler bounds, labels at join),
#                   Cluster Autoscaler and Karpenter installed and switched off
#   workload        nodes, Calico, metrics API, Istio, Prometheus (reachable as the
#                   export uses it), Grafana and the µBench dashboard, DREEM installed and
#                   switched off, Karpenter's CRDs and NodePool
#   testbed         profiles.json against the BareMetalHosts and the nodes, the muBench
#                   gateway address
#
# Every line is OK, WARN (works, but look at it: e.g. a scaler left on) or FAIL (the
# tests cannot run). The exit code is 1 when anything FAILs.
#
# Usage: ./check_setup.sh
# MGMT_KUBECONFIG (default ~/.kube/config), WORKLOAD_KUBECONFIG (default ~/workload.kubeconfig),
# METAL3_DEV_ENV (default <repo>/metal3-dev-env).

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBED="$REPO/testbed"
case "${1:-}" in -h|--help) awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;; esac
# shellcheck source=testbed/lib.sh
source "$TESTBED/lib.sh"   # mgmt, workload, cp_bmh, worker_bmhs, cp_node
set +e                     # a failed check is reported, not fatal

METAL3_DEV_ENV=${METAL3_DEV_ENV:-$REPO/metal3-dev-env}
MUBENCH=$REPO/muBench
MD_NAME=test-cluster-m3
CLUSTER_NAME=test-cluster-m3
PROFILES=$TESTBED/profiles.json
EXPECTED_WORKERS=$(jq '.assignments | length' "$PROFILES")
pinned() { sed -n "s/^COMMIT=\([0-9a-f]*\).*/\1/p" "$1"; }
METAL3_COMMIT=$(pinned "$REPO/metal3-dev-env_changes/apply-changes.sh")
MUBENCH_COMMIT=$(pinned "$REPO/mubench_changes/apply-changes.sh")
KARPENTER_IMAGE=$(sed -n 's/.*export KARPENTER_IMAGE=//p' "$REPO/Karpenter/karpenter.yaml" | head -1)

if [ -t 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'; else G=; Y=; R=; B=; N=; fi
OKS=0; WARNS=0; FAILS=0
ok()      { printf '  %sOK%s    %s\n' "$G" "$N" "$*"; OKS=$((OKS + 1)); }
warn()    { printf '  %sWARN%s  %s\n' "$Y" "$N" "$*"; WARNS=$((WARNS + 1)); }
fail()    { printf '  %sFAIL%s  %s\n' "$R" "$N" "$*"; FAILS=$((FAILS + 1)); }
section() { printf '\n%s== %s%s\n' "$B" "$*" "$N"; }
# check <description> <command...>: OK when the command succeeds, FAIL otherwise
check()   { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else fail "$what"; fi; }

# --- host ------------------------------------------------------------------------------

section "Host"
for t in kubectl clusterctl helm jq envsubst python3 git curl unzip virsh docker minikube; do
  if command -v "$t" >/dev/null; then ok "$t found"; else fail "$t not found"; fi
done
check "passwordless sudo (the tests power VMs with sudo -n virsh)" sudo -n true
VMS=$(sudo -n virsh list --all --name 2>/dev/null | grep -c . || true)
RUNNING=$(sudo -n virsh list --state-running --name 2>/dev/null | grep -c . || true)
if [ "${VMS:-0}" -ge $((EXPECTED_WORKERS + 1)) ]; then ok "libvirt: $VMS VMs defined, $RUNNING running"
else fail "libvirt: ${VMS:-0} VMs defined, expected at least $((EXPECTED_WORKERS + 1)) (control plane + workers)"; fi
check "provisioning bridge present" ip link show provisioning
if systemctl is-enabled metal3-provisioning-net.service >/dev/null 2>&1; then ok "metal3-provisioning-net.service enabled (bridge survives a reboot)"
else warn "metal3-provisioning-net.service not enabled: a reboot loses the provisioning bridge (metal3-dev-env_changes/README.md)"; fi

# --- checkouts -------------------------------------------------------------------------

same_files() {   # changes-dir checkout: the files of <changes>/files are identical in the checkout
  local changes=$1 dir=$2 f bad=()
  while read -r f; do cmp -s "$changes/files/$f" "$dir/$f" || bad+=("$f"); done \
    < <(cd "$changes/files" && find . -type f | sed 's|^\./||')
  [ "${#bad[@]}" -eq 0 ] && return 0
  echo "${bad[*]}"; return 1
}
checkout() {   # name dir commit changes-dir
  local name=$1 dir=$2 commit=$3 changes=$4 head diff
  if [ ! -d "$dir/.git" ]; then fail "$name: no checkout at $dir (run $changes/apply-changes.sh)"; return 1; fi
  head=$(git -C "$dir" rev-parse HEAD)
  if [ "$head" = "$commit" ]; then ok "$name at the pinned commit ${commit:0:10}"
  else fail "$name at ${head:0:10}, pinned ${commit:0:10}"; fi
  if diff=$(same_files "$changes" "$dir"); then ok "$name: changes applied ($(cd "$changes/files" && find . -type f | wc -l) files)"
  else fail "$name: changes missing or different: $diff (run $changes/apply-changes.sh)"; fi
}

section "Checkouts"
if [ -d "$METAL3_DEV_ENV/.git" ]; then
  checkout metal3-dev-env "$METAL3_DEV_ENV" "$METAL3_COMMIT" "$REPO/metal3-dev-env_changes"
else
  warn "metal3-dev-env: no checkout at $METAL3_DEV_ENV (set METAL3_DEV_ENV if it lives elsewhere)"
fi
if checkout muBench "$MUBENCH" "$MUBENCH_COMMIT" "$REPO/mubench_changes"; then
  check "muBench: Alibaba traces unzipped" test -d "$MUBENCH/Examples/Alibaba/traces-mbench/par"
  check "muBench: .venv with the Runner's dependencies" "$MUBENCH/.venv/bin/python3" -c 'import argcomplete, requests, yaml'
  missing=$(cd "$MUBENCH" && for f in $(jq -r '.RunnerParameters.workload_files_path_list[]' Configs/RunnerParameters.json); do [ -s "$f" ] || echo "$f"; done)
  if [ -z "$missing" ]; then ok "muBench: every workload file of RunnerParameters.json present"
  else fail "muBench: workload files missing: $(echo $missing)"; fi
  check "muBench: work model present" test -s "$MUBENCH/SimulationWorkspace/workmodel.json"
fi

# --- management cluster ----------------------------------------------------------------

section "Management cluster ($MGMT_KUBECONFIG)"
if check_mgmt_cluster >/dev/null 2>&1; then
  ok "reachable, serves BareMetalHosts"
  not_ready=$(mgmt get deploy -A -o json | jq -r '.items[]
      | select(.metadata.namespace | test("^(capi-|capm3-|baremetal-operator-|metal3-ipam-|cert-manager)"))
      | select((.status.readyReplicas // 0) < .spec.replicas) | "\(.metadata.namespace)/\(.metadata.name)"')
  if [ -z "$not_ready" ]; then ok "Cluster API, Metal3, Ironic, IPAM and cert-manager controllers ready"
  else fail "controllers not ready: $(echo $not_ready)"; fi
  phase=$(mgmt get cluster "$CLUSTER_NAME" -n "$METAL3_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$phase" = Provisioned ] && ok "Cluster $CLUSTER_NAME provisioned" || fail "Cluster $CLUSTER_NAME: ${phase:-missing}"

  bmhs=$(mgmt get bmh -n "$METAL3_NS" -o json)
  mapfile -t WORKERS < <(worker_bmhs 2>/dev/null)
  [ "${#WORKERS[@]}" -eq "$EXPECTED_WORKERS" ] && ok "${#WORKERS[@]} worker BareMetalHosts (control plane: $(cp_bmh 2>/dev/null))" \
    || fail "${#WORKERS[@]} worker BareMetalHosts, profiles.json describes $EXPECTED_WORKERS"
  errors=$(jq -r '.items[] | select((.status.errorType // "") != "") | "\(.metadata.name): \(.status.errorType)"' <<<"$bmhs")
  [ -z "$errors" ] && ok "no BareMetalHost in error" || fail "BareMetalHosts in error: $(echo $errors)"
  states=$(jq -r '[.items[] | .status.provisioning.state] | group_by(.) | map("\(length) \(.[0])") | join(", ")' <<<"$bmhs")
  detached=$(jq '[.items[] | select(.status.operationalStatus == "detached")] | length' <<<"$bmhs")
  ok "BareMetalHost states: $states"
  [ "$detached" -le 1 ] || warn "$detached BareMetalHosts detached (left by a DREEM run; test_CA.sh and test_Karpenter.sh re-attach them)"

  md=$(mgmt get md "$MD_NAME" -n "$METAL3_NS" -o json 2>/dev/null)
  if [ -n "$md" ]; then
    ok "MachineDeployment $MD_NAME: $(jq -r '"\(.spec.replicas) replicas, \(.status.readyReplicas // 0) ready"' <<<"$md")"
    bounds=$(jq -r '.metadata.annotations | "\(.["cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size"])/\(.["cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size"])/\(.["cluster.x-k8s.io/autoscaling-options-scaledownutilizationthreshold"])"' <<<"$md")
    [ "$bounds" = "3/8/0.4" ] && ok "Cluster Autoscaler bounds on $MD_NAME: min 3, max 8, threshold 0.4" \
      || fail "Cluster Autoscaler bounds on $MD_NAME are min/max/threshold $bounds, expected 3/8/0.4 (CA/README.md)"
    m3mt=$(jq -r '.spec.template.spec.infrastructureRef.name' <<<"$md")
    kct=$(jq -r '.spec.template.spec.bootstrap.configRef.name' <<<"$md")
    dt=$(mgmt get metal3machinetemplate "$m3mt" -n "$METAL3_NS" -o jsonpath='{.spec.template.spec.dataTemplate.name}')
    if mgmt get metal3datatemplate "$dt" -n "$METAL3_NS" -o json | jq -e '[.spec.metaData.fromAnnotations[]? | select(.object == "baremetalhost") | .key] as $k | ($k | index("group")) != null and ($k | index("size")) != null' >/dev/null \
       && mgmt get kubeadmconfigtemplate "$kct" -n "$METAL3_NS" -o json | grep -q 'ds.meta_data.size'; then
      ok "labels at join: data template $dt and bootstrap $kct give new nodes size and group"
    else
      fail "labels at join not configured (run testbed/init-testbed.sh)"
    fi
  else
    fail "MachineDeployment $MD_NAME missing"
  fi

  # Cluster Autoscaler
  ca=$(mgmt get deploy cluster-autoscaler -n kube-system -o json 2>/dev/null)
  if [ -n "$ca" ]; then
    replicas=$(jq '.spec.replicas' <<<"$ca")
    [ "$replicas" = 0 ] && ok "Cluster Autoscaler installed, switched off" || warn "Cluster Autoscaler running ($replicas replicas): only test_CA.sh should switch it on"
    live=$(jq -r '.spec.template.spec.containers[0].args[]' <<<"$ca" | sort)
    want=$(sed -n 's/^ *- \(--.*\)$/\1/p' "$REPO/CA/ca.yaml" | sort)
    [ "$live" = "$want" ] && ok "Cluster Autoscaler flags as in CA/ca.yaml" \
      || warn "Cluster Autoscaler flags differ from CA/ca.yaml: $(comm -3 <(echo "$want") <(echo "$live") | xargs) (re-apply CA/ca.yaml)"
  else
    fail "Cluster Autoscaler not installed (CA/README.md)"
  fi
  check "workload kubeconfig secret for CA and Karpenter (kube-system/dreem-mmiracapillo-cluster-kubeconfig)" \
    mgmt get secret dreem-mmiracapillo-cluster-kubeconfig -n kube-system -o jsonpath='{.data.value}'

  # Karpenter
  kp=$(mgmt get deploy karpenter -n kube-system -o json 2>/dev/null)
  if [ -n "$kp" ]; then
    replicas=$(jq '.spec.replicas' <<<"$kp")
    [ "$replicas" = 0 ] && ok "Karpenter installed, switched off" || warn "Karpenter running ($replicas replicas): only test_Karpenter.sh should switch it on"
    image=$(jq -r '.spec.template.spec.containers[0].image' <<<"$kp")
    [ "$image" = "$KARPENTER_IMAGE" ] && ok "Karpenter image pinned (9dc28cf, digest)" || warn "Karpenter image $image, pinned $KARPENTER_IMAGE"
    check "Karpenter management kubeconfig and Cluster API role" mgmt get configmap karpenter-mgmt-kubeconfig -n kube-system
    if mgmt get md "$MD_NAME-karpenter" -n "$METAL3_NS" >/dev/null 2>&1; then
      warn "Karpenter's MachineDeployment $MD_NAME-karpenter left over (the next test script removes it)"
    else ok "no Karpenter MachineDeployment left over"; fi
  else
    fail "Karpenter not installed (Karpenter/README.md)"
  fi
else
  fail "MGMT_KUBECONFIG=$MGMT_KUBECONFIG does not reach the management cluster"
fi

# --- workload cluster ------------------------------------------------------------------

section "Workload cluster ($WORKLOAD_KUBECONFIG)"
if check_workload_cluster >/dev/null 2>&1; then
  ok "reachable"
  nodes=$(workload get nodes -o json)
  cp_ready=$(jq '[.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null)
                  | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$nodes")
  w_ready=$(jq '[.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == null)
                 | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$nodes")
  [ "$cp_ready" = 1 ] && ok "control plane Ready" || fail "$cp_ready control-plane nodes Ready"
  if [ "$w_ready" -eq "$EXPECTED_WORKERS" ]; then ok "$w_ready workers Ready"
  else warn "$w_ready/$EXPECTED_WORKERS workers Ready (after a CA or Karpenter run; test.sh restores the fleet)"; fi
  version=$(jq -r '[.items[].status.nodeInfo.kubeletVersion] | unique | join(",")' <<<"$nodes")
  [ "$version" = v1.33.7 ] && ok "Kubernetes $version" || warn "Kubernetes $version (the experiments ran on v1.33.7)"

  ds_ready() { workload get ds "$2" -n "$1" -o json | jq -e '.status.numberReady == .status.desiredNumberScheduled and .status.desiredNumberScheduled > 0'; }
  dep_ready() { workload get deploy "$2" -n "$1" -o json | jq -e '(.status.availableReplicas // 0) >= 1'; }
  check "Calico running on every node" ds_ready kube-system calico-node
  check "metrics API answers (HPA)" workload get --raw /apis/metrics.k8s.io/v1beta1/nodes
  check "Istio: istiod available" dep_ready istio-system istiod
  [ "$(workload get ns default -o jsonpath='{.metadata.labels.istio-injection}')" = enabled ] \
    && ok "Istio sidecar injection on in namespace default" || fail "namespace default lacks istio-injection=enabled"

  # monitoring
  CPN=$(cp_node 2>/dev/null)
  prom_node=$(workload get pod -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
  [ -n "$prom_node" ] && [ "$prom_node" = "$CPN" ] && ok "Prometheus runs on the control plane" \
    || fail "Prometheus pod on '${prom_node:-none}', expected the control plane $CPN (mubench_changes/monitoring/install-monitoring.sh)"
  PROXY=/api/v1/namespaces/monitoring/services/prometheus-kube-prometheus-prometheus:9090/proxy/api/v1/query
  up=$(workload get --raw "$PROXY?query=count(up%7Bjob%3D%22node-exporter%22%7D%3D%3D1)" 2>/dev/null | jq -r '.data.result[0].value[1] // 0')
  if [ "${up:-0}" -ge 1 ]; then ok "Prometheus answers through the API server (export-metrics.py); node-exporter up on $up nodes"
  else fail "Prometheus not reachable through the API server, or no node-exporter target up"; fi
  retention=$(workload get prometheus -n monitoring -o jsonpath='{.items[0].spec.retention}' 2>/dev/null)
  [ "$retention" = 10d ] && ok "Prometheus retention 10d (export a run within 10 days)" || warn "Prometheus retention ${retention:-unknown}"
  check "PodMonitor mub-monitor scrapes the muBench pods" workload get podmonitor mub-monitor -n default
  check "Grafana available" dep_ready monitoring prometheus-grafana
  # the dashboard, through a short port-forward with the admin credentials (never printed)
  PORT=$((38100 + RANDOM % 800))
  workload -n monitoring port-forward svc/prometheus-grafana "$PORT:80" >/dev/null 2>&1 & PF=$!
  for _ in $(seq 20); do curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null && break; sleep 0.5; done
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -u "$(workload -n monitoring get secret prometheus-grafana -o jsonpath='{.data.admin-user}' | base64 -d):$(workload -n monitoring get secret prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d)" \
    "http://127.0.0.1:$PORT/apis/dashboard.grafana.app/v2/namespaces/default/dashboards/$(jq -r .metadata.name "$REPO/mubench_changes/monitoring/mubench-dashboard.json")")
  kill "$PF" 2>/dev/null
  [ "$code" = 200 ] && ok "µBench dashboard in Grafana" || warn "µBench dashboard not found in Grafana (HTTP $code): mubench_changes/monitoring/import-dashboard.sh"

  # DREEM
  if workload get ns dreem >/dev/null 2>&1; then
    for d in dreem-controller-manager forecast-deployment; do
      r=$(workload get deploy "$d" -n dreem -o jsonpath='{.spec.replicas}' 2>/dev/null)
      if [ -z "$r" ]; then fail "DREEM: deployment $d missing"
      elif [ "$r" = 0 ]; then ok "DREEM: $d installed, switched off"
      else warn "DREEM: $d running ($r replicas): test.sh switches it on and off per arm"; fi
    done
    enabled=$(workload get cm forecast-parameters -n dreem -o jsonpath='{.data.Enabled}' 2>/dev/null)
    case "$enabled" in
      false) ok "DREEM: forecaster disabled (forecast-parameters Enabled=false)" ;;
      true)  warn "DREEM: forecaster enabled (forecast-parameters Enabled=true)" ;;
      *)     fail "DREEM: ConfigMap forecast-parameters missing" ;;
    esac
    bounds=$(workload get cm cluster-configuration-parameters -n dreem -o jsonpath='{.data.minNodes}/{.data.maxNodes}' 2>/dev/null)
    [ "$bounds" = 3/8 ] && ok "DREEM: minNodes 3, maxNodes 8" || fail "DREEM: cluster-configuration-parameters minNodes/maxNodes '$bounds', expected 3/8"
    crds=$(workload get crd -o name | grep -c 'cluster.dreemk8s$')
    [ "$crds" -ge 3 ] && ok "DREEM: CRDs installed ($crds)" || fail "DREEM: $crds CRDs of group cluster.dreemk8s"
    sa=$(workload get deploy dreem-controller-manager -n dreem -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)
    sa="system:serviceaccount:dreem:${sa:-default}"
    if workload auth can-i patch nodes --as="$sa" >/dev/null 2>&1 \
       && workload auth can-i create pods --subresource=eviction -n default --as="$sa" >/dev/null 2>&1; then
      ok "DREEM: may cordon and drain"
    else fail "DREEM: $sa may not patch nodes or evict pods in default (needed to cordon and drain)"; fi
    missing=()
    for n in $(workload get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}'); do
      workload get secret "bmc-credentials-$n" -n dreem >/dev/null 2>&1 || missing+=("$n")
    done
    [ "${#missing[@]}" -eq 0 ] && ok "DREEM: BMC secret for every worker" \
      || warn "DREEM: no BMC secret for ${missing[*]} (test.sh rebuilds them; or testbed/sync-bmc-secrets.sh)"
  else
    fail "DREEM not installed (namespace dreem missing, see DREEM/README.md)"
  fi

  # Karpenter, workload side
  crds=$(workload get crd -o name | grep -cE 'nodepools.karpenter.sh|nodeclaims.karpenter.sh|clusterapinodeclasses.karpenter.cluster.x-k8s.io')
  [ "$crds" = 3 ] && ok "Karpenter: CRDs installed" || fail "Karpenter: $crds of 3 CRDs (Karpenter/crds/)"
  limit=$(workload get nodepool metal3 -o jsonpath='{.spec.limits.cpu}' 2>/dev/null)
  if [ -n "$limit" ] && workload get clusterapinodeclass metal3 >/dev/null 2>&1; then
    want=$(( (EXPECTED_WORKERS - 3) * $(jq '.cores_per_node' "$PROFILES") ))
    [ "$limit" = "$want" ] && ok "Karpenter: NodePool and node class metal3, limit $limit CPUs" \
      || fail "Karpenter: NodePool limit $limit CPUs, expected $want"
  else
    fail "Karpenter: NodePool or ClusterAPINodeClass metal3 missing (Karpenter/nodepool.yaml)"
  fi
  claims=$(workload get nodeclaims --no-headers 2>/dev/null | grep -c .)
  [ "${claims:-0}" = 0 ] && ok "Karpenter: no NodeClaims" || warn "Karpenter: $claims NodeClaims left (the next test script removes them)"

  # testbed: profiles on the hosts and the nodes
  section "Testbed (profiles.json, gateway)"
  if [ "$(printf '%s\n' "${WORKERS[@]}" | sort)" = "$(jq -r '.assignments | keys[]' "$PROFILES" | sort)" ]; then
    ok "profiles.json describes the live worker BareMetalHosts"
  else
    fail "profiles.json does not match the worker BareMetalHosts (testbed/init-testbed.sh --regenerate-profiles)"
  fi
  wrong=$(jq -r --slurpfile p "$PROFILES" '.items[] | .metadata.name as $n | $p[0].assignments[$n] as $a | select($a != null)
      | .metadata.annotations as $an
      | select(($an["dreemk8s.io/size"] // $an.size) != $a.size or $an["dreemk8s.io/consumption-profile"] != ($a.consumption_profile | tostring)
               or $an["dreemk8s.io/group"] != $a.group) | $n' <<<"$bmhs")
  [ -z "$wrong" ] && ok "BareMetalHost annotations match profiles.json" \
    || fail "BareMetalHost annotations differ from profiles.json: $(echo $wrong) (testbed/assign-profiles.sh)"
  unlabeled=$(jq -r --slurpfile n <(echo "$nodes") '.items[] | select(.spec.consumerRef.name != null) | .spec.consumerRef.name as $c
      | .metadata.annotations as $an | ($n[0].items[] | select(.metadata.name == $c)) as $node
      | select($node.metadata.labels["node-role.kubernetes.io/control-plane"] == null)
      | select($node.metadata.labels.size != ($an["dreemk8s.io/size"] // $an.size) or $node.metadata.labels.group != $an["dreemk8s.io/group"]
               or $node.metadata.annotations["dreemk8s.io/consumption-profile"] != $an["dreemk8s.io/consumption-profile"]) | $c' <<<"$bmhs")
  [ -z "$unlabeled" ] && ok "every worker node carries its host's size, group and consumption profile" \
    || warn "nodes without their host's profile: $(echo $unlabeled) (testbed/apply-profiles.sh; the test scripts run it)"
  cp_labels=$(jq -r '.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null)
      | [.metadata.labels.size, .metadata.labels.group, .metadata.annotations["dreemk8s.io/consumption-profile"]] | map(select(. != null)) | length' <<<"$nodes")
  [ "$cp_labels" = 0 ] && ok "control plane carries no profile" || fail "control plane carries size/group/profile (testbed/apply-profiles.sh)"

  if [ -f "$MUBENCH/Configs/RunnerParameters.json" ]; then
    gw=$(jq -r '.RunnerParameters.ms_access_gateway' "$MUBENCH/Configs/RunnerParameters.json")
    gw_host=$(sed -E 's#^https?://([^:/]+).*#\1#' <<<"$gw")
    cp_ip=$(jq -r '.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null)
                   | .status.addresses[] | select(.type == "InternalIP") | .address' <<<"$nodes")
    [ "$gw_host" = "$cp_ip" ] && ok "muBench gateway $gw is the control plane" \
      || fail "muBench gateway $gw, the control plane is $cp_ip: fix ms_access_gateway in muBench/Configs/RunnerParameters*.json"
  fi
else
  fail "WORKLOAD_KUBECONFIG=$WORKLOAD_KUBECONFIG does not reach the workload cluster"
fi

printf '\n%s%d OK, %d WARN, %d FAIL%s\n' "$B" "$OKS" "$WARNS" "$FAILS" "$N"
if [ "$FAILS" -gt 0 ]; then echo "Not ready: fix the FAIL lines first."; exit 1; fi
echo "Ready to run the tests (testbed/RUNNING.md)."
