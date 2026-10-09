# metal3-dev-env changes

The virtual testbed is [metal3-dev-env](https://github.com/metal3-io/metal3-dev-env):
libvirt VMs that Metal3 treats as bare-metal hosts (Redfish BMCs emulated by
sushy-tools), a minikube management cluster with Cluster API and Metal3, and a workload
cluster provisioned on the VMs (1 control plane, 8 workers of 10 vCPU / 32 GB).

| Item | Value |
|---|---|
| Commit the experiments used | `ac77fc9218022cf88be286f0c971dec10d7ea4a0` (main, 2026-08-12); `apply-changes.sh` takes the latest commit unless `--pinned` |
| Host | Ubuntu 24.04, 96 CPUs, 503 GB RAM, passwordless `sudo` |
| Tools on the host | kubectl v1.33.7, clusterctl v1.13.5, helm v4.2.4, minikube v1.37.0, jq, envsubst, docker, libvirt |

## Files

| Path | What it is |
|---|---|
| `apply-changes.sh` | clones metal3-dev-env one level above the repository (if needed), at the latest commit or with `--pinned` at the experiments' one, and copies `files/` over it |
| `files/` | the modified files, at their path in metal3-dev-env |
| `changes.patch` | the same changes as a diff, for review |
| `env.sh` | the variables the install ran with (9 nodes, CentOS 10 image, Kubernetes v1.33.7, Redfish, cluster `test-cluster-m3`) |
| `host/` | host-side bring-up that survives a reboot (see below) |
| `workload-cluster/post-provision.sh` | kubeconfig, Calico v3.26.1 and metrics-server v0.9.0 in the new workload cluster |

The changes (details in `apply-changes.sh`):

- `02_configure_host.sh`: minikube with 8 GB and 8 CPUs;
- `vm-setup/roles/common/defaults/main.yml`: node VMs with 10 vCPUs and 32 GB;
- `tests/roles/run_tests/templates/main/metal3datatemplate-template.yaml`: the nodes' DNS
  servers (the host network's resolvers; **put your own network's**);
- `config_example.sh`, `disable_apparmor_driver_libvirtd.sh`: executable bit.

## Install

```bash
cd $REPO/metal3-dev-env_changes
./apply-changes.sh                       # -> $UPSTREAM/metal3-dev-env at the latest commit
# ./apply-changes.sh --pinned            #    or at the experiments' commit (warns: may no longer work)
source ./env.sh

sudo ufw disable                        # -> disabling firewall, it may block part of the installation

cd $UPSTREAM/metal3-dev-env
./01_prepare_host.sh && ./02_configure_host.sh && ./03_launch_mgmt_cluster.sh

# workload cluster: Cluster, control plane, then the 8 workers
./tests/scripts/provision/cluster.sh
./tests/scripts/provision/controlplane.sh
./tests/scripts/provision/worker.sh
kubectl get bmh -n metal3               # node-0 .. node-8 provisioned (node-0 or another one is the control plane)

$REPO/metal3-dev-env_changes/workload-cluster/post-provision.sh
```

To start over: `./cluster_cleanup.sh; ./host_cleanup.sh` in the metal3-dev-env folder.

## Surviving a reboot (`host/`)

On Ubuntu, metal3-dev-env creates the `provisioning` bridge and the `ironicendpoint` veth
with runtime-only commands, so a reboot loses them: libvirt's provisioning network then
has no bridge, the VMs cannot reach Ironic and Ironic crashes. Install the unit once:

```bash
sudo install -m 755 host/metal3-provisioning-net.sh /usr/local/sbin/
sudo install -m 644 host/metal3-provisioning-net.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now metal3-provisioning-net.service
```

After every reboot run `host/metal3-restore.sh`: it starts the libvirt networks, minikube,
the bridge inside the minikube VM and the support containers (registry, httpd-infra,
vbmc, sushy-tools), and restarts Ironic if it came up before the bridge. The Bare Metal
Operator then adopts the hosts again without reinstalling them.
