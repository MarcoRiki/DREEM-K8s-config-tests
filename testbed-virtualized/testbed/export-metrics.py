#!/usr/bin/env python3
"""Exports the dashboard data the analysis notebook reads, for every arm of a run.

It runs the queries of the µBench Grafana dashboard panels directly against Prometheus,
over each arm's workload window (<ARM>_window.json in --run-dir), and writes the CSVs
with the names, columns and layout of Grafana's "Download CSV" export, so the notebook
reads them unchanged:

  Active Worker-<A>.csv                   N worker                  "Active Workers"
  Avg cluster usage-data-<B>.csv          Avg CPU usage             "Average CPU", 0-1
  Node CPU usage-data-<A>.csv             Node CPU usage            one column per ip:9100, percent
  Pending Application Pods-data-<A>.csv   Pending Application Pods  the query as column name
  Service delay-<A>.csv                   Service delay             one column per service, ms
  Service rate-<A>.csv                    Service rate (req/s)      one column per service
  Node info.csv                           Node info                 CA only, node:ip::systemUUID
  Node info-data-KARPENTER.csv            Node info                 the same for Karpenter

<A> is DREEM-QOS, DREEM-ENERGY, BASELINE, CA, KARPENTER or a BASELINE on fewer workers
(test.sh's BASELINE_N: BASELINE_6, BASELINE_7_big, ...); <B> is the same without
"DREEM-", as in the exports the notebook was written against. Node info follows the
machines of the arms that reprovision nodes; the notebook finds Karpenter's next to its
Node CPU usage file.

Time is UTC milliseconds on a 30 s grid, from --before seconds before the window to
--after seconds after it (the probes run 5 minutes past the workload). A series without
a sample is written "undefined" and a NaN value "NaN", as Grafana does; rows where no
series has a sample are left out.

Prometheus is reached through the workload cluster's API server (no port-forward), or
at --prometheus-url. It keeps 10 days of data: export a run before its first arm is
older than that - the script refuses a window Prometheus no longer holds.

Usage:
  ./export-metrics.py --run-dir Result/<scenario>/rep<N> [--out DIR] [--arms QOS,ENERGY]
                      [--before 60] [--after 300] [--control-plane-ip IP]
                      [--prometheus-url http://host:port] [--force] [--dry-run]
"""

import argparse
import csv
import io
import json
import math
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ARMS = ("QOS", "ENERGY", "BASELINE", "CA", "KARPENTER")
DREEM_PREFIXED = {"QOS": "DREEM-QOS", "ENERGY": "DREEM-ENERGY", "BASELINE": "BASELINE", "CA": "CA",
                  "KARPENTER": "KARPENTER"}
# test.sh's BASELINE_N arm, named after its fleet: BASELINE_6, BASELINE_7_big, BASELINE_5_small
BASELINE_N = re.compile(r"BASELINE_[0-9]+(_[a-z]+)?")


def arm_name(name):
    """the arm as its files are named, or None: QOS and qos are QOS, BASELINE_7_big stays as it is"""
    name = name.strip()
    if name.upper() in ARMS:
        return name.upper()
    return name if BASELINE_N.fullmatch(name) else None
STEP_S = 30
PENDING_EXPR = 'sum(kube_pod_status_phase{phase="Pending", namespace="default"})'


def ip_key(address):
    """192.168.111.101:9100 -> sortable tuple"""
    host = address.split(":")[0]
    try:
        return tuple(int(part) for part in host.split("."))
    except ValueError:
        return (999,)


def panels(control_plane_ip):
    """one entry per CSV: file name pattern, query, column name from the series labels"""
    excluded = f"{control_plane_ip}:9100"
    return [
        {"file": "Active Worker-{dreem}.csv",
         "expr": 'sum(kube_node_status_condition{condition="Ready", status="true"})-1',
         "column": lambda labels: "Active Workers"},
        {"file": "Avg cluster usage-data-{plain}.csv",
         "expr": (f'sum(rate(node_cpu_seconds_total{{mode!="idle", instance!~"{excluded}"}}[5m]))\n/\n'
                  f'sum(rate(node_cpu_seconds_total{{instance!~"{excluded}"}}[5m]))'),
         "column": lambda labels: "Average CPU"},
        {"file": "Node CPU usage-data-{dreem}.csv",
         "expr": (f'100*(1 - (avg(rate(node_cpu_seconds_total{{mode="idle",instance!~"{excluded}", '
                  f'job="node-exporter"}}[5m])) by (instance)))'),
         "column": lambda labels: labels.get("instance", ""),
         "order": ip_key},
        {"file": "Pending Application Pods-data-{dreem}.csv",
         "expr": PENDING_EXPR,
         "column": lambda labels: PENDING_EXPR},
        {"file": "Service delay-{dreem}.csv",
         "expr": ("sum by (app_name) (increase(mub_request_processing_latency_milliseconds_sum{}[2m])) / "
                  "sum by (app_name) (increase(mub_request_processing_latency_milliseconds_count{}[2m]))"),
         "column": lambda labels: labels.get("app_name", "")},
        {"file": "Service rate-{dreem}.csv",
         "expr": "sum by (app_name) (rate(mub_internal_processing_latency_milliseconds_count{}[2m]))",
         "column": lambda labels: labels.get("app_name", "")},
        {"file": "Node info.csv",
         "arms": {"CA"},
         "expr": "kube_node_info",
         "column": node_info_column,
         "order": node_info_order},
        {"file": "Node info-data-{dreem}.csv",
         "arms": {"KARPENTER"},
         "expr": "kube_node_info",
         "column": node_info_column,
         "order": node_info_order},
    ]


