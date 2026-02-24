# METAL3-DEV-ENV CONFIGUTION
This document describes how to set up a development environment for Metal3 in order to fully test DREEM but on virtual machines instead of bare metal servers. This environment is useful for developers who want to test DREEM on a local machine without the need of having access to a bare metal infrastructure.

## Prerequisites
We assume that you have already set up the Metal3 development environment on your local machine. If you haven't done it yet, you can follow the official documentation [here](https://github.com/metal3-io/metal3-dev-env.git). We used the commit `339f90525123a95fd2332f06975b93a7335e6e2c` of the `main` branch of the `metal3-dev-env` repository for our tests.

## Steps to set up the environment
1. Clone the `metal3-dev-env` repository
2. Set the following environments variables if you want deploy the same environment as the one used for the DREEM preliminary tests:
```bash
export BOOTSTRAP_CLUSTER=minikube
export IMAGE_NAME=CENTOS_10_NODE_IMAGE_K8S_v1.33.7.qcow2
export KUBERNETES_VERSION=v1.33.7
export TARGET_NODE_MEMORY=16384
export WORKER_MACHINE_COUNT=3
export CONTROL_PLANE_MACHINE_COUNT=1
export NUM_NODES=4
```

3. Run the `make` command to deploy the environment. This will create a management cluster with Metal3 and a workload cluster with 4 nodes (1 control plane and 3 worker nodes) where you can deploy the microservice application and run the DREEM tests.

4. Once the environment is deployed, you can follow the instructions in the `DREEM` repository to deploy it on the management cluster (the minikube VM) and run the tests on the workload cluster (the 3+1 nodes created by Metal3).

5. Follow the instruction in the `README.md` file of this repository to run the `run.sh` script to deploy the same microservice application and generate the traffic as the one used for the DREEM validation.

