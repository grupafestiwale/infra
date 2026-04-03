#!/bin/bash
###############################################################################
# Grupa Festiwale — Hetzner Proxmox VE 9.1 Installation Script
#
# Run this in Hetzner RESCUE MODE (SSH into rescue system first)
#
# Usage:
#   ssh root@136.243.41.254    # (rescue password from Robot)
#   curl -fsSL https://raw.githubusercontent.com/grupafestiwale/infra/main/scripts/hetzner-install.sh | bash
#   # or
#   wget -qO- https://raw.githubusercontent.com/grupafestiwale/infra/main/scripts/hetzner-install.sh | bash
#
# What it does:
#   1. Detects NVMe drives
#   2. Creates installimage config (Proxmox VE + RAID1 + ZFS data pool)
#   3. Runs installimage non-interactively
#   4. Post-install: adds SSH key, creates ZFS pool, preps for Ansible
#   5. Reboots into Proxmox VE 9.1
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

header() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}========================================${NC}"
}

###############################################################################
# PREFLIGHT
###############################################################################
header "Grupa Festiwale — Proxmox VE 9.1 Install"

# Must be in rescue
if [ ! -f /etc/hetzner-rescue ]; then
    # Alternative check
    if ! grep -qi "rescue" /etc/motd 2>/dev/null && ! hostname | grep -qi "rescue"; then
        warn "This doesn't look like Hetzner Rescue. Proceeding anyway..."
    fi
fi

# Detect drives
log "Detecting drives..."
NVME_DRIVES=($(ls /dev/nvme*n1 2>/dev/null || true))
SATA_DRIVES=($(ls /dev/sd[a-z] 2>/dev/null | head -2 || true))