def node_info_column(labels):
    return f'{labels.get("node", "")}:{labels.get("internal_ip", "")}::{labels.get("system_uuid", "")}'


def node_info_order(column):
    return ip_key(column.split(":")[1] if ":" in column else column)


# --- Prometheus access ------------------------------------------------------------------

class Prometheus:
    def __init__(self, url, kubeconfig, namespace, service):
        self.url, self.kubeconfig, self.namespace, self.service = url, kubeconfig, namespace, service

    def get(self, api_path, params):
        query = urllib.parse.urlencode(params)
        if self.url:
            with urllib.request.urlopen(f"{self.url.rstrip('/')}{api_path}?{query}", timeout=180) as response:
                body = response.read()
        else:
            path = f"/api/v1/namespaces/{self.namespace}/services/{self.service}/proxy{api_path}?{query}"
            done = subprocess.run(["kubectl", f"--kubeconfig={self.kubeconfig}", "get", "--raw", path],
                                  capture_output=True, timeout=180)
            if done.returncode != 0:
                raise RuntimeError(f"kubectl get --raw failed: {done.stderr.decode().strip()}")
            body = done.stdout
        doc = json.loads(body)
        if doc.get("status") != "success":
            raise RuntimeError(f"Prometheus: {doc.get('errorType')}: {doc.get('error')}")
        return doc["data"]

    def range(self, expr, start, end, step):
        return self.get("/api/v1/query_range", {"query": expr, "start": start, "end": end, "step": step})["result"]

    def oldest_sample_s(self):
        result = self.get("/api/v1/query", {"query": "min(prometheus_tsdb_lowest_timestamp)"})["result"]
        return float(result[0]["value"][1]) / 1000 if result else None


def control_plane_ip(kubeconfig):
    done = subprocess.run(["kubectl", f"--kubeconfig={kubeconfig}", "get", "nodes",
                           "-l", "node-role.kubernetes.io/control-plane", "-o", "json"],
                          capture_output=True, check=True, timeout=60)
    addresses = [a["address"] for node in json.loads(done.stdout)["items"]
                 for a in node["status"]["addresses"] if a["type"] == "InternalIP"]
    if len(addresses) != 1:
        sys.exit(f"found {len(addresses)} control-plane InternalIPs ({addresses}); pass --control-plane-ip")
    return addresses[0]


# --- CSV in Grafana's export layout -------------------------------------------------------

def grafana_number(value):
    if value == "NaN":
        return "NaN"
    if value in ("+Inf", "Inf"):
        return "Infinity"
    if value == "-Inf":
        return "-Infinity"
    number = float(value)
    if math.isfinite(number) and number.is_integer() and abs(number) < 1e15:
        return str(int(number))
    return repr(number)


def to_csv(series, panel):
    """series: Prometheus matrix -> (csv text, stats)"""
    columns = {}
    for s in series:
        name = panel["column"](s["metric"])
        if not name:
            continue
        values = columns.setdefault(name, {})
        for ts, value in s["values"]:
            values.setdefault(int(round(float(ts) * 1000)), value)   # first series wins on a duplicate name
    order = panel.get("order")
    names = sorted(columns, key=order) if order else sorted(columns)
    times = sorted({t for values in columns.values() for t in values})

    out = io.StringIO()
    csv.writer(out, quoting=csv.QUOTE_ALL, lineterminator="\n").writerow(["Time"] + names)
    undefined = nan = 0
    for t in times:
        cells = []
        for name in names:
            value = columns[name].get(t)
            if value is None:
                cells.append("undefined")
                undefined += 1
            else:
                cells.append(grafana_number(value))
                nan += value == "NaN"
        out.write(",".join([str(t)] + cells) + "\n")
    return out.getvalue(), {"rows": len(times), "columns": len(names), "undefined": undefined, "NaN": nan}


