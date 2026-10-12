# DREEM

DREEM (operator and forecaster) is installed in the workload cluster from its Helm chart,
published on Harbor as an OCI artifact; the values for this testbed go here, as
`values.yaml` (to be added). Installation is below.

The test scripts (`../testbed/`) and `../check_setup.sh` rely on these names. The two
Deployments depend on how DREEM was installed, and the scripts find either pair:

| Installed from | Operator | Forecaster |
|---|---|---|
| the DREEM repository's manifests | `dreem-controller-manager` | `forecast-deployment` |
| the Helm chart (below), release `dreem` | `dreem-dreem-charts-operator` | `dreem-dreem-charts-forecast` |

For any other names (another Helm release name, say) set `DREEM_OPERATOR` and
`DREEM_FORECAST` (`testbed/lib.sh`).

| Object | Name |
|---|---|
| Namespace | `dreem` |
| Deployments | see above |
| ConfigMaps | `cluster-configuration-parameters` (`minNodes: "3"`, `maxNodes: "8"`, `selectionProfile`), `forecast-parameters` (`Enabled`, thresholds, `Request_rate_query`), `selection-weights-scale-down`, `selection-weights-scale-up` (the AHP weights of the ENERGY and QOS profiles) |
| CRDs (group `cluster.dreemk8s`) | `ClusterConfiguration`, `NodeSelecting`, `NodeHandling` |
| RBAC | the operator's service account may patch nodes (cordon) and create `pods/eviction` in `default` (drain) |

Install it **disabled**: both Deployments at 0 replicas and `Enabled: "false"` in
`forecast-parameters`. `testbed/test.sh` switches DREEM on for its arms, and
`test_CA.sh` / `test_Karpenter.sh` switch it off.

DREEM powers worker nodes on and off through their BMCs: `testbed/sync-bmc-secrets.sh`
(run by `init-testbed.sh` and `test.sh`) writes its `bmc-credentials-<node>` secrets from
the BareMetalHosts, so no credential belongs in the values.

## Install

The chart is `dreem-charts` on Harbor (public, no login needed):

| Item | Value |
|---|---|
| Chart | `oci://harbor.ng.crownlabs.polito.it/marco-miracapillo/dreem-k8s/dreem-charts` |
| Version | `0.1.1` (appVersion 0.0.32: operator 0.0.32, forecaster 0.0.60) |

OCI charts need no `helm repo add`: Helm pulls them straight from the registry. To look
at the chart and its default values first:

```bash
helm show chart  oci://harbor.ng.crownlabs.polito.it/marco-miracapillo/dreem-k8s/dreem-charts --version 0.1.1
helm show values oci://harbor.ng.crownlabs.polito.it/marco-miracapillo/dreem-k8s/dreem-charts --version 0.1.1
```

### What `values.yaml` must set for this testbed

The chart defaults target another cluster, so the testbed's values override them:

| Key | Value | Why |
|---|---|---|
| `operator.replicas` | `0` | installed switched off |
| `forecast.enabled` | `true` | without it the chart renders no forecaster Deployment at all |
| `operator.nodeSelector`, `forecast.nodeSelector` | `node-role.kubernetes.io/control-plane: ""` | kubeadm sets the label to `""`; the chart default `"true"` leaves the pods Pending |
| `prometheus.url` | `http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090` | the Prometheus of muBench's monitoring install (the default points at a kind cluster) |
| `config.clusterConfiguration.minNodes`, `maxNodes` | `3`, `8` | the testbed's bounds, the same as Cluster Autoscaler's |
| `config.forecastParameters.Enabled` | `false` | installed switched off |
| `config.bmcCredentials` | `[]` | `sync-bmc-secrets.sh` writes the Secrets from the BareMetalHosts |

### Install

The chart refuses any namespace but `dreem`, and installs into the workload cluster:

```bash
export KUBECONFIG=~/workload.kubeconfig        # the workload cluster, not the management one
helm upgrade --install dreem \
  oci://harbor.ng.crownlabs.polito.it/marco-miracapillo/dreem-k8s/dreem-charts --version 0.1.1 \
  --namespace dreem --create-namespace \
  -f $REPO/DREEM/values.yaml
```

`upgrade --install` installs the first time and applies a changed `values.yaml` later.

The forecaster's replica count is fixed at 1 in the chart, so switch it off by hand after
every install or upgrade:

```bash
kubectl scale deploy dreem-dreem-charts-forecast -n dreem --replicas=0
```

Check that it came up switched off:

```bash
kubectl get deploy -n dreem                     # dreem-dreem-charts-operator, -forecast: 0/0
kubectl get cm forecast-parameters -n dreem -o jsonpath='{.data.Enabled}'; echo   # false
kubectl get crd | grep cluster.dreemk8s         # the three DREEM CRDs
```

Then write the BMC secrets and check the whole setup:

```bash
unset KUBECONFIG
$REPO/testbed/sync-bmc-secrets.sh               # bmc-credentials-<node> (init-testbed.sh does it too)
$REPO/check_setup.sh                            # the "DREEM" lines must all be OK
```

### Uninstall

The chart keeps its CRDs (and every DREEM custom resource) on uninstall
(`crds.keep: true`); the last command deletes them:

```bash
export KUBECONFIG=~/workload.kubeconfig
helm uninstall dreem -n dreem
kubectl delete crd clusterconfigurations.cluster.dreemk8s nodeselectings.cluster.dreemk8s nodehandlings.cluster.dreemk8s
```
