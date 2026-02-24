# DREEM-K8s-config-tests
This Repo contains the configurations file for the validation of DREEM for bare metal K8s infrastructures.

## Repo structure

- `config/`: contains the configuration files to test DREEM on bare metal K8s infrastructures.
    - `K8sParameters.json`: contains the parameters to correctly deploy the microservice application on the K8s cluster.
    - `RunnerParameters.json`: contains the parameters to correctly generate the traffic on the target cluster. Here you **must** specify the `ms_access_gateway`, which is typically the control plane node IP address and the NodePort port of the `gw-nginx` service (e.g. 192.168.111.100:31113).
    - `TrafficParameters.json`: contains the parameters to correctly generate the traffic on the target cluster. The traditional usage has been modified to allow more microservices to be called as ingress points for the traffic generation. The `TrafficGenerator.py` script has been properly modified to allow the user to specify a list of microservices as ingress points.
    - `WorkModelParameters.json`: specifies the parameters for the functions that will be executed when a microservice call is made (see muBench documentation for more details about the WorkModel and CustomFunction concepts).
    - `requirements.txt`: contains the updated dependencies to run mubench
    - `run_stress_ng.py`: the CustomFunction to run the stress-ng tool inside the microservice application deployed on the K8s cluster to generate the load on the cluster.
    - `workload.json`: the file containing the sequence of microservice calls to generate the traffic on the K8s cluster. This file is used by `TrafficGenerator.py` to generate the traffic on the K8s cluster in combination with the `TrafficParameters.json` file.
    - `workmdel.json`
    - `TrafficGenerator.py`
- `run.sh`: script to download all the necessary files required to generate the traffic and run the DREEM tests on a bare metal K8s infrastructure.
    -  It will download the `muBench` tool which is used to deploy a microservice application on the K8s cluster and generate the traffic.
    - It will install the dependencies to run `muBench` on the host (not Docker)
    - It will replace the parameters in the configuration files with the values specified in the `config/` folder.
    - It will deploy the microservice application on the K8s cluster.
    - It will check whether DREEM is correctly deployed on the K8s cluster.
- `README.md`: this file.

## Usage
To correcly run the script you need to export the following environment variables:
- `MANAGEMENT_KUBECONFIG`: the path to the kubeconfig file of the management cluster (the cluster where DREEM, CAPI and Metal3 are deployed).
- `TARGET_KUBECONFIG`: the path to the kubeconfig file of the workload cluster (the cluster where the microservice application will be deployed and where the traffic will be generated).