# --- main ------------------------------------------------------------------------------------

def utc(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run-dir", required=True, type=Path, help="folder with the <ARM>_window.json files")
    parser.add_argument("--out", type=Path, help="where the CSVs go (default: --run-dir)")
    parser.add_argument("--arms", help="comma-separated, default: every arm with a window")
    parser.add_argument("--before", type=int, default=60, help="seconds before the window (default 60)")
    parser.add_argument("--after", type=int, default=300, help="seconds after the window (default 300)")
    parser.add_argument("--control-plane-ip", help="excluded from the CPU panels (default: looked up)")
    parser.add_argument("--prometheus-url", help="query Prometheus here instead of through the API server")
    parser.add_argument("--kubeconfig", default=os.environ.get("WORKLOAD_KUBECONFIG", os.path.expanduser("~/workload.kubeconfig")))
    parser.add_argument("--namespace", default="monitoring")
    parser.add_argument("--service", default="prometheus-kube-prometheus-prometheus:9090")
    parser.add_argument("--force", action="store_true", help="overwrite existing CSVs")
    parser.add_argument("--dry-run", action="store_true", help="show what would be exported")
    args = parser.parse_args()

    out = args.out or args.run_dir
    windows = {}
    if args.arms:
        arms = [a for a in args.arms.split(",") if a.strip()]
        unknown = [a for a in arms if arm_name(a) is None]
        if unknown:
            sys.exit(f"unknown arm {', '.join(unknown)}: use {', '.join(ARMS)} or BASELINE_<N>[_<size>]")
        arms = [arm_name(a) for a in arms]
    else:
        found = {p.name[:-len("_window.json")] for p in args.run_dir.glob("*_window.json")}
        arms = [a for a in ARMS if a in found] + sorted(a for a in found if a not in ARMS and arm_name(a))
    for arm in arms:
        path = args.run_dir / f"{arm}_window.json"
        if path.exists():
            w = json.loads(path.read_text())
            windows[arm] = tuple(datetime.strptime(w[k], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
                                 for k in ("start", "end"))
    if not windows:
        sys.exit(f"no <ARM>_window.json in {args.run_dir} for arms {', '.join(arms) or 'any'}")

    cp_ip = args.control_plane_ip or control_plane_ip(args.kubeconfig)
    prometheus = Prometheus(args.prometheus_url, args.kubeconfig, args.namespace, args.service)
    print(f"control plane excluded from CPU panels: {cp_ip}")

    if not args.dry_run:
        oldest = prometheus.oldest_sample_s()
        too_old = [arm for arm, (start, _) in windows.items() if oldest and start - args.before < oldest]
        if too_old:
            sys.exit(f"Prometheus only holds data since {utc(oldest)} UTC; too old: {', '.join(too_old)}")
        out.mkdir(parents=True, exist_ok=True)

    failed = False
    for arm, (start, end) in windows.items():
        first = math.floor((start - args.before) / STEP_S) * STEP_S
        last = math.ceil((end + args.after) / STEP_S) * STEP_S
        print(f"\n{arm}: {utc(first)} -> {utc(last)} UTC, step {STEP_S} s")
        for panel in panels(cp_ip):
            if "arms" in panel and arm not in panel["arms"]:
                continue
            name = panel["file"].format(dreem=DREEM_PREFIXED.get(arm, arm), plain=arm)
            target = out / name
            if target.exists() and not args.force:
                print(f"  {name}: exists, skipped (--force to overwrite)")
                continue
            if args.dry_run:
                print(f"  {name}: would query {' '.join(panel['expr'].split())[:90]}")
                continue
            try:
                text, stats = to_csv(prometheus.range(panel["expr"], first, last, STEP_S), panel)
            except (RuntimeError, subprocess.TimeoutExpired, OSError) as error:
                print(f"  {name}: FAILED - {error}")
                failed = True
                continue
            if stats["rows"] == 0:
                print(f"  {name}: FAILED - no data in the window")
                failed = True
                continue
            target.write_text(text)
            print(f"  {name}: {stats['rows']} rows x {stats['columns']} columns"
                  f"{', undefined ' + str(stats['undefined']) if stats['undefined'] else ''}"
                  f"{', NaN ' + str(stats['NaN']) if stats['NaN'] else ''}")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
