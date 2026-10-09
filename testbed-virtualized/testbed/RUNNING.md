# Running the experiment

Everything needed lives in this folder. `test.sh` still does the whole run in
one command; afterwards `export-metrics.py` exports the dashboard data and the
analysis runs on it.

```
testbed/
  test.sh                 the driver - run this
  profiles.json           the deterministic hardware assignment (ground truth)
  init-testbed.sh         once per install: profiles, BMH annotations, labels at join, node labels
  gen-profiles.py         profiles.json assignments, from its slots and the live worker BMHs
  assign-profiles.sh      profiles.json -> BMH annotations (size, consumption profile, group)
  apply-profiles.sh       BMH -> Node label + annotation, resets power-cycle-count
  export-mapping.sh       per-run node mapping (uuid, systemUUID, ip, size, profile)
  export-metrics.py       dashboard data as the CSVs the notebook reads, from Prometheus
  base-latency.sh         the base latency the notebook normalizes with (RunnerParametersS)
  lib.sh                  control-plane discovery (Machine -> Metal3Machine -> BMH)
  test_CA.sh              the Cluster Autoscaler arm (same flags and folder as test.sh)
  test_Karpenter.sh       the Karpenter arm (same flags and folder; see ../Karpenter/)
  run-lib.sh              the steps test.sh, test_CA.sh and test_Karpenter.sh share
  deploy-mubench.sh       renders and applies the workload (heavy services, anchors, probes)
  latency.sh              emulated delay between workers: enable, disable, check
  sync-bmc-secrets.sh     DREEM's per-node BMC secrets, rebuilt from the BMHs
  ironic-maintenance.sh   Ironic maintenance and power control
  analysis/consumption.py the power/energy model
  analysis/analyze.py     the comparison driver
  data/cpu_to_consumption_map.csv   measured reference-server power curves
  Result/                 written by test.sh - download this whole folder
```

## 0. After installing the environment (once per install)

```bash
cd $REPO/testbed
export MGMT_KUBECONFIG=$HOME/.kube/config         # management cluster (the default)
export WORKLOAD_KUBECONFIG=$HOME/workload.kubeconfig   # workload cluster (the default)

./init-testbed.sh --dry-run    # see what it would do
./init-testbed.sh              # profiles, BMH annotations, labels at join, node labels, DREEM secrets
```

Run it after metal3-dev-env has provisioned the control plane and the workers
(`tests/scripts/provision/cluster.sh`, `controlplane.sh`, `worker.sh`). It is safe to
run again, and covers the testbed's own configuration only: Calico, Istio, monitoring
and the DREEM operator are installed separately.

`profiles.json` describes the fleet as ordered `slots` (size, consumption profile,
group). The worker BMHs, sorted by name, take them in order, so the same fleet comes out
whichever BMH became the control plane. If a reinstall moved the control plane or
renamed the hosts, the script stops and asks for `--regenerate-profiles`.

Changing the slots, or regenerating the assignments, changes which node is big or small.
Never do it between arms: the arms must share one fleet or the energy difference stops
being attributable to the algorithm.

`apply-profiles.sh` and `export-mapping.sh` are called by `test.sh` and do not need to
be run by hand.

## 1. Run the test

One call runs one **repetition** of one **scenario**; the Cluster Autoscaler and
Karpenter arms are further calls with the same flags. Results land in
`Result/anchors-<a>_delay-<d>/rep<N>/`, one folder per repetition.

```bash
cd $REPO/testbed
./test.sh           --rep=1 --anchors=big --latency=yes --delay=5ms   # ENERGY, QOS, BASELINE
./test_CA.sh        --rep=1 --anchors=big --latency=yes --delay=5ms   # Cluster Autoscaler
./test_Karpenter.sh --rep=1 --anchors=big --latency=yes --delay=5ms   # Karpenter
```

The Runner is started with `muBench/.venv/bin/python3`, the environment muBench
is installed into, so there is no need to activate it; set `PYTHON=...` to use
another one.

