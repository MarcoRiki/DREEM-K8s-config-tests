#!/usr/bin/env bash
#
# Post-reboot bring-up for the metal3-dev-env on this host.
#
# The host-side provisioning bridge is handled automatically at boot by
# metal3-provisioning-net.service.  Everything below has to happen *after*
# boot, because it depends on the minikube VM and on Docker:
#
#   * minikube's in-VM "ironicendpoint" bridge (lost whenever the VM stops)
#   * the sushy-tools / vbmc / httpd-infra / registry containers
#
# Ironic's database is ephemeral, so on startup BMO re-registers the hosts and
# *adopts* them back to "provisioned" - the node disks are not re-imaged.
#
# Idempotent: safe to re-run at any time.
#
set -euo pipefail

# metal3-dev-env defaults (lib/network.sh, BARE_METAL_PROVISIONER_NETWORK=172.22.0.0/24)
PROV_IFACE="${PROV_IFACE:-ironicendpoint}"
MINIKUBE_PROV_NIC="${MINIKUBE_PROV_NIC:-eth2}"
MINIKUBE_PROV_IP="${MINIKUBE_PROV_IP:-172.22.0.9/24}"   # INITIAL_BARE_METAL_PROVISIONER_BRIDGE_IP
CONTAINERS=(registry httpd-infra vbmc sushy-tools)

say() { printf '\n==> %s\n' "$*"; }

say "1/5  host provisioning bridge"
sudo systemctl start metal3-provisioning-net.service
ip -br addr show "$PROV_IFACE"

say "2/5  libvirt networks"
for net in default external mk-minikube provisioning; do
    state=$(sudo virsh net-info "$net" 2>/dev/null | awk '/^Active/{print $2}')
    if [[ "$state" != "yes" ]]; then
        echo "starting libvirt network: $net"
        sudo virsh net-start "$net"
    else
        echo "libvirt network already active: $net"
    fi
done

say "3/5  minikube management cluster"
if ! minikube status --format '{{.Host}}' 2>/dev/null | grep -q Running; then
    minikube start
else
    echo "minikube already running"
fi

# Recreate the in-VM bridge that carries the cluster side of the provisioning
# network.  minikube loses this every time the VM stops.
say "4/5  minikube in-VM $PROV_IFACE bridge"
minikube ssh -- "
    sudo brctl addbr $PROV_IFACE 2>/dev/null || true
    sudo ip link set $PROV_IFACE up
    sudo brctl addif $PROV_IFACE $MINIKUBE_PROV_NIC 2>/dev/null || true
    sudo ip addr replace $MINIKUBE_PROV_IP dev $PROV_IFACE
    ip -br addr show $PROV_IFACE
"

say "5/5  metal3 support containers"
for c in "${CONTAINERS[@]}"; do
    if [[ "$(sudo docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == "true" ]]; then
        echo "already running: $c"
    else
        echo "starting: $c"
        sudo docker start "$c" >/dev/null
    fi
done

say "waiting for Ironic"
# Ironic crashes if it starts before the bridge exists; restart it if unhealthy.
if ! kubectl -n baremetal-operator-system wait --for=condition=Ready \
        pod -l name=ironic --timeout=120s >/dev/null 2>&1; then
    echo "Ironic not ready - restarting it now that the bridge is up"
    kubectl -n baremetal-operator-system delete pod -l name=ironic --ignore-not-found
    kubectl -n baremetal-operator-system wait --for=condition=Ready \
        pod -l name=ironic --timeout=300s
fi

say "status"
kubectl -n baremetal-operator-system get pods
kubectl get bmh -n metal3 2>/dev/null || true
sudo virsh list --all

cat <<'NOTE'

BMO powers the node VMs back on by itself (the BareMetalHosts are online:true)
and adopts them back to "provisioned".  Give it a couple of minutes.

If a node stays off while its BMH claims poweredOn:true, Ironic is holding a
stale cached power state; power it via its Redfish BMC rather than virsh so the
BMC layer stays consistent:

  kubectl -n metal3 get bmh <host> -o jsonpath='{.spec.bmc.address}'
  curl -sk -u admin:<pw> -X POST -H 'Content-Type: application/json' \
       -d '{"ResetType":"On"}' \
       https://192.168.111.1:8000/redfish/v1/Systems/<uuid>/Actions/ComputerSystem.Reset

NOTE
