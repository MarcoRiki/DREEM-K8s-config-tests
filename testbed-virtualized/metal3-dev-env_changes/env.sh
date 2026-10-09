# Environment for installing metal3-dev-env and provisioning the workload cluster, as used
# for the experiments. Source it in the shell that runs the metal3-dev-env scripts:
#
#   source $REPO/metal3-dev-env_changes/env.sh
#
# metal3-dev-env reads these variables (config_<user>.sh was left as config_example.sh).

# 9 libvirt VMs: 1 control plane + 8 workers, booted through Redfish (sushy-tools)
export NUM_NODES=9
export CONTROL_PLANE_MACHINE_COUNT=1
export WORKER_MACHINE_COUNT=8
export BMC_DRIVER="redfish"
export NODE_HOSTNAME_FORMAT="test-node-%d"

# node image and Kubernetes version
export IMAGE_OS=centos
export IMAGE_NAME=CENTOS_10_NODE_IMAGE_K8S_v1.33.7.qcow2
export KUBERNETES_VERSION=v1.33.7

# workload cluster name (the testbed scripts and the CA/Karpenter manifests use it)
export CLUSTER_NAME=test-cluster-m3

# management cluster
export BOOTSTRAP_CLUSTER=minikube

# memory of every node VM, in MB (vCPUs come from vm-setup/roles/common/defaults/main.yml)
export TARGET_NODE_MEMORY=32768
