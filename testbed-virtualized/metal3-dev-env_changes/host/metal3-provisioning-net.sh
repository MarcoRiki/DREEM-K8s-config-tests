#!/usr/bin/env bash
#
# Recreate the metal3-dev-env "provisioning" host bridge and the
# ironicendpoint/ironic-peer veth pair.
#
# WHY THIS EXISTS
#   On Ubuntu, metal3-dev-env builds this plumbing in
#   ubuntu_bridge_network_configuration.sh using runtime-only commands
#   (brctl addbr / ip link add / ip addr add).  None of it is persisted, so
#   every reboot loses the provisioning bridge.  The "external" bridge
#   survives only because libvirt owns it and autostarts it.
#
#   Without this, libvirt's "provisioning" network (forward mode=bridge)
#   starts but has no bridge to attach to, the node VMs cannot reach Ironic,
#   and the Ironic pod crashes because 172.22.0.1 does not exist.
#
# Idempotent: safe to run repeatedly and at every boot.
#
set -euo pipefail

BRIDGE="${BRIDGE:-provisioning}"
VETH_HOST="${VETH_HOST:-ironicendpoint}"
VETH_PEER="${VETH_PEER:-ironic-peer}"
# BARE_METAL_PROVISIONER_IP/CIDR as resolved by metal3-dev-env lib/network.sh
# (BARE_METAL_PROVISIONER_NETWORK default 172.22.0.0/24 -> host address .1)
PROVISIONER_IP="${PROVISIONER_IP:-172.22.0.1/24}"

log() { echo "metal3-provisioning-net: $*"; }

# 1. the bridge itself
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    log "creating bridge $BRIDGE"
    ip link add name "$BRIDGE" type bridge
fi

# 2. the veth pair that carries the host-side Ironic endpoint address
if ! ip link show "$VETH_HOST" >/dev/null 2>&1; then
    log "creating veth $VETH_HOST <-> $VETH_PEER"
    ip link add "$VETH_HOST" type veth peer name "$VETH_PEER"
fi

# 3. peer into the bridge (no-op if already enslaved)
ip link set "$VETH_PEER" master "$BRIDGE"

# 4. host-side address; 'replace' so a stale address is corrected in place
ip addr replace "$PROVISIONER_IP" dev "$VETH_HOST"

# 5. bring everything up
ip link set "$BRIDGE" up
ip link set "$VETH_HOST" up
ip link set "$VETH_PEER" up

log "ready: $BRIDGE up, $VETH_HOST has ${PROVISIONER_IP}"
