# bin/sh

# Download the mubench repository
printf "Downloading the mubench repository...\n"
cd
git clone https://github.com/mSvcBench/muBench.git
cd muBench

# Install the dependencies
printf "Installing the dependencies to run muBench...\n"
python3 -m venv .venv
source .venv/bin/activate
pip3 install wheel
pip3 install -r requirements.txt

# Copy the configuration files in the proper location
printf "Copying the configuration files in the proper location in the muBench folder...\n"
cp ../config/K8sParameters.json Configs/K8sParameters.json
cp ../config/RunnerParameters.json Configs/RunnerParameters.json
cp ../config/TrafficParameters.json Configs/TrafficParameters.json
cp ../config/WorkModelParameters.json Configs/WorkModelParameters.json

# Deploy the microservices application
printf "Switching to the target K8s cluster to deploy the microservices application...\n"
export KUBECONFIG=$TARGET_KUBECONFIG
python3 Deployers/K8sDeployer/RunK8sDeployer.py -c Configs/K8sParameters.json
sleep 60
printf "Waiting for the microservices application to be fully deployed on the target Kubernetes cluster...\n"
kubectl wait --for=condition=available --timeout=600s deployments --all


# Check whether DREEM is running on the management cluster
printf "Checking whether DREEM is properly installed on the management cluster...\n"
export KUBECONFIG=$MANAGEMENT_KUBECONFIG
if [ $(kubectl get crds | grep dreem | wc -l) -ne 3 ]; then
    printf "DREEM CRDs are not properly installed on the management cluster. Please install DREEM before running this script.\n"
    exit 1
fi
# check whether the DREEM controller is running
if [ $(kubectl get pods -n dreem | grep dreem-controller | grep Running | wc -l) -ne 1 ]; then
    printf "DREEM controller is not running on the management cluster. Please install DREEM before running this script.\n"
    exit 1
fi
printf "DREEM is properly installed on the management cluster.\n"