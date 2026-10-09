# DREEM

Placeholder for the Helm values that install DREEM (operator and forecaster) in the
workload cluster. The chart itself lives with the DREEM sources.

The test scripts (`../testbed/`) and `../check_setup.sh` rely on these names, so the
values must keep them:

| Object | Name |
|---|---|
| Namespace | `dreem` |
| Deployments | `dreem-controller-manager` (operator), `forecast-deployment` (forecaster) |
| ConfigMaps | `cluster-configuration-parameters` (`minNodes: "3"`, `maxNodes: "8"`, `selectionProfile`), `forecast-parameters` (`Enabled`, thresholds, `Request_rate_query`), `selection-weights-scale-down`, `selection-weights-scale-up` (the AHP weights of the ENERGY and QOS profiles) |
| CRDs (group `cluster.dreemk8s`) | `ClusterConfiguration`, `NodeSelecting`, `NodeHandling` |
| RBAC | the operator's service account may patch nodes (cordon) and create `pods/eviction` in `default` (drain) |

Install it **disabled**: both Deployments at 0 replicas and `Enabled: "false"` in
`forecast-parameters`. `testbed/test.sh` switches DREEM on for its arms, and
`test_CA.sh` / `test_Karpenter.sh` switch it off.

DREEM powers worker nodes on and off through their BMCs: `testbed/sync-bmc-secrets.sh`
(run by `init-testbed.sh` and `test.sh`) writes its `bmc-credentials-<node>` secrets from
the BareMetalHosts, so no credential belongs in the values.
