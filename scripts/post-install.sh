#!/bin/bash
# Grupa Festiwale — post-install for installimage
# Runs inside chroot after Debian Trixie install

set -euo pipefail

# Proxmox VE 9 repo
wget -qO /usr/share/keyrings/proxmox-release-trixie.gpg http://download.proxmox.com/debian/proxmox-release-trixie.gpg 2>/dev/null || true
echo "deb [signed-by=/usr/share/keyrings/proxmox-release-trixie.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

# ZFS ARC limit 16GB
mkdir -p /etc/modprobe.d
echo "options zfs zfs_arc_max=17179869184" > /etc/modprobe.d/zfs.conf

# Hostname
echo "pve1" > /etc/hostname
printf "127.0.0.1\tlocalhost\n136.243.41.254\tpve1.grupafestiwale.pl pve1\n::1\t\tlocalhost\n" > /etc/hosts

# Sysctl
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-proxmox.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-proxmox.conf
echo "vm.swappiness=10" >> /etc/sysctl.d/99-proxmox.conf

echo "[+] Post-install done"
