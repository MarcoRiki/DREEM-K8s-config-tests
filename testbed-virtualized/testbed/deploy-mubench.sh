#!/usr/bin/env bash
# Builds the muBench manifests from SimulationWorkspace/workmodel.json and applies
# them to the workload cluster, so every run deploys exactly the same application.
#
#   * anchors (services named a<letter>) get the required node affinity chosen with
#     --anchors: big | small | any | mixed. mixed alternates in name order: aa and ac on
#     big, ab and ad on small, so two pairs sit on each size. The workmodel keeps "big";
#     the rendered copy used for the deployment is saved in the output folder with the
#     manifests.
#   * HorizontalPodAutoscalers only for the heavy services (s<N>) and gw-nginx;
#     probes (p<letter>) and anchors keep a fixed replica count.
#   * every deployment is restarted, so the new workmodel ConfigMap is loaded.
#
# Usage: ./deploy-mubench.sh [--anchors=big|small|any|mixed] [--out=DIR] [--render-only]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
MUBENCH="$(cd "$HERE/../muBench" && pwd)"
PYTHON=${PYTHON:-$MUBENCH/.venv/bin/python3}
[ -x "$PYTHON" ] || PYTHON=python3

usage() { awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; }

ANCHORS=big; OUT=""; RENDER_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --anchors=*)   ANCHORS="${arg#--anchors=}" ;;
    --out=*)       OUT="${arg#--out=}" ;;
    --render-only) RENDER_ONLY=true ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 1 ;;
  esac
done
case "$ANCHORS" in big|small|any|mixed) ;; *) echo "--anchors must be big, small, any or mixed" >&2; exit 1 ;; esac

OUT=${OUT:-$(mktemp -d)}
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
rm -rf "$OUT/yamls"   # never apply manifests left over from an earlier render
NAMESPACE=$(jq -r '.K8sParameters.namespace' "$MUBENCH/Configs/K8sParameters.json")

echo "rendering the workmodel (anchors: $ANCHORS) into $OUT"
python3 - "$MUBENCH/SimulationWorkspace/workmodel.json" "$OUT/workmodel.json" "$ANCHORS" <<'EOF'
import json, re, sys
src, dst, anchors = sys.argv[1:]
wm = json.load(open(src))
anchor_names = sorted(s for s in wm if re.fullmatch(r"a[a-z]", s))
probe_names = sorted(s for s in wm if re.fullmatch(r"p[a-z]", s))
if not anchor_names or not probe_names:
    sys.exit("the workmodel has no probe (p<letter>) or anchor (a<letter>) services")
for i, s in enumerate(anchor_names):
    wm[s].pop("required_node_labels", None)
    size = ("big", "small")[i % 2] if anchors == "mixed" else anchors
    if size != "any":
        wm[s]["required_node_labels"] = {"size": [size]}
for p in probe_names:
    unknown = [t for t in wm[p].get("preferred_pod_affinity", {}) if t not in wm]
    if unknown:
        sys.exit(f"{p} prefers unknown service(s) {unknown}")
json.dump(wm, open(dst, "w"), indent=2)
for s in anchor_names:
    print(f"  {s}: {wm[s].get('required_node_labels', 'no node constraint')}")
for p in probe_names:
    print(f"  {p}: prefers {wm[p].get('preferred_pod_affinity')}")
EOF

# The same builder calls as RunK8sDeployer.create_deployment_config, without importing
# its deployer module (it needs the kubernetes Python client): kubectl applies below.
if ! (cd "$MUBENCH" && "$PYTHON" - "$OUT" "$MUBENCH/Configs/K8sParameters.json" <<'EOF'
import json, sys
sys.path.insert(0, "Deployers/K8sDeployer")
import K8sYamlBuilder
out, params_file = sys.argv[1], sys.argv[2]
params = json.load(open(params_file))
k8s = params["K8sParameters"]
workmodel = json.load(open(f"{out}/workmodel.json"))
K8sYamlBuilder.customization_work_model(workmodel, k8s)
K8sYamlBuilder.create_deployment_service_yaml_files(workmodel, k8s, {}, out)
K8sYamlBuilder.create_workmodel_configmap_yaml_file(workmodel, k8s, {}, out)
K8sYamlBuilder.create_internalservice_configmap_yaml_file(k8s, {}, out, params["InternalServiceFilePath"])
EOF
     ) > "$OUT/build.log" 2>&1; then
  tail -20 "$OUT/build.log" >&2
  echo "ERROR: manifest generation failed, see $OUT/build.log" >&2
  exit 1
fi

mapfile -t ALL   < <(jq -r 'keys[]' "$OUT/workmodel.json")
mapfile -t HEAVY < <(jq -r 'keys[] | select(test("^s[0-9]+$"))' "$OUT/workmodel.json")
mapfile -t FIXED < <(jq -r 'keys[] | select(test("^[ap][a-z]$"))' "$OUT/workmodel.json")

"$PYTHON" - "$MUBENCH/Add-on/HPA/hpa-template.yaml" "$OUT/hpa.yaml" "$NAMESPACE" "${HEAVY[@]}" gw-nginx <<'EOF'
import copy, sys, yaml
template, out, namespace, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
base = yaml.safe_load(open(template))
docs = []
for name in names:
    hpa = copy.deepcopy(base)
    hpa["metadata"] = {"name": name, "namespace": namespace}
    hpa["spec"]["scaleTargetRef"]["name"] = name
    docs.append(hpa)
yaml.safe_dump_all(docs, open(out, "w"), sort_keys=False)
EOF
echo "manifests: $(ls "$OUT/yamls" | wc -l) files, HPAs for: ${HEAVY[*]} gw-nginx"

if $RENDER_ONLY; then
  echo "render only: nothing applied"
  exit 0
fi

echo "applying to namespace $NAMESPACE"
for f in "$OUT"/yamls/*ConfigMap*.yaml; do workload apply -f "$f" >/dev/null; done
workload apply -f "$OUT/yamls/" >/dev/null
workload apply -f "$OUT/hpa.yaml" >/dev/null
workload delete hpa -n "$NAMESPACE" "${FIXED[@]}" --ignore-not-found >/dev/null

EXTRA=$(comm -13 <(printf '%s\n' "${ALL[@]}" gw-nginx | sort) \
                 <(workload get deploy -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort))
[ -z "$EXTRA" ] || echo "WARNING: deployments not in the workmodel are still running: $EXTRA"

GW_WANT=$(jq -r '.RunnerParameters.ms_access_gateway' "$MUBENCH/Configs/RunnerParameters.json" | sed -E 's#.*:([0-9]+)/?$#\1#')
GW_HAVE=$(workload get svc gw-nginx -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')
[ "$GW_WANT" = "$GW_HAVE" ] || { echo "ERROR: gw-nginx NodePort $GW_HAVE, RunnerParameters uses $GW_WANT" >&2; exit 1; }

echo "restarting every deployment to load the new workmodel"
workload rollout restart deployment -n "$NAMESPACE" "${ALL[@]}" gw-nginx >/dev/null
for d in "${ALL[@]}" gw-nginx; do
  workload rollout status deployment "$d" -n "$NAMESPACE" --timeout=15m >/dev/null
done
echo "deployed: ${ALL[*]}"
