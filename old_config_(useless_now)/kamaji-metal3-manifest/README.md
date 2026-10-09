## INSTRUCTION FOR DEPLOYMENT ON RESTART SERVERS
This document describes how to deploy a K8s bare metal cluster with RESTART servers and run the DREEM tests on it using the configurations provided in this repository.
The configuration is based on Kamaji control plane + Metal3 for the workload bare metal cluster.


# Comand to run the script:
```bash
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.35/deploy/local-path-storage.yaml
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml
```
metalLB configuration:
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.11.22-192.168.11.22
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
```
Then, to deploy the Kamaji control plane, you can run the following command:
```bash
    helm repo add clastix https://clastix.github.io/charts
    helm upgrade --install --namespace kamaji-system --create-namespace kamaji clastix/kamaji
```

