#!/usr/bin/env python3
"""Bring every probe back onto its anchor's node.

Preferred pod affinity is IgnoredDuringExecution: once a drain has separated a probe
from its anchor, nothing moves it back, not even when the anchor's node has room again.
The probe then pays the injected network delay on all ten calls of every request for the
rest of the arm. This script is that missing repair: it deletes a probe pod that sits
away from its anchor when the anchor's node can take it, and the scheduler puts the
replacement next to the anchor, because that node scores highest for its weight-100
preference.

Only probe pods are ever deleted. Anchors and heavy services are never touched: moving
an anchor would break the pair it hosts, and the heavy services' preferred node affinity
is a separate repair (the Kubernetes descheduler covers that one).

Capacity is checked the way the kube-scheduler does: allocatable minus the requests of
the pods already on the node, with init containers accounted for and native sidecars
(restartPolicy Always, e.g. istio-proxy) added to the pod's own requests.

Usage:
  ./repair-pairs.py --dry-run                 # what it would do, changes nothing
  ./repair-pairs.py                           # one pass
  ./repair-pairs.py --interval=600            # a pass every 10 minutes until stopped

Options:
  --workmodel=PATH     where the probe -> anchor pairs come from
                       (default: $MUBENCH/SimulationWorkspace/workmodel.json; a run's
                       deploy/workmodel.json describes exactly what was deployed)
  --namespace=NS       application namespace (default: from muBench's K8sParameters.json)
  --max-per-pass=N     probes to move in one pass (default 1: one restart at a time)
  --interval=SECONDS   keep running, one pass every SECONDS (default: a single pass)
  --kubeconfig=PATH    workload cluster (default: $WORKLOAD_KUBECONFIG, ~/workload.kubeconfig)
  --dry-run            report only

Run it with the same settings in every arm of a comparison, or the arms are not
comparable: the repair changes placement, restarts and latency.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
MUBENCH = Path(os.environ.get("MUBENCH", HERE.parents[2] / "muBench"))   # one level above the repository root
DEFAULT_WORKMODEL = MUBENCH / "SimulationWorkspace" / "workmodel.json"
K8S_PARAMETERS = MUBENCH / "Configs" / "K8sParameters.json"


def log(message):
    print(f"[{datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ}] {message}", flush=True)


def kubectl(kubeconfig, *args, check=True):
    result = subprocess.run(["kubectl", f"--kubeconfig={kubeconfig}", *args],
                            capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SystemExit(f"kubectl {' '.join(args)} failed: {result.stderr.strip()}")
    return result


def kubectl_json(kubeconfig, *args):
    return json.loads(kubectl(kubeconfig, *args, "-o", "json").stdout)


def quantity(value):
    """A CPU or memory quantity in millicores / bytes."""
    if value is None:
        return 0
    text = str(value)
    if text.endswith("m"):
        return int(float(text[:-1]))
    units = {"Ki": 2 ** 10, "Mi": 2 ** 20, "Gi": 2 ** 30, "Ti": 2 ** 40,
             "K": 10 ** 3, "M": 10 ** 6, "G": 10 ** 9, "T": 10 ** 12}
    for suffix, factor in units.items():
        if text.endswith(suffix):
            return int(float(text[: -len(suffix)]) * factor)
    return int(float(text) * 1000) if "." in text or text.isdigit() else 0


def pod_requests(pod):
    """(cpu millicores, memory bytes) requested by a pod, as the scheduler counts them.

    Native sidecars - init containers with restartPolicy Always, such as istio-proxy -
    keep running next to the app containers, so their requests add to the total; a
    regular init container only has to fit next to the sidecars declared before it.
    """
    spec = pod.get("spec", {})
    cpu = mem = 0
    for container in spec.get("containers", []):
        req = container.get("resources", {}).get("requests", {})
        cpu += quantity(req.get("cpu"))
        mem += quantity(req.get("memory"))

    sidecar_cpu = sidecar_mem = 0
    init_cpu = init_mem = 0
    for container in spec.get("initContainers", []):
        req = container.get("resources", {}).get("requests", {})
        if container.get("restartPolicy") == "Always":
            sidecar_cpu += quantity(req.get("cpu"))
            sidecar_mem += quantity(req.get("memory"))
            continue
        init_cpu = max(init_cpu, quantity(req.get("cpu")) + sidecar_cpu)
        init_mem = max(init_mem, quantity(req.get("memory")) + sidecar_mem)

    return max(cpu + sidecar_cpu, init_cpu), max(mem + sidecar_mem, init_mem)


def probe_pairs(workmodel_path):
    """{probe: anchor} from the workmodel: a probe is p<letter>, its anchor the service
    its preferred pod affinity points at."""
    workmodel = json.loads(Path(workmodel_path).read_text())
    pairs = {}
    for service, spec in workmodel.items():
        if not re.fullmatch(r"p[a-z]", service):
            continue
        preferred = spec.get("preferred_pod_affinity") or {}
        if not preferred:
            continue
        pairs[service] = max(preferred, key=preferred.get)
    if not pairs:
        raise SystemExit(f"{workmodel_path} has no probe (p<letter>) with a preferred_pod_affinity")
    return pairs


def usable_nodes(kubeconfig):
    """{node name: [free cpu millicores, free memory bytes]} for the Ready, schedulable
    workers, allocatable minus everything already requested on them."""
    free = {}
    for node in kubectl_json(kubeconfig, "get", "nodes")["items"]:
        labels = node["metadata"].get("labels", {})
        if "node-role.kubernetes.io/control-plane" in labels or "node-role.kubernetes.io/master" in labels:
            continue
        if node["spec"].get("unschedulable"):
            continue
        ready = any(c["type"] == "Ready" and c["status"] == "True"
                    for c in node["status"].get("conditions", []))
        if not ready:
            continue
        allocatable = node["status"]["allocatable"]
        free[node["metadata"]["name"]] = [quantity(allocatable["cpu"]), quantity(allocatable["memory"])]

    for pod in kubectl_json(kubeconfig, "get", "pods", "--all-namespaces")["items"]:
        node = pod["spec"].get("nodeName")
        if node not in free or pod["status"].get("phase") in ("Succeeded", "Failed"):
            continue
        cpu, mem = pod_requests(pod)
        free[node][0] -= cpu
        free[node][1] -= mem
    return free


def one_pass(args, pairs):
    pods = kubectl_json(args.kubeconfig, "get", "pods", "-n", args.namespace)["items"]
    by_app = {}
    for pod in pods:
        if pod["metadata"].get("deletionTimestamp") or pod["status"].get("phase") in ("Succeeded", "Failed"):
            continue
        by_app.setdefault(pod["metadata"].get("labels", {}).get("app"), []).append(pod)

    free = usable_nodes(args.kubeconfig)
    moved = 0
    for probe, anchor in sorted(pairs.items()):
        if moved >= args.max_per_pass:
            log(f"{args.max_per_pass} probe(s) moved in this pass, the rest waits for the next one")
            break

        anchor_nodes = {p["spec"].get("nodeName") for p in by_app.get(anchor, [])
                        if p["status"].get("phase") == "Running"}
        if not anchor_nodes:
            log(f"{probe}: its anchor {anchor} is not running anywhere, skipped")
            continue

        for pod in by_app.get(probe, []):
            node = pod["spec"].get("nodeName")
            if node in anchor_nodes:
                continue   # already with its anchor
            if pod["status"].get("phase") != "Running":
                log(f"{probe}: {pod['metadata']['name']} is {pod['status'].get('phase')}, skipped")
                continue

            cpu, mem = pod_requests(pod)
            targets = [n for n in anchor_nodes if n in free and free[n][0] >= cpu and free[n][1] >= mem]
            if not targets:
                room = ", ".join(f"{n}: {free[n][0]}m free" if n in free else f"{n}: not schedulable"
                                 for n in sorted(anchor_nodes))
                log(f"{probe} on {node}, away from {anchor}, but no room for {cpu}m ({room})")
                continue

            target = targets[0]
            if args.dry_run:
                log(f"would delete {pod['metadata']['name']} on {node}: {anchor} runs on {target}, "
                    f"{free[target][0]}m free for the {cpu}m it needs")
            else:
                kubectl(args.kubeconfig, "delete", "pod", "-n", args.namespace,
                        pod["metadata"]["name"], "--wait=false")
                log(f"deleted {pod['metadata']['name']} on {node} so it can rejoin {anchor} on {target}")
                free[target][0] -= cpu
                free[target][1] -= mem
            moved += 1
            break   # one replica of this probe per pass
    if moved == 0:
        log("every probe is with its anchor, or no anchor node has room")
    return moved


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--workmodel", default=str(DEFAULT_WORKMODEL))
    parser.add_argument("--namespace")
    parser.add_argument("--max-per-pass", type=int, default=1)
    parser.add_argument("--interval", type=int, default=0)
    parser.add_argument("--kubeconfig", default=os.environ.get(
        "WORKLOAD_KUBECONFIG", str(Path.home() / "workload.kubeconfig")))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    args = parser.parse_args()
    if args.help:
        print(__doc__)
        return 0

    if not args.namespace:
        args.namespace = json.loads(K8S_PARAMETERS.read_text())["K8sParameters"]["namespace"]

    pairs = probe_pairs(args.workmodel)
    log(f"probe -> anchor pairs: {pairs} (namespace {args.namespace}, "
        f"{'dry run' if args.dry_run else 'deleting at most %d probe(s) per pass' % args.max_per_pass})")

    while True:
        one_pass(args, pairs)
        if args.interval <= 0:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
