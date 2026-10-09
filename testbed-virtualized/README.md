# VIRTUAL TESTBED

Everything needed to rebuild the virtual testbed and repeat the experiments that compare
**DREEM**, a node-level Kubernetes autoscaler with an energy-aware (ENERGY) and a
QoS-aware (QOS) node-selection profile, against no node scaling (BASELINE),
**Cluster Autoscaler** and **Karpenter**.

The testbed is built on [metal3-dev-env](https://github.com/metal3-io/metal3-dev-env):
9 libvirt VMs that Metal3 manages as bare-metal servers through emulated Redfish BMCs. A
minikube management cluster runs Cluster API and Metal3. The workload cluster on the VMs
has 1 control plane and 8 workers of 10 vCPU / 32 GB, Kubernetes v1.33.7, Calico and
Istio. The workers get emulated hardware heterogeneity: a size, a consumption profile
and a group per host. The application and its load come from
[muBench](https://github.com/mSvcBench/muBench).

## What each folder contains

| Folder | Contents |
|---|---|
| `metal3-dev-env_changes/` | the files changed in metal3-dev-env (VM and minikube sizes, node DNS for the PoliTO network), a script that applies them to a checkout at the pinned commit, the install variables (`env.sh`), the host's reboot fixes, and the workload cluster's base add-ons (Calico, metrics-server) |
| `mubench_changes/` | the files changed or added in muBench (stress-ng function, deployer with node and pod affinities, HPA template, load generator), the work model and request traces the tests send, a script that applies them and unzips the Alibaba traces, the monitoring install and the Grafana dashboard |
| `DREEM/` | the Helm values for DREEM (operator and forecaster), to be added; its README lists the names the tests rely on |
| `CA/` | Cluster Autoscaler v1.29.0 (Cluster API provider): manifest and install instructions |
| `Karpenter/` | Karpenter with its Cluster API provider: manifests, CRDs, the image build, a feasibility check and install instructions |
| `testbed/` | the experiment: fleet profiles, workload deployment, emulated network latency, one script per compared configuration (`test.sh`, `test_CA.sh`, `test_Karpenter.sh`), metrics export and analysis; `RUNNING.md` is the manual |
| `check_setup.sh` | checks, without changing anything, that everything is in place for the tests |

The setup clones metal3-dev-env and muBench into `metal3-dev-env/` and `muBench/` next to
these folders (git-ignored). `testbed/` expects muBench exactly there.

## Setup

The host needs Ubuntu 24.04 with passwordless `sudo` and room for the VMs (9 × 10 vCPU
and 32 GB, plus 8 CPU / 8 GB for minikube; the original host has 96 CPUs and 503 GB).
Install clusterctl v1.13.5, helm, envsubst (gettext-base), unzip, git and Python 3.12;
metal3-dev-env installs jq, kubectl, minikube, libvirt and docker itself. Run every step
from a shell where the repository path is set:

```bash
export REPO=$(pwd)   # the root of this repository
```

1. **Get metal3-dev-env at the pinned commit and apply the changes.**

   ```bash
   $REPO/metal3-dev-env_changes/apply-changes.sh   # clones into $REPO/metal3-dev-env, copies the changed files
   ```

   Check the node DNS servers first: the changed data template uses the resolvers of
   the original host's network (`metal3-dev-env_changes/README.md`).

2. **Install metal3-dev-env and provision the workload cluster.**

   ```bash
   source $REPO/metal3-dev-env_changes/env.sh      # 9 nodes, CentOS 10, Kubernetes v1.33.7, Redfish
   cd $REPO/metal3-dev-env
   ./01_prepare_host.sh && ./02_configure_host.sh && ./03_launch_mgmt_cluster.sh
   ./tests/scripts/provision/cluster.sh
   ./tests/scripts/provision/controlplane.sh
   ./tests/scripts/provision/worker.sh
   $REPO/metal3-dev-env_changes/workload-cluster/post-provision.sh   # ~/workload.kubeconfig, Calico, metrics-server
   ```

   Install the host's provisioning-bridge unit once, so the testbed survives a reboot
   (`metal3-dev-env_changes/README.md`, "Surviving a reboot").

3. **Get muBench at the pinned commit and apply the changes.**

   ```bash
   $REPO/mubench_changes/apply-changes.sh   # clones into $REPO/muBench, copies the changes,
                                            # unzips traces-mbench.zip, creates .venv (~6 min)
   ```

4. **Install the monitoring stack and import the Grafana dashboard.**

   ```bash
   $REPO/mubench_changes/monitoring/install-monitoring.sh   # Prometheus, Grafana, Istio, Jaeger, Kiali (pinned versions)
   $REPO/mubench_changes/monitoring/import-dashboard.sh     # µBench dashboard
   ```

   This is muBench's `monitoring-install.sh` with the chart versions pinned, plus the
   muBench PodMonitor and Prometheus and Grafana pinned to the control plane.

5. **Install DREEM, Cluster Autoscaler and Karpenter, all switched off.**

   - DREEM: install the Helm chart with the values in `DREEM/`, with both Deployments at
     0 replicas and `Enabled: "false"` in `forecast-parameters` (`DREEM/README.md`).
   - Cluster Autoscaler: `CA/README.md`, "Install" (0 replicas, plus the min 3 / max 8
     annotations on the worker MachineDeployment).
   - Karpenter: `Karpenter/README.md`, "Install" (CRDs and NodePool in the workload
     cluster, controller with 0 replicas in the management cluster).
   - Then prepare the testbed itself: fleet profiles, host annotations, labels at join,
     node labels and DREEM's BMC secrets.

     ```bash
     $REPO/testbed/init-testbed.sh --dry-run && $REPO/testbed/init-testbed.sh
     ```

6. **Check the setup.**

   ```bash
   $REPO/check_setup.sh
   ```

   Every line is OK, WARN or FAIL; the tests can run when nothing FAILs.

## Running the tests

`testbed/RUNNING.md` explains every flag and output. One repetition of one scenario:

```bash
cd $REPO/testbed
./test.sh           --rep=1 --anchors=mixed --latency=yes --delay=2ms --repair=yes   # ENERGY, QOS, BASELINE
./test_CA.sh        --rep=1 --anchors=mixed --latency=yes --delay=2ms --repair=yes   # Cluster Autoscaler
./test_Karpenter.sh --rep=1 --anchors=mixed --latency=yes --delay=2ms --repair=yes   # Karpenter
./export-metrics.py --run-dir Result/anchors-mixed_delay-2ms_repair/rep1          # within 10 days
./base-latency.sh   --run-dir Result/anchors-mixed_delay-2ms_repair/rep1          # base latency for the notebook (~50 min)
```

`--arms="... BASELINE_N" --nodes=6` adds a no-scaling baseline on fewer workers (6 here;
`--remove=big|small` when an odd number goes), see `testbed/RUNNING.md`. Results land in
`testbed/Result/` (git-ignored). `testbed/analysis/notebook/` holds the
analysis notebook.

## Pinned versions

| Component | Version |
|---|---|
| metal3-dev-env | `ac77fc9218022cf88be286f0c971dec10d7ea4a0` |
| Cluster API / clusterctl | v1.13.5 |
| Kubernetes (nodes) | v1.33.7, CentOS 10 node image |
| Calico | v3.26.1 |
| metrics-server | v0.9.0 |
| muBench | `176c8f14f2740414436078d5dcd969d38dd4acd4` |
| kube-prometheus-stack | 89.2.2 (Prometheus operator v0.93.1, Grafana 13.2.1) |
| Istio | 1.30.4; Kiali 2.31.0 |
| Cluster Autoscaler | v1.29.0 |
| Karpenter | Cluster API provider `9dc28cf` on Karpenter core v1.5.0 (image pinned by digest) |
| DREEM | operator 0.0.32, forecaster 0.0.60 |
