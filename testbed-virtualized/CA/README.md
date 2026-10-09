# Cluster Autoscaler

Cluster Autoscaler (CA) v1.29.0 with the Cluster API provider: the baseline node-level
autoscaler DREEM is compared with. It scales the worker MachineDeployment
`test-cluster-m3`, so Metal3 provisions and deprovisions BareMetalHosts when CA adds or
removes a node.

## Where it runs

CA runs in the **management cluster** (minikube), in `kube-system`, next to Cluster API.
It reads Machines and MachineDeployments there with its own service account, and reaches
the workload cluster (Nodes, Pods) through the kubeconfig stored in the secret
`dreem-mmiracapillo-cluster-kubeconfig`. It uses no worker resources. Karpenter uses the
same secret (see `../Karpenter/`).

## Files

| File | What it is |
|---|---|
| `ca.yaml` | Deployment (0 replicas), service account, cluster roles for the workload cluster and for Cluster API |

## Install (once)

```bash
cd $REPO/CA

# 1. workload-cluster kubeconfig as a secret in the management cluster
kubectl -n kube-system create secret generic dreem-mmiracapillo-cluster-kubeconfig \
  --from-file=value=$HOME/workload.kubeconfig

# 2. CA, switched off (the Deployment has replicas: 0)
export AUTOSCALER_NS=kube-system
envsubst '${AUTOSCALER_NS}' < ca.yaml | kubectl apply -f -

# 3. node-group bounds on the worker MachineDeployment: CA finds node groups through
#    these annotations; min 3 is the same floor as DREEM (minNodes) and Karpenter (base)
kubectl -n metal3 annotate machinedeployment test-cluster-m3 --overwrite \
  cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size="3" \
  cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size="8" \
  cluster.x-k8s.io/autoscaling-options-scaledownutilizationthreshold="0.4"
```

Installed with 0 replicas, CA does nothing. `testbed/test_CA.sh` scales it to 1 for the CA
arm and back to 0 at the end; `test.sh`, `test_CA.sh` and `test_Karpenter.sh` switch it
off before they restore the fleet.

## Settings (`ca.yaml`)

| Flag | Value | Why |
|---|---|---|
| `--node-group-auto-discovery` | `clusterapi:clusterName=test-cluster-m3` | the MachineDeployment carrying the min/max annotations |
| `--scale-down-utilization-threshold` | 0.4 | a node is a removal candidate below 40 % of its CPU requested |
| `--scale-down-unneeded-time` | 10m | how long a node must stay a candidate |
| `--scale-down-delay-after-add` | 10m | no removal in the 10 minutes after a node was added |
| `--scale-down-unready-time` | 5m | an unready node goes after 5 minutes |
| `--new-pod-scale-up-delay` | 1m | Pending pods younger than this do not trigger a scale-up |
| `--skip-nodes-with-system-pods` | false | CoreDNS and other system pods run on workers |
| `--skip-nodes-with-local-storage` | false | Istio sidecars give every workload pod emptyDir volumes |

Karpenter's NodePool uses the same 10 minutes (`consolidateAfter`), so the two
comparisons wait equally long before removing a node.

## What to state when comparing

`test-cluster-m3` is a single MachineDeployment holding high- and low-consumption hosts.
CA models a node group as homogeneous: it cannot choose a low-consumption host over a
high-consumption one when it adds a node (Metal3 picks any available host), and when it
removes one it looks at utilization, not consumption.