| flag | meaning |
|------|---------|
| `--rep=N` | repetition number (required). A finished arm is never overwritten without `--force` |
| `--arms="ENERGY QOS BASELINE"` | test.sh only: the arms and their order - alternate it between repetitions. `BASELINE_N` adds BASELINE on fewer workers (below) |
| `--nodes=6` | test.sh's `BASELINE_N` only: workers that stay on |
| `--remove=big\|small` | test.sh's `BASELINE_N` only, when an odd number of workers is switched off: the size that loses one more |
| `--anchors=big\|small\|any\|mixed` | where anchors are pinned: `big` = conflict scenario, `small` = control, `any` = unconstrained, `mixed` = aa and ac on big, ab and ad on small (two pairs per size, so pair-hosting is not tied to consumption) |
| `--latency=yes --delay=5ms` / `--latency=no` | delay between workers, one way (a round trip carries 2 x delay). Applied to each peer's node address and to its Calico tunnel endpoint on the provisioning network, which is the path pod-to-pod traffic takes; the check pings both |
| `--probe-rate=2` | requests/s sent to each probe |
| `--repair=yes\|no` | `yes` runs `repair-pairs.py` during the workload: a probe that sits away from its anchor is deleted when the anchor's node has room, so the scheduler puts it back next to it. Results go to a separate `..._repair` folder; use the same value for every arm |
| `--repair-interval=600` | seconds between repair passes; keep it above DREEM's 10-minute decision cycle |
| `--skip-provision` | keep the fleet as it is (no CA / Ironic / MachineDeployment steps) |
| `--base-hosts=node-1,node-2,node-7` | test_Karpenter.sh only: the hosts Karpenter never removes (default: chosen from `profiles.json`, see below) |

What every call does:

1. **Fleet.** Cluster Autoscaler and Karpenter off (Karpenter's leftover nodes
   removed), worker BMHs attached, MachineDeployment back
   to every worker and all workers Ready - this is what recovers the fleet after a CA
   run deprovisioned nodes - then a wait until the operator has registered and adopted
   every worker again (BMH OK, Ironic record active under the BMH's ID), then
   `apply-profiles.sh` (size, consumption profile, group). For the DREEM arms and
   BASELINE the worker BMHs are then detached, which makes the operator delete their
   Ironic records, so DREEM's Redfish power-offs are not undone by Ironic's power sync;
   a record that survives goes into maintenance. The control-plane BMH is never
   touched. The run stops if a worker does not register within 15 minutes: repair it
   with `./ironic-reregister.sh <bmh>`. `sync-bmc-secrets.sh` rebuilds
   DREEM's `bmc-credentials-<node>` secrets, which are looked up by node name and
   go stale on every reprovision.
2. **Workload.** `deploy-mubench.sh` renders the workmodel for `--anchors`, applies
   it, keeps HPAs for `s0-s5` and `gw-nginx` only, and restarts everything. The
   rendered workmodel and manifests are kept in `deploy/`, together with the load the
   Runner injects (`deploy/load/`) and a copy of DREEM's `forecast-parameters`
   ConfigMap as deployed (`deploy/forecast-parameters.yaml`), so a run can be
   reproduced with the same workload and the same forecaster settings.
3. **Per arm.** All VMs on, workers uncordoned, profiles re-applied, `latency.sh`
   sets **and verifies** the delay (the run stops if it is wrong), placement reset
   (heavy services and anchors first, then probes; the start placement is saved),
   node map export, DREEM profile, pod-placement watcher, the main Runner plus one
   periodic Runner per probe, results copied.

**Probes and anchors.** `pa`, `pb`, `pc` call `aa`, `ab`, `ac` ten times in a row per
request and prefer the node their anchor runs on (hostname pod affinity); anchors are
pinned by `--anchors`. The names are lowercase because they become Kubernetes object
names. Probes and anchors use `"request_method": "rest"`: in the current muBench image
every gRPC call between services fails (`app.logger.info.info(...)` in
`ServiceCell/CellController-mp.py`, line 236), which never showed before because the
heavy services do not call other services. Fix that line and rebuild the image before
switching them back to gRPC. At the placement reset each anchor is started on its own
node (nodes already holding one are cordoned only while the anchors are placed), then
the probes are restarted so they land next to it.

**Labels at join.** Workers provisioned by Cluster API (every CA scale-up, and
`test.sh` bringing the fleet back to 8) register with `size` and `group` already set:
the worker Metal3DataTemplate `test-cluster-m3-workers-template-labels` copies the BMH
annotations `dreemk8s.io/size` and `dreemk8s.io/group` into the host metadata, and the
worker KubeadmConfigTemplate passes them to kubelet as node labels. So no pod can land
on an unlabeled node. `apply-profiles.sh` is still needed for the annotations
(consumption profile, power-cycle count) and skips hosts whose Node has not joined yet.
The previous objects are saved in `cluster-backup-20260914/`; to roll back, point the
Metal3MachineTemplate `test-cluster-m3-workers` at `test-cluster-m3-workers-template`
again and restore `node-labels` to `metal3.io/uuid={{ ds.meta_data.uuid }}`.

**Karpenter arm.** Karpenter only removes nodes it created, so `test_Karpenter.sh`
splits the fleet. The base MachineDeployment keeps 3 workers on fixed hosts (Cluster
Autoscaler's min size, also DREEM's `minNodes`): by default one per group, both sizes,
mean consumption profile closest to the fleet's, ties broken by name, which today gives
`node-1`, `node-2`, `node-7` (profiles 280, 300, 240; fleet mean 270). The other 5
hosts belong to Karpenter's MachineDeployment, capped by the NodePool limit. The run
then:

1. restores the fleet as for CA and shrinks the base MachineDeployment to the base hosts
   (the other Machines are marked `delete-machine`);
2. **warm start:** a placeholder pod per free host (`../Karpenter/warmup.yaml`, its own
   namespace) makes Karpenter add 5 nodes, so the arm starts with all 8 workers on like
   the others; then the controller is switched off and the placeholders deleted;
3. deploys the workload and prepares the arm exactly as for CA;
4. switches the controller on right before the workload, as CA. Starting it restarts its
   consolidation timers, so no node goes in the first 10 minutes (`consolidateAfter`);
5. after the workload saves the controller log, removes Karpenter's nodes, switches it
   off and deletes its MachineDeployment.

The feasibility check brought two Karpenter nodes up in 8 minutes; five at once may take
a little longer. Install Karpenter first: `../Karpenter/README.md`.

**BASELINE on fewer workers (`BASELINE_N`).** No scaling, like BASELINE, but with only
`--nodes` workers on: the others are cordoned, drained and powered off before the
placement reset, as DREEM leaves the nodes it switches off, and the next arm powers them
on again. As many big as small go; when the number is odd, `--remove` picks the size that
loses one more. The hosts come from `profiles.json`: hosts of distinct groups (every group
keeps a host), the kept fleet's mean consumption profile closest to the whole fleet's,
ties to the lowest names. The arm is named after the choice:

```bash
./test.sh --rep=0 --anchors=mixed --latency=yes --delay=2ms --repair=yes \
          --arms="QOS ENERGY BASELINE BASELINE_N" --nodes=6              # BASELINE_6: node-1, node-8 off
./test.sh --rep=0 --anchors=mixed --latency=yes --delay=2ms --repair=yes \
          --arms="BASELINE_N" --nodes=7 --remove=big                     # BASELINE_7_big: node-1 off
```

| `--nodes` | switched off (size group profile) | kept mean profile |
|---|---|---|
| 7, `--remove=big` | node-1 (big A 280) | 268.6 |
| 7, `--remove=small` | node-8 (small D 260) | 271.4 |
| 6 | node-1 (big A 280), node-8 (small D 260) | 270.0 |
| 5, `--remove=big` | node-1 (big A 280), node-2 (big B 300), node-7 (small C 240) | 268.0 |
| 5, `--remove=small` | node-2 (big B 300), node-7 (small C 240), node-8 (small D 260) | 272.0 |
| 4 | node-1, node-2, node-7, node-8 | 270.0 |

Several sizes are separate arms of the same folder (one `--nodes` per call), e.g.
`BASELINE_6` and `BASELINE_7_big` next to BASELINE. `<arm>_switched_off.json` records
the hosts. The powered-off nodes stay off after the last arm, until the next test script
powers them on.

DREEM's forecaster request-rate query is restricted to the heavy services
(`app_name=~"s[0-9]+"`), so the probe traffic does not drive scaling. The ramp-down
workloads are run from `workload-<n>d.json` copies, so no result file overwrites
another, and `SimulationWorkspace/Result` is emptied before every arm.

Per arm the folder holds:

| file | what it is |
|------|-----------|
| `<ARM>_node_map.json` (`.jsonl`, a snapshot a minute, for CA and KARPENTER) | uuid / systemUUID / IP / profile / group mapping for that arm |
| `<ARM>_window.json` | UTC start and end of the main workload |
| `<ARM>_Result/` | `result_workload-*.txt` (heavy traffic) and `probe_<p>.txt` (probes) |
| `<ARM>_nodeselecting_CR.json` | DREEM's scale-down decisions (ENERGY, QOS) |
| `<ARM>_pods.jsonl` | pod placement and node state every 30 s |
| `<ARM>_start_placement.json` | placement at the start, with the probe/anchor checks |
| `<ARM>_switched_off.json` | BASELINE_N only: the hosts switched off, the kept fleet's mean profile |
| `base_latency_services.csv`, `base_latency/` | the base latency and its run (`base-latency.sh`, section 2b) |
| `KARPENTER_nodeclaims.jsonl`, `KARPENTER_nodeclaims_end.json`, `KARPENTER_events.json`, `logs/KARPENTER_controller*.log`, `deploy/karpenter/` | Karpenter only: NodeClaims every minute (node, host, conditions, disruption reason), at the end, its events of the last hour, the controller logs (warm start and run), the NodePool, node class, MachineDeployment, image and base hosts it ran with |
| `run_config_*.json`, `profiles.json`, `deploy/`, `runner/`, `logs/` | scenario and DREEM images, fleet, rendered workload, injected load, `forecast-parameters` ConfigMap, Runner configs, logs |

The pieces also work on their own:

```bash
./latency.sh --latency=yes --delay=2ms   # enable and verify
./latency.sh --check                     # verify what is applied
./latency.sh --latency=no                # remove
./deploy-mubench.sh --anchors=small      # redeploy the workload
./sync-bmc-secrets.sh --dry-run          # show the DREEM BMC secrets it would write
```

## 2. Export the dashboard data

```bash
./export-metrics.py --run-dir Result/<scenario>/rep<N>
```

It runs the queries of the µBench dashboard panels against Prometheus over each arm's
workload window (`<ARM>_window.json`) and writes the CSVs the notebook reads, with the
names, columns and layout of a Grafana "Download CSV":

| file | panel |
|---|---|
| `Active Worker-<A>.csv` | N worker |
| `Avg cluster usage-data-<B>.csv` | Avg CPU usage (0-1) |
| `Node CPU usage-data-<A>.csv` | Node CPU usage (percent, one column per `ip:9100`) |
| `Pending Application Pods-data-<A>.csv` | Pending Application Pods |
| `Service delay-<A>.csv`, `Service rate-<A>.csv` | Service delay, Service rate (one column per service) |
| `Node info.csv` | Node info (`node:ip::systemUUID`), Cluster Autoscaler arm only |
| `Node info-data-KARPENTER.csv` | the same for the Karpenter arm |

`<A>` is `DREEM-QOS`, `DREEM-ENERGY`, `BASELINE`, `CA`, `KARPENTER` or a `BASELINE_N` arm
(`BASELINE_6`, `BASELINE_7_big`, ...); `<B>` the same without `DREEM-`. Without
`--arms` every arm with a `<ARM>_window.json` is exported. Checked against the Grafana downloads of a run: same columns, same
values.

* **Export within 10 days.** Prometheus keeps 10 days of data; the script stops if an
  arm's window is older than what Prometheus still holds.
* **Run it after `test.sh` and again after `test_CA.sh` and `test_Karpenter.sh`.**
  Existing CSVs are kept (use `--force` to overwrite), so a later call only adds the new
  arm's files.
* It does what a manual export must get right: timestamps in UTC, and a missing
  sample written as `undefined`. When DREEM powers a node down its CPU series must
  show a hole - that hole *is* the measurement.
* The control plane is excluded from the CPU panels by its InternalIP, looked up in
  the cluster (`--control-plane-ip` to override). `--dry-run` shows the queries and
  time ranges; `--prometheus-url` queries a Prometheus reachable directly.

## 2b. Measure the base latency

The notebook divides each heavy service's latency by its base latency: its latency alone
on a calm cluster. `base-latency.sh` measures it. muBench's
`Configs/RunnerParametersS.json` sends 100 requests to s0, then to s1 ... s5, about 5 s
apart, and the "Service delay" panel over that window is exported to
`base_latency_services.csv` (columns Time, s0 ... s5, as the notebook reads it).

```bash
./base-latency.sh --run-dir Result/<scenario>/rep<N> --dry-run   # checks and plan
./base-latency.sh --run-dir Result/<scenario>/rep<N>             # ~50 min
```

* Run it right after a test script: the scenario's delay is still applied and the
  scalers are off. It refuses to start with DREEM's forecaster, Cluster Autoscaler or
  Karpenter on, or while another Runner sends load, and first waits until every service
  is back at its HPA minimum.
* The notebook looks for the file next to itself and one folder up, so one measurement
  per scenario is enough: `--out Result/<scenario>/base_latency_services.csv`.
* `base_latency/` keeps the window, the Runner's results and the parameters used;
  `--export-only` exports again from that window (within Prometheus's 10 days).
* The test scripts end with this reminder when the folder has no base latency yet.

## 3. Analyse

```bash
cd $REPO/testbed/analysis
./analyze.py --results-dir ../Result \
    --target-server restart-srv05 \
    --cpu ENERGY=energy_cpu.csv --node-info ENERGY="ENERGY Node info.csv" \
    --cpu QOS=qos_cpu.csv       --node-info QOS="QOS Node info.csv" \
    --cpu BASELINE=base_cpu.csv --node-info BASELINE="BASELINE Node info.csv" \
    --reference QOS
```

`--power-map` defaults to `../data/cpu_to_consumption_map.csv`, and `--cores-ref`
to 100 (the measured machines have 100 cores; the VMs have 10, which is where
the factor of 10 comes from).

Read the table as follows:

* **`energy_Wh`** is the headline: what it cost to serve the same workload.
* **`J_per_request`** is the fair number when the arms take different amounts of
  time. Mean power only compares meaningfully at equal duration.
* **`node_hours_on`** shows the consolidation directly.
* **`latency_p95_ms`** and **`error_rate`** are the QoS side, so the ENERGY arm's
  saving can be quoted against what it cost in latency.

The analysis refuses to run rather than produce a quietly wrong number: an
unmapped CPU column, a CPU series that looks like a 0-1 fraction, or a workload
window that does not overlap the CSV all raise with an explanation.

## 3b. Or from the notebook

`Result/` carries `consumption.py`, so the notebook works from the download
alone. Paste `analysis/notebook_cell.py` into a cell, then:

```python
macchina_target = "restart-srv02"

consumption_QOS = create_consumption_dict_updated(
    cpu_file="Node CPU usage-data-DREEM-QOS.csv",
    map_file="Result/cpu_to_consumption_map.csv",
    target_server=macchina_target,
    arm="QOS",                      # <- the one addition
)
consumption_ENERGY  = create_consumption_dict_updated(..., arm="ENERGY")
consumption_BASELINE= create_consumption_dict_updated(..., arm="BASELINE")
consumption_CA      = create_consumption_dict_updated(..., arm="CA")

print(f"QOS:      {total_energy_kWh(consumption_QOS):.3f} kWh")
print(f"ENERGY:   {total_energy_kWh(consumption_ENERGY):.3f} kWh")
print(f"BASELINE: {total_energy_kWh(consumption_BASELINE):.3f} kWh")
print(f"CA:       {total_energy_kWh(consumption_CA):.3f} kWh")
```

`arm=` selects the node map exported during that run. Without it the function
raises rather than guess, because a map from another run attaches the wrong
profile to the wrong machine.

`Total_Consumption` is still there and is still instantaneous **watts**, so
existing plots keep working. Do not sum it: summing watts is not energy. Use
`total_energy_kWh(df)`, which integrates over the real sample interval. On a
30 s export the old `sum()/1000` overstates by a factor of 120.

`df.attrs["summary"]` holds the per-node breakdown, node-hours powered on and
the model parameters; `df.attrs["workload"]` holds request count and latency.

## The power curve

`data/cpu_to_consumption_map.csv` is built by `generate_cpu_to_consumption_map()`
in `analysis/notebook_cell.py` from a VANILLA run's two exports:

```python
df = generate_cpu_to_consumption_map(
    "Node CPU usage-VANILLA.csv", "Cluster Consumption-VANILLA.csv")
cols = [c for c in df.columns if not c.endswith(("__source", "__samples"))]
df[cols].to_csv("cpu_to_consumption_map.csv", index=False)
df.to_csv("cpu_to_consumption_map_annotated.csv", index=False)   # keep provenance
```

The earlier version of that function used `interpolate(limit_direction="both")`,
which invented data outside the range the servers were actually driven through.
restart-srv02 never exceeded 84% CPU, so bins 85-100 were back-filled with the
value at 84; restart-srv05 never went below 4.84% or above 86.82%, so bins 0-4
and 88-100 were invented too, and bin 87 - a single 443 W reading - was held
constant all the way to 100%. The result claimed a node at 90% drew 443 W while
one at 75% drew 631 W, which flatters whichever scaling arm packs nodes hardest.

The current version joins the two exports on Time, drops bins with fewer than
three readings, interpolates interior gaps only, fits a sample-count-weighted
isotonic regression (the same PAVA DREEM uses in
`scripts/metricUpdate/main.py`), holds the idle value below the measured range,
and extends the measured trend above it. Both curves come out monotone:
restart-srv02 324 -> 604 W, restart-srv05 263 -> 640 W.

The annotated CSV carries a `<server>__source` column marking each bin
`measured`, `interpolated`, `held_idle` or `extrapolated_linear`, and a
`<server>__samples` column with the reading count. Check how much of a run's CPU
data lands in the extrapolated region before quoting a figure; if a lot does,
drive a VANILLA run harder so the top of the curve is measured rather than
extended. `extrapolate="hold"` reproduces the old flat-tail behaviour for a
sensitivity check.
