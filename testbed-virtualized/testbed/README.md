# Testbed fleet profiles

Every worker of the workload cluster carries a **hardware profile**. It is the single
source of truth for all arms of the experiment (DREEM ENERGY, DREEM QOS, baseline,
Cluster Autoscaler), so that differences between arms come from the scaling algorithm
and not from a different fleet.

| profile field | on the Node | used by |
|---|---|---|
| `size` (`big` / `small`) | label `size` | muBench anchors (required node affinity `size=big`) |
| `group` (`A` / `B` / `C` / `D`) | label `group` | muBench heavy services (`preferred_group`) |
| `consumption_profile` | annotation `dreemk8s.io/consumption-profile` | DREEM's `EnergyProfile` criterion, energy analysis |

See `RUNNING.md` for the full experiment procedure. In short: `./init-testbed.sh` once
per install, then `./test.sh` per experiment, then the analysis.

## How a profile reaches a node

```
profiles.json            slots  (what you edit)
      │  gen-profiles.py
      ▼
profiles.json            assignments  (generated: one slot per worker BMH)
      │  assign-profiles.sh
      ▼
BareMetalHost            annotations dreemk8s.io/size, consumption-profile, group
      │                          (durable: survive deprovision/reprovision)
      ├── apply-profiles.sh ───────────────► Node labels size, group
      │                                      Node annotation consumption-profile
      │
      └── at provisioning (labels at join) ► kubelet registers every NEW node
                                             with size and group already set
```

`init-testbed.sh` runs the whole chain. The **BMH** is the durable home of a profile:
Cluster Autoscaler deletes Node objects, the BMH survives. `apply-profiles.sh` copies
BMH -> Node and never reads `profiles.json`.

## profiles.json

| key | meaning |
|---|---|
| `slots` | ordered list of hardware profiles, one per worker. **Edit this.** |
| `assignments` | worker BMH -> slot, **generated** by `gen-profiles.py`. Do not edit by hand. |
| `ranges` | allowed `consumption_profile` per size (big 230-280, small 160-210); disjoint, so a big node is never as cheap as a small one |
| `baseline_profile` | reference value the energy analysis scales against (power = reference curve x `consumption_profile` / `baseline_profile`) |
| `cores_per_node` | vCPUs per worker, used by the energy analysis |

Current fleet:

| slot | size | consumption_profile | group | host (control plane on node-0) |
|---|---|---|---|---|
| 1 | big | 280 | A | node-1 |
| 2 | big | 270 | B | node-2 |
| 3 | big | 250 | C | node-3 |
| 4 | big | 240 | D | node-4 |
| 5 | small | 160 | A | node-5 |
| 6 | small | 180 | B | node-6 |
| 7 | small | 190 | C | node-7 |
| 8 | small | 210 | D | node-8 |

A higher `consumption_profile` means the node consumes more, which matches DREEM:
`EnergyProfile` is a benefit criterion in scale-down (highest = best to remove) and a
cost criterion in scale-up.

`group` is independent of `size`: the four groups are dealt out in snake order over the
fleet sorted by consumption profile (A B C D D C B A), so every group holds one big and one
small node, and the groups' consumption totals differ by at most 10 (440, 450, 440, 450).
On size alone the consumption profile and pod density moved together, and the ENERGY and
QOS profiles could not be told apart.

### From slots to assignments

The worker BMHs, sorted by name (`node-2` before `node-10`), take the slots in order.
The control-plane BMH is found at runtime (Machine -> Metal3Machine -> BMH, see
`lib.sh`) and left out, so the same fleet comes out wherever the control plane lands:

| control plane | workers in order | slot 1 (big, 280, A) goes to |
|---|---|---|
| node-0 | node-1 ... node-8 | node-1 |
| node-5 | node-0 ... node-4, node-6 ... node-8 | node-0 |

The generator refuses a file whose slot count differs from the number of workers, or a
`consumption_profile` outside the range of its size.

## After installing the environment

Once metal3-dev-env has provisioned the control plane and the workers:

```bash
cd $REPO/testbed
export MGMT_KUBECONFIG=$HOME/.kube/config         # management cluster (the default)
export WORKLOAD_KUBECONFIG=$HOME/workload.kubeconfig   # workload cluster (the default)

./init-testbed.sh --dry-run    # what it would do
./init-testbed.sh
```

It writes the workload kubeconfig if missing, keeps or generates `profiles.json`, writes
the profiles onto the BMHs, sets up labels at join, labels the existing workers and syncs
DREEM's BMC secrets. It is safe to run again.

If a reinstall moved the control plane or renamed the hosts, the existing assignments no
longer match and the script stops; run it with `--regenerate-profiles`.

## Changing a profile (size, consumption profile or group)

**1. Find the slot of the host.** The slot table is printed by `./init-testbed.sh --dry-run`,
or:

```bash
./gen-profiles.py --profiles profiles.json --workers $(bash -c 'source ./lib.sh; worker_bmhs') --summary
```

```
  slot 1: node-1     size=big   profile=280  group=A
  slot 2: node-2     size=big   profile=270  group=B
  ...
```

**2. Edit that entry in `slots`** in `profiles.json`, for example slot 3:

```json
{ "size": "big", "consumption_profile": 260, "group": "C" },
```

Keep `consumption_profile` inside the range of its size, or widen `ranges`.

**3. Apply it**, with one command:

