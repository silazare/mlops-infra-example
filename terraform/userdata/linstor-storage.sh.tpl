#!/bin/bash
set -ex

export DEBIAN_FRONTEND=noninteractive

# === 1. LVM + DRBD userspace + extra kernel modules ===
apt-get update
apt-get install -y \
  lvm2 \
  drbd-utils \
  thin-provisioning-tools \
  linux-modules-extra-$(uname -r) \
  nvme-cli

# === 2. DRBD kernel module — load + persist ===
modprobe drbd usermode_helper=disabled
echo "drbd" > /etc/modules-load.d/drbd.conf
echo "options drbd usermode_helper=disabled" > /etc/modprobe.d/drbd.conf

# === 3. udev rule: stable symlink /dev/linstor-data → first non-root NVMe ===
cat > /etc/udev/rules.d/99-linstor-data.rules <<'UDEV'
KERNEL=="nvme[1-9]n1", SUBSYSTEM=="block", ATTRS{model}=="Amazon Elastic Block Store", SYMLINK+="linstor-data"
UDEV
udevadm control --reload-rules
udevadm trigger

# Wait up to 30s for the symlink — Piraeus satellite will look for /dev/linstor-data
for i in $(seq 1 30); do
  [ -e /dev/linstor-data ] && break
  sleep 1
done

# === 4. Module-provided pre-bootstrap hook if set in TF ===
${pre_bootstrap_user_data}

# === 5. EKS bootstrap — join kubelet to the cluster.
/etc/eks/bootstrap.sh ${cluster_name} \
  --b64-cluster-ca ${cluster_auth_base64} \
  --apiserver-endpoint ${cluster_endpoint}

# === 6. Module-provided post-bootstrap hook if set in TF ===
${post_bootstrap_user_data}