if [ ${#NVME_DRIVES[@]} -ge 2 ]; then
    DRIVE1="${NVME_DRIVES[0]}"
    DRIVE2="${NVME_DRIVES[1]}"
    log "Found NVMe: $DRIVE1, $DRIVE2"
elif [ ${#SATA_DRIVES[@]} -ge 2 ]; then
    DRIVE1="${SATA_DRIVES[0]}"
    DRIVE2="${SATA_DRIVES[1]}"
    log "Found SATA: $DRIVE1, $DRIVE2"
else
    err "Need at least 2 drives for RAID1. Found: $(ls /dev/nvme*n1 /dev/sd[a-z] 2>/dev/null)"
    exit 1
fi

# Detect drive size
DRIVE_SIZE_GB=$(lsblk -b -d -n -o SIZE "$DRIVE1" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}')
log "Drive size: ${DRIVE_SIZE_GB} GB each"

# Find Proxmox image
log "Looking for Proxmox VE image..."
PVE_IMAGE=""
for dir in /root/.oldroot/nfs/images /root/images; do
    if [ -d "$dir" ]; then
        PVE_IMAGE=$(ls "$dir"/Proxmox-VE-*.tar* 2>/dev/null | sort -V | tail -1)
        [ -n "$PVE_IMAGE" ] && break
    fi
done

if [ -z "$PVE_IMAGE" ]; then
    err "Proxmox VE image not found!"
    echo "Available images:"
    ls /root/.oldroot/nfs/images/ 2>/dev/null | grep -i prox || echo "  (none in /root/.oldroot/nfs/images/)"
    ls /root/images/ 2>/dev/null | grep -i prox || echo "  (none in /root/images/)"
    echo ""
    echo "Try: installimage  (interactive, select Proxmox manually)"
    exit 1
fi

log "Image: $PVE_IMAGE"

# Network info
IP_ADDR=$(ip -4 addr show | grep 'inet ' | grep -v '127.0.0' | awk '{print $2}' | head -1)
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
log "IP: $IP_ADDR, Gateway: $GATEWAY"

###############################################################################
# SSH KEY
###############################################################################
header "SSH Key Setup"

SSH_PUBKEY=""
echo ""
echo "Paste your SSH public key (from Mac: cat ~/.ssh/id_ed25519.pub)"
echo "Or press Enter to skip (you'll use password login):"
read -r SSH_PUBKEY_INPUT

if [ -n "$SSH_PUBKEY_INPUT" ]; then
    SSH_PUBKEY="$SSH_PUBKEY_INPUT"
    log "SSH key will be added"
else
    warn "No SSH key — you'll login with password only"
fi

###############################################################################
# CONFIRM
###############################################################################
echo ""
echo -e "${YELLOW}Installation plan:${NC}"
echo "  Server:    pve1.grupafestiwale.pl"
echo "  Drives:    $DRIVE1 + $DRIVE2 (${DRIVE_SIZE_GB} GB each)"
echo "  RAID:      mdraid1 (mirror) for root OS"
echo "  Root:      100 GB ext4 (Proxmox OS)"
echo "  Swap:      16 GB"
echo "  ZFS pool:  Rest of disk (~$((DRIVE_SIZE_GB - 120)) GB mirror) for VMs/CTs"
echo "  Image:     $(basename "$PVE_IMAGE")"
echo ""
echo -e "${RED}WARNING: ALL DATA ON BOTH DRIVES WILL BE DESTROYED!${NC}"
echo ""
read -p "Type YES to proceed: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    log "Aborted."
    exit 0
fi

###############################################################################
# INSTALLIMAGE CONFIG
###############################################################################
header "Step 1/4: Creating installimage config"

cat > /tmp/proxmox.conf << CONF
## Hetzner installimage config
## Grupa Festiwale — pve1.grupafestiwale.pl

DRIVE1 ${DRIVE1}
DRIVE2 ${DRIVE2}

## Software RAID 1 (mirror) for root OS
SWRAID 1
SWRAIDLEVEL 1

## Hostname
HOSTNAME pve1.grupafestiwale.pl

## Partitions
## Boot + Root on mdraid, rest left for ZFS (created post-install)
PART /boot  ext4  1024M
PART lvm    vg0   100G
PART swap   swap  16G
## Leave remaining space unpartitioned → ZFS pool post-install

LV vg0 root / ext4 100G

## Proxmox image
IMAGE ${PVE_IMAGE}
CONF

log "Config written to /tmp/proxmox.conf"
cat /tmp/proxmox.conf

###############################################################################
# RUN INSTALLIMAGE
###############################################################################
header "Step 2/4: Running installimage"

log "Installing Proxmox VE (this takes 5-10 minutes)..."
installimage -a -c /tmp/proxmox.conf 2>&1 | tee /tmp/installimage.log

if [ $? -ne 0 ]; then
    err "installimage failed! Check /tmp/installimage.log"
    tail -20 /tmp/installimage.log
    exit 1
fi

log "installimage completed!"

###############################################################################
# POST-INSTALL CONFIGURATION
###############################################################################
header "Step 3/4: Post-install configuration"

# Mount installed system
INSTALLED_ROOT="/mnt"
if ! mountpoint -q "$INSTALLED_ROOT"; then
    mount /dev/vg0/root "$INSTALLED_ROOT" 2>/dev/null || mount /dev/md1 "$INSTALLED_ROOT" 2>/dev/null || true
fi

# Add SSH key
if [ -n "$SSH_PUBKEY" ]; then
    mkdir -p "${INSTALLED_ROOT}/root/.ssh"
    echo "$SSH_PUBKEY" >> "${INSTALLED_ROOT}/root/.ssh/authorized_keys"
    chmod 700 "${INSTALLED_ROOT}/root/.ssh"
    chmod 600 "${INSTALLED_ROOT}/root/.ssh/authorized_keys"
    log "SSH key added"
fi

# Create post-boot script (runs on first boot to create ZFS pool)
cat > "${INSTALLED_ROOT}/root/first-boot-setup.sh" << 'FIRSTBOOT'
#!/bin/bash
###############################################################################
# First boot setup — creates ZFS data pool from unpartitioned space
###############################################################################
set -euo pipefail

LOG="/var/log/first-boot-setup.log"
exec > >(tee -a "$LOG") 2>&1

echo "[$(date)] Starting first-boot setup..."

# Find unpartitioned space on NVMe drives
# installimage used part of each drive, rest is free
DRIVE1=$(lsblk -d -n -o NAME,TYPE | grep disk | awk '{print "/dev/"$1}' | head -1)
DRIVE2=$(lsblk -d -n -o NAME,TYPE | grep disk | awk '{print "/dev/"$1}' | tail -1)

echo "Drives: $DRIVE1, $DRIVE2"

# Create partition on remaining space (partition 4, after boot/lvm/swap)
for DRIVE in "$DRIVE1" "$DRIVE2"; do
    # Find the last partition number
    LAST_PART=$(lsblk -n -o NAME "$DRIVE" | grep -c "part" || echo 0)
    NEXT_PART=$((LAST_PART + 1))

    # Check if ZFS partition already exists
    if zpool list rpool &>/dev/null 2>&1; then
        echo "ZFS pool rpool already exists — skipping"
        break
    fi

    # Create partition using remaining space
    echo "Creating ZFS partition on ${DRIVE} (partition ${NEXT_PART})..."
    sgdisk -n "${NEXT_PART}:0:0" -t "${NEXT_PART}:bf00" "$DRIVE"
done

# Reload partition table
partprobe "$DRIVE1" "$DRIVE2" 2>/dev/null
sleep 2

# Find the new ZFS partitions
ZFS_PART1=$(lsblk -n -o NAME,PARTTYPE "$DRIVE1" 2>/dev/null | grep "6a898cc3" | awk '{print "/dev/"$1}' | head -1)
ZFS_PART2=$(lsblk -n -o NAME,PARTTYPE "$DRIVE2" 2>/dev/null | grep "6a898cc3" | awk '{print "/dev/"$1}' | head -1)

# Fallback: find by partition number
if [ -z "$ZFS_PART1" ]; then
    ZFS_PART1=$(ls "${DRIVE1}"*4 2>/dev/null | head -1 || ls "${DRIVE1}p4" 2>/dev/null | head -1)
    ZFS_PART2=$(ls "${DRIVE2}"*4 2>/dev/null | head -1 || ls "${DRIVE2}p4" 2>/dev/null | head -1)
fi

if [ -z "$ZFS_PART1" ] || [ -z "$ZFS_PART2" ]; then
    echo "ERROR: Could not find ZFS partitions. Manual setup needed."
    echo "Create ZFS pool manually:"
    echo "  zpool create -f -o ashift=12 rpool mirror /dev/nvmeXnYpZ /dev/nvmeXnYpZ"
    exit 1
fi

echo "ZFS partitions: $ZFS_PART1, $ZFS_PART2"

# Create ZFS mirror pool
if ! zpool list rpool &>/dev/null 2>&1; then
    echo "Creating ZFS mirror pool 'rpool'..."
    zpool create -f \
        -o ashift=12 \
        -O acltype=posixacl \
        -O compression=lz4 \
        -O dnodesize=auto \
        -O normalization=formD \
        -O relatime=on \
        -O xattr=sa \
        -O mountpoint=none \
        rpool mirror "$ZFS_PART1" "$ZFS_PART2"

    echo "Creating ZFS datasets..."
    zfs create -o mountpoint=none rpool/data
    zfs create -o mountpoint=none rpool/data/db
    zfs create -o mountpoint=none rpool/data/files

    # PostgreSQL-optimized settings
    zfs set recordsize=8K rpool/data/db
    zfs set primarycache=metadata rpool/data/db
    zfs set logbias=latency rpool/data/db

    # File storage settings
    zfs set recordsize=1M rpool/data/files

    echo "ZFS pool 'rpool' created successfully!"
    zpool status rpool
    zpool list rpool
fi

# Add ZFS pool as Proxmox storage
if ! pvesm status | grep -q "local-zfs"; then
    pvesm add zfspool local-zfs -pool rpool/data
    echo "Added 'local-zfs' storage to Proxmox"
fi

# Remove no-subscription nag
if [ -f /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js ]; then
    sed -Ei.bak "s/Ext\.Msg\.show\(\{[^}]+title:\s*gettext\('No valid sub/void({/" \
        /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js 2>/dev/null || true
fi

# Configure repos for PVE 9 (Trixie)
rm -f /etc/apt/sources.list.d/pve-enterprise.list
rm -f /etc/apt/sources.list.d/ceph-enterprise.list

cat > /etc/apt/sources.list.d/pve-no-subscription.list << 'EOF'
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF

# Update
apt-get update -qq
apt-get dist-upgrade -y -qq

# Install essentials
apt-get install -y -qq git ansible python3-jmespath python3-netaddr curl jq

echo ""
echo "[$(date)] First-boot setup complete!"
echo ""
echo "Next: run the Grupa Festiwale infrastructure deployment:"
echo "  git clone https://github.com/grupafestiwale/infra.git /opt/grupafestiwale-infra"
echo "  bash /opt/grupafestiwale-infra/scripts/setup-proxmox.sh"

# Self-delete
rm -f /root/first-boot-setup.sh
FIRSTBOOT

chmod +x "${INSTALLED_ROOT}/root/first-boot-setup.sh"
log "First-boot script created"

# Create systemd service for first-boot
cat > "${INSTALLED_ROOT}/etc/systemd/system/first-boot-setup.service" << 'SYSTEMD'
[Unit]
Description=Grupa Festiwale First Boot Setup (ZFS pool + repos)
After=network-online.target zfs.target
Wants=network-online.target
ConditionPathExists=/root/first-boot-setup.sh

[Service]
Type=oneshot
ExecStart=/root/first-boot-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD

# Enable service
chroot "$INSTALLED_ROOT" systemctl enable first-boot-setup.service 2>/dev/null || \
    ln -sf /etc/systemd/system/first-boot-setup.service \
    "${INSTALLED_ROOT}/etc/systemd/system/multi-user.target.wants/first-boot-setup.service"

log "First-boot systemd service enabled"

# Ensure network config is correct
cat > "${INSTALLED_ROOT}/etc/network/interfaces" << NETWORK
auto lo
iface lo inet loopback

auto eno1
iface eno1 inet manual

auto vmbr0
iface vmbr0 inet static
    address 136.243.41.254/26
    gateway 136.243.41.193
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
NETWORK

log "Network configured (136.243.41.254/26, gw 136.243.41.193)"

# Fix interface name — detect real interface
REAL_IFACE=$(ls "${INSTALLED_ROOT}/sys/class/net/" 2>/dev/null | grep -v lo | grep -v vmbr | head -1 || echo "")
if [ -z "$REAL_IFACE" ]; then
    # Try from rescue system
    REAL_IFACE=$(ip -o link show | grep -v lo | grep -v vmbr | awk -F: '{print $2}' | tr -d ' ' | head -1)
fi

if [ -n "$REAL_IFACE" ] && [ "$REAL_IFACE" != "eno1" ]; then
    sed -i "s/eno1/${REAL_IFACE}/g" "${INSTALLED_ROOT}/etc/network/interfaces"
    log "Interface name: $REAL_IFACE (updated from eno1)"
fi

###############################################################################
# REBOOT
###############################################################################
header "Step 4/4: Installation Complete!"

echo ""
echo -e "${GREEN}Proxmox VE installed successfully!${NC}"
echo ""
echo "After reboot:"
echo "  1. SSH:  ssh root@136.243.41.254"
echo "  2. Web:  https://136.243.41.254:8006"
echo "  3. First-boot script will auto-create ZFS pool + install Ansible"
echo "  4. Then run:"
echo "     git clone https://github.com/grupafestiwale/infra.git /opt/grupafestiwale-infra"
echo "     bash /opt/grupafestiwale-infra/scripts/setup-proxmox.sh"
echo ""
read -p "Reboot now? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    log "Rebooting in 5 seconds..."
    sleep 5
    reboot
fi