```bash
./init-testbed.sh --regenerate-profiles
```

or step by step - all three steps are needed:

```bash
./gen-profiles.py --profiles profiles.json --workers $(bash -c 'source ./lib.sh; worker_bmhs') --write   # slots -> assignments
./assign-profiles.sh      # profiles.json -> BMH annotations
./apply-profiles.sh       # BMH -> Node labels and annotations
```

Do not skip `assign-profiles.sh`: `apply-profiles.sh` copies from the BMH, so without it
the Nodes get the old values back.

**4. Know when the change takes effect.**

| what | when |
|---|---|
| DREEM decisions | immediately: DREEM reads the consumption profile from the Node when it decides |
| nodes provisioned later (Cluster Autoscaler, `test.sh` scaling back to all workers) | automatically: labels at join read the BMH annotations |
| pods already running | only once they are rescheduled - affinity is applied at scheduling. `test.sh` resets the placement at the start of every arm; otherwise run `./deploy-mubench.sh` |

**Do not** edit `assignments` directly: `init-testbed.sh` then reports a mismatch, and
`--regenerate-profiles` rebuilds `assignments` from the unchanged slots, discarding the
edit.

**Never change the fleet between arms or repetitions of one comparison.** Each run folder
keeps a copy of the `profiles.json` it used. Changing `size` also changes where anchors can
run (they require `size=big`), and with it the conflict scenario.

## Labels at join

Nodes created by Cluster API register with `size` and `group` already set, so a node
brought back by Cluster Autoscaler is never unlabeled, not even for a few seconds:

1. the worker Metal3DataTemplate copies the BMH annotations `dreemk8s.io/size` and
   `dreemk8s.io/group` into the host metadata (`fromAnnotations`)
2. the worker KubeadmConfigTemplate passes `group={{ ds.meta_data.group }},size={{ ds.meta_data.size }}`
   to kubelet as node labels; cloud-init fills in the values on the host at boot
3. kubelet creates the Node with those labels

`init-testbed.sh` sets this up. A Metal3DataTemplate cannot be modified, so a copy named
`<template>-labels` is created and the machine template pointed at it; existing machines
are not reprovisioned. The objects as they were before the change on the current cluster
are saved in `cluster-backup-20260914/`.

The consumption profile and the power-cycle count are annotations, which kubelet cannot
set: `apply-profiles.sh` still writes them.

To check it on the first node Cluster API provisions after the setup:
`kubectl --kubeconfig $WORKLOAD_KUBECONFIG get node <new node> --show-labels` should show
`size` and `group` from the moment the node appears.

## Scripts

| script | what it does |
|---|---|
| `init-testbed.sh` | once per install: kubeconfig, profiles, BMH annotations, labels at join, node labels, DREEM BMC secrets |
| `gen-profiles.py` | `profiles.json` assignments from its slots and the live worker BMHs (`--summary`, `--check`, `--write`) |
| `assign-profiles.sh` | `profiles.json` -> BMH annotations (size, consumption profile, group); `--dry-run` |
| `apply-profiles.sh` | BMH -> Node labels and annotations, resets the power-cycle count; skips hosts whose Node has not joined; `--dry-run` |
| `export-mapping.sh` | per-run node mapping (uuid, systemUUID, IP, size, group, profile) |
| `export-metrics.py` | the dashboard data the notebook reads (workers, CPU, Pending pods, service delay and rate, Node info), queried from Prometheus per arm |
| `repair-pairs.py` | deletes a probe pod that sits away from its anchor when the anchor's node has room, so it is rescheduled next to it; `--dry-run`, `--interval` (used by `--repair=yes`) |
| `sync-bmc-secrets.sh` | DREEM's `bmc-credentials-<node>` secrets, rebuilt from the BMHs |
| `lib.sh` | control-plane discovery (Machine -> Metal3Machine -> BMH) and kubectl helpers |

`test.sh` and `test_CA.sh` call `apply-profiles.sh` and `export-mapping.sh` themselves.

## Why it works this way

* **The control plane must be excluded, and cannot be identified by name.**
  metal3-dev-env names every BMH `node-N`, and CAPM3 puts the
  `cluster.x-k8s.io/control-plane` label on the Machine, not on the BMH. `lib.sh` walks
  Machine -> Metal3Machine -> BMH, and the slots make the fleet independent of which host
  became the control plane.
* **Profiles must not be random.** `$RANDOM` used to re-roll the fleet on every run, so an
  energy difference between two arms mixed the algorithm effect with different hardware.
* **Profiles live on the BMH.** Cluster Autoscaler deletes Node objects on scale-down; the
  BMH survives.
* **The mapping must be exported per run.** Node names get a new random suffix on every
  reprovision, and the IP <-> host binding is a DHCP lease that changes between runs. The
  stable key is `metal3.io/uuid`, which equals the BMH `metadata.uid`.

## Node mapping during a Cluster Autoscaler run

Nodes churn while Cluster Autoscaler runs, so `test_CA.sh` appends a node-map snapshot
every minute to `CA_node_map.jsonl` in the run folder. For the analysis, the IP -> host
timeline comes from the "Node info" Grafana panel (legend `name:ip:systemUUID`), passed
as `--node-info CA="CA Node info.csv"`: `systemUUID` is the VM's SMBIOS UUID and survives
reprovisioning, which node names and DHCP leases do not.
