# Karpenter (Cluster API provider)

Karpenter as a third scaling arm next to DREEM and Cluster Autoscaler. Karpenter has no
Metal3 or bare-metal provider: it runs here through the
[Cluster API provider](https://github.com/kubernetes-sigs/karpenter-provider-cluster-api),
which scales a MachineDeployment exactly like Cluster Autoscaler does, so Metal3 provisions
and deprovisions BareMetalHosts in both arms. The provider is experimental and publishes no
image: it is built from a pinned commit.

| Item | Value |
|---|---|
| Provider commit | `9dc28cf` (main after v0.2.0: fixes machine selection on create, honours the max-size annotation, batches creates and deletes) |
| Karpenter core | v1.5.0 |
| Cluster API types | v1beta1, still served by the management cluster (Cluster API v1.13.5) |
| Image | `harbor.ng.crownlabs.polito.it/marco-miracapillo/karpenter-clusterapi-controller:9dc28cf`, pinned by digest `sha256:3eb8da35106d3e9b7aaaaa87f627ad169369217c8484a08be8caeec0f6042a60` (linux/amd64) |

## Where it runs and why

Like Cluster Autoscaler, Karpenter runs in the **management cluster** (minikube) and reaches
the workload cluster through the kubeconfig secret `dreem-mmiracapillo-cluster-kubeconfig`:

```
management cluster (minikube)                       workload cluster
  Karpenter controller  --KUBECONFIG--------------->  Nodes, Pods, NodePool, NodeClaims
     |                                                ClusterAPINodeClass, CRDs
     +--CLUSTER_API_KUBECONFIG (own service account)
     v
  MachineDeployment test-cluster-m3-karpenter --> Machines --> Metal3 --> BareMetalHosts
```

- The image is in Harbor next to the DREEM images; the project is public, so minikube pulls
  it without credentials.
- The controller uses no worker resources, the same as Cluster Autoscaler.
- `CLUSTER_API_KUBECONFIG` is mandatory: without it the provider looks for Machines in the
  workload cluster.

## Files

| File | What it is |
|---|---|
| `build-image.sh` | clones the provider at the pinned commit, builds the linux/amd64 image (Go 1.25), pushes it to Harbor, copies the CRDs of the same commit to `crds/`; only needed to rebuild |
| `crds/` | NodePool, NodeClaim and ClusterAPINodeClass CRDs (workload cluster) |
| `karpenter.yaml` | controller, service account, Cluster API RBAC and management kubeconfig (management cluster); starts with 0 replicas |
| `machinedeployment.sh` | creates, renders, shows or deletes Karpenter's MachineDeployment (management cluster) |
| `nodepool.yaml` | ClusterAPINodeClass and NodePool (workload cluster) |
| `smoke-test.yaml` | workload for the feasibility check |
| `feasibility-check.sh` | runs the feasibility check, timed and logged, and restores the testbed |
| `warmup.yaml` | placeholder pods for the warm start of the Karpenter arm (namespace `karpenter-warmup`) |
| `../testbed/test_Karpenter.sh` | the Karpenter arm of the experiment |

## Install (once)

```bash
cd $REPO/Karpenter

# 1. the image, already in Harbor (the CRDs of the same commit are in crds/)
export KARPENTER_IMAGE=harbor.ng.crownlabs.polito.it/marco-miracapillo/karpenter-clusterapi-controller:9dc28cf@sha256:3eb8da35106d3e9b7aaaaa87f627ad169369217c8484a08be8caeec0f6042a60

# 2. workload kubeconfig in the management cluster (already there if CA is installed)
kubectl -n kube-system get secret dreem-mmiracapillo-cluster-kubeconfig >/dev/null 2>&1 || \
  kubectl -n kube-system create secret generic dreem-mmiracapillo-cluster-kubeconfig \
    --from-file=value=$HOME/workload.kubeconfig

# 3. CRDs, node class and NodePool in the workload cluster
kubectl --kubeconfig ~/workload.kubeconfig apply -f crds/
kubectl --kubeconfig ~/workload.kubeconfig apply -f nodepool.yaml

# 4. controller in the management cluster, switched off (0 replicas)
envsubst '${KARPENTER_IMAGE}' < karpenter.yaml | kubectl apply -f -
```

Installed and switched off, Karpenter does nothing: the NodePool alone has no effect, and
its MachineDeployment exists only during the Karpenter arm.

## How the Karpenter arm uses it

`../testbed/test_Karpenter.sh` runs the arm, with the same flags and result folder as
`test.sh` and `test_CA.sh`:

```bash
cd $REPO/testbed
./test_Karpenter.sh --rep=1 --anchors=mixed --latency=yes --delay=2ms --repair=yes
```

1. **Fleet as for Cluster Autoscaler:** DREEM, Cluster Autoscaler and Karpenter off,
   worker BareMetalHosts attached (Metal3 must provision them), all 8 workers.
2. **Base MachineDeployment down to 3 fixed hosts**, the same floor as DREEM (`minNodes`)
   and Cluster Autoscaler (min size). Karpenter never removes these: it only manages
   nodes it created. By default one host per group, both sizes, mean consumption profile
   closest to the fleet's (`node-1`, `node-2`, `node-7`); `--base-hosts=` overrides. The
   other Machines are marked `cluster.x-k8s.io/delete-machine`, so Cluster API removes
   exactly those.
3. **Karpenter's MachineDeployment** (`machinedeployment.sh create`), `nodepool.yaml`
   re-applied, its CPU limit checked against the 5 free hosts.
4. **Warm start:** `warmup.yaml` at 5 replicas, one pod per node and only on Karpenter
   nodes, with the controller on: Karpenter adds 5 nodes, so the arm starts with all 8
   workers on, like the others. Then the controller is switched off and the placeholders
   are deleted.
5. **Workload deployed and the arm prepared as for Cluster Autoscaler** (profiles,
   latency, placement reset), the controller still off.
6. **Controller on** right before the workload, as Cluster Autoscaler. A starting
   controller marks a pod event on every node that has pods, so consolidation waits
   `consolidateAfter` (10 min) from there. During the run the NodePool caps Karpenter at
   5 nodes; every minute the node map and the NodeClaims are snapshotted.
7. **After the run:** controller log, NodeClaims and events saved; the NodePool limit set
   to 0 (no new node for the pods that go Pending), all NodeClaims deleted (Karpenter
   drains its nodes and gives the Machines back), controller off, Karpenter's
   MachineDeployment deleted, `nodepool.yaml` re-applied. The next `test.sh` restores the
   base MachineDeployment to all workers.

If the script stops early it switches the controller off and leaves Karpenter's nodes.
The next `test.sh`, `test_CA.sh` or `test_Karpenter.sh` removes them, or by hand:

```bash
cd $REPO/testbed && bash -c 'source ./run-lib.sh; karpenter_off'
```

## Feasibility check (about an hour)

It confirms that Karpenter both adds and removes Metal3 nodes. Run it between campaign runs:
it uses the same BareMetalHosts.

**Prerequisites.** After a DREEM run the worker BareMetalHosts are *detached* from Metal3
(DREEM powers servers through Redfish behind Metal3's back); in that state Metal3 can neither
deprovision nor provision a host, so a Karpenter Machine would never get one. Re-attach them
as for Cluster Autoscaler, and switch DREEM off:

```bash
kubectl --kubeconfig ~/workload.kubeconfig -n dreem scale deployment \
  dreem-controller-manager forecast-deployment --replicas=0
cd $REPO/testbed && bash -c 'source ./run-lib.sh; provision_fleet ca'
```

The next `test.sh` switches DREEM back on and detaches the hosts again.

**The check** is `feasibility-check.sh`: each stage is timed and logged to
`feasibility-check-<UTC time>.log`, and the testbed is put back at the end (`--keep` skips
the clean-up). The steps it runs:

```bash
cd $REPO/Karpenter
W="kubectl --kubeconfig $HOME/workload.kubeconfig"

# free two hosts for Karpenter: base MachineDeployment from 8 to 6 workers
kubectl -n metal3 scale machinedeployment test-cluster-m3 --replicas=6
./machinedeployment.sh create
kubectl -n kube-system scale deployment karpenter --replicas=1

# scale-up: two pods only Karpenter nodes can host, one per node
$W apply -f smoke-test.yaml
$W scale deployment karpenter-smoke --replicas=2
$W get nodeclaims -w                                   # Launched, Registered, Initialized
./machinedeployment.sh show                            # 2 Machines, claimed
$W get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type,size,group

# scale-down: empty nodes removed after consolidateAfter (10 min)
$W scale deployment karpenter-smoke --replicas=0
$W get nodeclaims -w                                   # deleted after ~10 min; Machines and replicas follow

# clean up
$W delete -f smoke-test.yaml
kubectl -n kube-system scale deployment karpenter --replicas=0
./machinedeployment.sh delete
kubectl -n metal3 scale machinedeployment test-cluster-m3 --replicas=8
```

**Pass:** both NodeClaims get a node within 15 minutes (Karpenter's registration limit), the
nodes carry `karpenter.sh/nodepool=metal3` plus `size` and `group` from the BareMetalHost,
and scaling to 0 removes both nodes, Machines and replicas.

**Expected warning:** a `UnregisteredTaintMissing` warning event on each NodeClaim. Karpenter's nodes should
register with the `karpenter.sh/unregistered` taint, but the bootstrap template is shared
with the other arms, and a taint there would block pods on every node CA or DREEM brings
up. Without it Karpenter still registers the node and copies its labels.

## Differences from Cluster Autoscaler to state in the paper

- **Fixed floor:** like the other arms the Karpenter arm starts with all 8 workers on (the
  warm start), but 3 of them are fixed hosts Karpenter cannot remove; DREEM and Cluster
  Autoscaler can remove any node down to 3. The base hosts are chosen so that their mean
  consumption profile is close to the fleet's (273 against 270).
- **Start of the run:** a Karpenter node still empty when the workload starts can go
  within a minute, because its last pod event dates from the warm start; Cluster
  Autoscaler waits 10 minutes for any node. After the placement reset every node normally
  hosts pods.
- **Scale-down:** no utilization threshold: any Karpenter node whose pods fit on the others
  is removed after 10 minutes (the same wait as CA's `--scale-down-unneeded-time`), one at a
  time (disruption budget). Which node goes is decided by the cost of moving its pods, not
  by its consumption.
- **No energy awareness:** the provider prices every node at 0, so Karpenter never prefers
  a cheaper node, nor replaces an expensive one.
- **Node labels decided at join:** Karpenter cannot know which BareMetalHost a new Machine
  will get, so it does not know the `size` and `group` of a node before it exists. A
  Pending pod that *requires* a size (an anchor) cannot trigger a new node; preferred group
  affinity is ignored when deciding to add one.

## Uninstall

```bash
kubectl --kubeconfig ~/workload.kubeconfig delete nodeclaims --all
envsubst '${KARPENTER_IMAGE}' < karpenter.yaml | kubectl delete -f -
./machinedeployment.sh delete
kubectl --kubeconfig ~/workload.kubeconfig delete -f nodepool.yaml
kubectl --kubeconfig ~/workload.kubeconfig delete -f crds/
```
