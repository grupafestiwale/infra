#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== Grupa Festiwale — First Boot Setup ==="
echo "Started: $(date)"

echo "=== [1/7] Adding Proxmox VE 9 repo... ==="
wget -qO /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg http://download.proxmox.com/debian/proxmox-release-trixie.gpg 2>/dev/null || true
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

echo "=== [2/7] Updating system... ==="
apt-get update
apt-get dist-upgrade -y

echo "=== [3/7] Installing Proxmox VE kernel... ==="
apt-get install -y proxmox-default-kernel
apt-get remove -y linux-image-amd64 'linux-image-6.*' 2>/dev/null || true
update-grub

echo "=== [4/7] Installing Proxmox VE... ==="
apt-get install -y proxmox-ve postfix open-iscsi chrony
apt-get remove -y os-prober 2>/dev/null || true

echo "=== [5/7] Removing subscription nag... ==="
PL="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [ -f "$PL" ]; then
    cp "$PL" "${PL}.bak"
    sed -i "s/res === null || res === undefined || \!res || res.data.status.toLowerCase() !== 'active'/false/g" "$PL"
    systemctl restart pveproxy 2>/dev/null || true
fi

echo "=== [6/7] Creating ZFS partitions + rpool mirror... ==="
modprobe zfs 2>/dev/null || true

for disk in /dev/nvme0n1 /dev/nvme1n1; do
    LAST=$(parted -s "$disk" unit s print | awk '/^ [0-9]/{e=$3} END{print e}' | tr -d s)
    parted -s "$disk" mkpart primary $((LAST+1))s 100% || true
done
sleep 2; partprobe; sleep 2

P1=""; P2=""
for p in /dev/nvme0n1p4 /dev/nvme0n1p5; do [ -b "$p" ] && P1="$p" && break; done
for p in /dev/nvme1n1p4 /dev/nvme1n1p5; do [ -b "$p" ] && P2="$p" && break; done

if [ -n "$P1" ] && [ -n "$P2" ]; then
    zpool create -f -o ashift=12 -o autotrim=on \
        -O compression=lz4 -O atime=off -O xattr=sa -O dnodesize=auto \
        rpool mirror "$P1" "$P2"
    zfs create rpool/data
    zfs create rpool/data/vm-disks
    zfs create rpool/data/ct-volumes
    zfs create rpool/data/backups
    zfs create rpool/data/iso
    zfs create rpool/data/templates
    pvesm add zfspool local-zfs -pool rpool/data/vm-disks -content images,rootdir -sparse 1
    echo "[+] ZFS rpool created:"
    zpool status rpool
    zfs list -r rpool
else
    echo "[!] ZFS partitions not found! Create manually after reboot."
fi

echo "=== [7/7] Final setup... ==="
echo 17179869184 > /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || true
mkdir -p /etc/modprobe.d
echo "options zfs zfs_arc_max=17179869184" > /etc/modprobe.d/zfs.conf
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-proxmox.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-proxmox.conf
sysctl -p /etc/sysctl.d/99-proxmox.conf 2>/dev/null || true
apt-get install -y python3 python3-apt sudo curl wget git
mkdir -p /opt/scripts

echo ""
echo "==========================================="
echo "  PROXMOX VE 9 INSTALLATION COMPLETE"
echo "==========================================="
echo ""
echo "  Reboot now:  reboot"
echo "  Web UI:      https://136.243.41.254:8006"
echo "  Then run Ansible from laptop."
echo ""
echo "Finished: $(date)"
