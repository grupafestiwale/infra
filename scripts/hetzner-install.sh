#!/bin/bash
###############################################################################
# Grupa Festiwale — Proxmox VE 9 via Hetzner installimage
#
# Uses Hetzner's native installimage to install Debian Trixie base,
# then post-install script adds Proxmox VE 9 + ZFS data pool.
#
# Usage (in Hetzner Rescue SSH):
#   wget -qO /tmp/install.sh https://raw.githubusercontent.com/grupafestiwale/infra/main/scripts/hetzner-install.sh
#   bash /tmp/install.sh
#
# Or paste directly into rescue SSH.
#
# Server: Hetzner AX102 (AMD Ryzen 9 5950X, 128GB RAM, 2x3.84TB NVMe)
# IP: 136.243.41.254/26, GW: 136.243.41.193
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
# CONFIG
###############################################################################
HOSTNAME="pve1"
FQDN="pve1.grupafestiwale.pl"
IP_ADDR="136.243.41.254"
IP_CIDR="26"
GATEWAY="136.243.41.193"
DRIVE1="/dev/nvme0n1"
DRIVE2="/dev/nvme1n1"
ZFS_ARC_MAX_GB=16
ZFS_ARC_MAX_BYTES=$((ZFS_ARC_MAX_GB * 1024 * 1024 * 1024))

# Partition sizes
BOOT_SIZE="1G"       # /boot (ext4, mdraid)
ROOT_SIZE="100G"     # / (ext4, mdraid) — OS + Proxmox
SWAP_SIZE="8G"       # swap (mdraid)
# Remaining ~3.6TB per drive → ZFS data pool (created in post-install)

###############################################################################
header "Grupa Festiwale — Proxmox VE 9 Installer"
###############################################################################

log "Server: $FQDN ($IP_ADDR/$IP_CIDR)"
log "Drives: $DRIVE1 + $DRIVE2 (RAID1)"
log "Layout: 100G root (mdraid) + ~3.5TB ZFS data pool"
log "ZFS ARC: ${ZFS_ARC_MAX_GB}GB"
echo ""

# Verify we're in rescue mode
if [[ ! -d /root/.oldroot/nfs/install ]]; then
    err "Not in Hetzner Rescue mode! Reboot into Rescue first."
    exit 1
fi

# Verify drives exist
for d in "$DRIVE1" "$DRIVE2"; do
    if [[ ! -b "$d" ]]; then
        err "Drive $d not found!"
        exit 1
    fi
done

log "Drives detected:"
lsblk -d -o NAME,SIZE,MODEL "$DRIVE1" "$DRIVE2" 2>/dev/null || true
echo ""

###############################################################################
header "Step 1: Creating installimage config"
###############################################################################

cat > /tmp/installimage.conf << 'INSTALLCONF'
## Grupa Festiwale — Hetzner installimage config
## Proxmox VE 9 on Debian Trixie

DRIVE1 /dev/nvme0n1
DRIVE2 /dev/nvme1n1

## Software RAID 1 (mirror)
SWRAID 1
SWRAIDLEVEL 1

## Partitions (mdraid) — keep small, ZFS gets the rest
PART /boot ext4 1G
PART /     ext4 100G
PART swap  swap 8G
## Remaining space left UNPARTITIONED for ZFS data pool

## Hostname
HOSTNAME pve1.grupafestiwale.pl

## Image — Debian Trixie base (Proxmox 9 added in post-install)
IMAGE /root/.oldroot/nfs/install/../images/Debian-trixie-latest-amd64-base.tar.gz
INSTALLCONF

log "Config written to /tmp/installimage.conf"
cat /tmp/installimage.conf
echo ""

###############################################################################
header "Step 2: Creating post-install script"
###############################################################################

cat > /tmp/post-install.sh << 'POSTINSTALL'
#!/bin/bash
###############################################################################
# Post-install: Debian Trixie → Proxmox VE 9 + ZFS data pool
###############################################################################
set -euo pipefail

LOG="/tmp/post-install.log"
exec > >(tee -a "$LOG") 2>&1

echo "[+] Post-install starting..."

INSTALLED_ROOT="/installimage/hdd"

# ─── 1. Add Proxmox VE 9 repository ───────────────────────────────────────
echo "[+] Adding Proxmox VE 9 repository..."

mkdir -p "$INSTALLED_ROOT/etc/apt/keyrings"
mkdir -p "$INSTALLED_ROOT/etc/apt/sources.list.d"

# Download Proxmox GPG key
wget -qO "$INSTALLED_ROOT/etc/apt/keyrings/proxmox-release-bookworm.gpg" \
    "http://download.proxmox.com/debian/proxmox-release-trixie.gpg" 2>/dev/null || \
wget -qO "$INSTALLED_ROOT/etc/apt/keyrings/proxmox-release-bookworm.gpg" \
    "http://download.proxmox.com/debian/proxmox-release-bookworm.gpg" 2>/dev/null || true

# Add Proxmox no-subscription repo
cat > "$INSTALLED_ROOT/etc/apt/sources.list.d/proxmox.sources" << 'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# ─── 2. Configure network ─────────────────────────────────────────────────
echo "[+] Configuring network for Proxmox (vmbr0)..."

cat > "$INSTALLED_ROOT/etc/network/interfaces" << 'EOF'
### Hetzner Online GmbH installance
### Grupa Festiwale — Proxmox VE 9

auto lo
iface lo inet loopback
iface lo inet6 loopback

# Physical interface (no IP — bridged)
auto eth0
iface eth0 inet manual

# Main bridge — public IP
auto vmbr0
iface vmbr0 inet static
    address 136.243.41.254/26
    gateway 136.243.41.193
    bridge-ports eth0
    bridge-stp off
    bridge-fd 0
    # VLAN awareness for LXC/VM networks
    bridge-vlan-aware yes
    bridge-vids 2-4094

    # Sysctl
    up sysctl -p || true

# VLAN bridges (created by Ansible later)
# vmbr10 = MGMT (10.10.10.0/24)
# vmbr20 = DMZ (10.10.20.0/24)
# vmbr30 = DATA (10.10.30.0/24)
# vmbr40 = APPS (10.10.40.0/24)
# vmbr50 = DEV (10.10.50.0/24)
# vmbr60 = VAULT (10.10.60.0/24)
EOF

# ─── 3. Hostname & Hosts ──────────────────────────────────────────────────
echo "[+] Setting hostname..."
echo "pve1" > "$INSTALLED_ROOT/etc/hostname"

cat > "$INSTALLED_ROOT/etc/hosts" << 'EOF'
127.0.0.1       localhost
136.243.41.254  pve1.grupafestiwale.pl pve1

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# ─── 4. Sysctl for IP forwarding & ZFS ARC ────────────────────────────────
echo "[+] Configuring sysctl (IP forwarding, ZFS ARC 16GB)..."

cat > "$INSTALLED_ROOT/etc/sysctl.d/99-proxmox.conf" << 'EOF'
# IP forwarding for VMs/LXC
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# ZFS ARC max 16GB (128GB total, rest for VMs)
vm.swappiness = 10
EOF

# ZFS ARC limit — also set via modprobe for early boot
mkdir -p "$INSTALLED_ROOT/etc/modprobe.d"
cat > "$INSTALLED_ROOT/etc/modprobe.d/zfs.conf" << 'EOF'
# Limit ZFS ARC to 16GB (17179869184 bytes)
# Server has 128GB RAM — 108GB reserved for VMs/LXC
options zfs zfs_arc_max=17179869184
EOF

# ─── 5. Prepare first-boot script (installs PVE + creates ZFS pool) ──────
echo "[+] Creating first-boot script..."

cat > "$INSTALLED_ROOT/root/first-boot.sh" << 'FIRSTBOOT'
#!/bin/bash
###############################################################################
# First boot: Install Proxmox VE 9 + Create ZFS data pool
# Run once after reboot: bash /root/first-boot.sh
###############################################################################
set -euo pipefail

LOG="/var/log/first-boot.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== Grupa Festiwale — First Boot Setup ==="
echo "Started: $(date)"

# ─── Install Proxmox VE ──────────────────────────────────────────────────
echo "[1/6] Updating packages and installing Proxmox VE..."
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get dist-upgrade -y

# Install Proxmox VE kernel first
apt-get install -y proxmox-default-kernel
# Remove standard kernel
apt-get remove -y linux-image-amd64 'linux-image-6.*' 2>/dev/null || true
update-grub

# Install Proxmox VE
apt-get install -y proxmox-ve postfix open-iscsi chrony

# Remove os-prober (not needed on server)
apt-get remove -y os-prober 2>/dev/null || true

echo "[2/6] Proxmox VE installed."

# ─── Remove subscription nag ─────────────────────────────────────────────
echo "[3/6] Removing subscription popup..."
PROXLIB="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [[ -f "$PROXLIB" ]]; then
    cp "$PROXLIB" "${PROXLIB}.bak"
    sed -i.bak "s/res === null || res === undefined || \!res || res.data.status.toLowerCase() !== 'active'/false/g" "$PROXLIB"
    systemctl restart pveproxy 2>/dev/null || true
fi

# ─── Create ZFS data pool ────────────────────────────────────────────────
echo "[4/6] Creating ZFS data pool on remaining NVMe space..."

# Load ZFS module
modprobe zfs 2>/dev/null || true

# Find unpartitioned space — create partition 4 on each drive
# (installimage uses partitions 1-3 for /boot, /, swap)
for disk in /dev/nvme0n1 /dev/nvme1n1; do
    echo "[+] Creating ZFS partition on $disk..."
    # Get the end of the last partition
    LAST_END=$(parted -s "$disk" unit s print | awk '/^ [0-9]/ {end=$3} END {print end}' | tr -d 's')
    DISK_END=$(parted -s "$disk" unit s print | grep "Disk ${disk}:" | awk '{print $3}' | tr -d 's')

    if [[ -n "$LAST_END" && -n "$DISK_END" ]]; then
        NEXT_START=$((LAST_END + 1))
        parted -s "$disk" mkpart primary "${NEXT_START}s" "100%" || true
    fi
done

# Wait for device nodes
sleep 2
partprobe 2>/dev/null || true
sleep 2

# Detect ZFS partition names (nvme0n1p4 / nvme1n1p4)
ZFS_PART1=""
ZFS_PART2=""
for p in /dev/nvme0n1p4 /dev/nvme0n1p5; do
    [[ -b "$p" ]] && ZFS_PART1="$p" && break
done
for p in /dev/nvme1n1p4 /dev/nvme1n1p5; do
    [[ -b "$p" ]] && ZFS_PART2="$p" && break
done

if [[ -n "$ZFS_PART1" && -n "$ZFS_PART2" ]]; then
    echo "[+] Creating ZFS mirror: $ZFS_PART1 + $ZFS_PART2"
    zpool create -f \
        -o ashift=12 \
        -o autotrim=on \
        -O compression=lz4 \
        -O atime=off \
        -O xattr=sa \
        -O dnodesize=auto \
        -O relatime=on \
        rpool mirror "$ZFS_PART1" "$ZFS_PART2"

    # Create datasets
    zfs create rpool/data
    zfs create rpool/data/vm-disks
    zfs create rpool/data/ct-volumes
    zfs create rpool/data/backups
    zfs create rpool/data/iso
    zfs create rpool/data/templates

    # Add to Proxmox storage
    pvesm add zfspool local-zfs -pool rpool/data/vm-disks -content images,rootdir -sparse 1
    pvesm add dir local-backup -path /rpool/data/backups -content backup -shared 0 2>/dev/null || true

    echo "[+] ZFS pool created:"
    zpool status rpool
    zfs list -r rpool
else
    echo "[!] WARNING: Could not find ZFS partitions. Create pool manually."
    echo "    Expected: /dev/nvme0n1p4 + /dev/nvme1n1p4"
fi

# ─── Apply ZFS ARC limit ─────────────────────────────────────────────────
echo "[5/6] Setting ZFS ARC max to 16GB..."
echo 17179869184 > /proc/sys/kernel/spl/hostid 2>/dev/null || true
echo 17179869184 > /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || true

# ─── Prepare for Ansible ─────────────────────────────────────────────────
echo "[6/6] Preparing for Ansible deployment..."

# Install Python (needed for Ansible)
apt-get install -y python3 python3-apt sudo curl wget git

# Ensure SSH is configured
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd 2>/dev/null || true

# Create scripts directory
mkdir -p /opt/scripts

echo ""
echo "=== FIRST BOOT COMPLETE ==="
echo ""
echo "Proxmox VE 9 is installed. Access web UI at:"
echo "  https://136.243.41.254:8006"
echo ""
echo "ZFS pool 'rpool' status:"
zpool status rpool 2>/dev/null || echo "(ZFS pool not yet created)"
echo ""
echo "Next steps:"
echo "  1. Reboot: reboot"
echo "  2. After reboot, access https://136.243.41.254:8006"
echo "  3. From your laptop, run the Ansible playbooks"
echo ""
echo "Finished: $(date)"
FIRSTBOOT

chmod +x "$INSTALLED_ROOT/root/first-boot.sh"

# ─── 6. Disable Hetzner's default enterprise repo if present ─────────────
rm -f "$INSTALLED_ROOT/etc/apt/sources.list.d/pve-enterprise.list" 2>/dev/null || true

echo "[+] Post-install complete!"
echo ""
echo "After reboot, run: bash /root/first-boot.sh"
echo "This will install Proxmox VE 9 and create the ZFS data pool."

POSTINSTALL

chmod +x /tmp/post-install.sh
log "Post-install script written to /tmp/post-install.sh"
echo ""

###############################################################################
header "Step 3: Running installimage"
###############################################################################

log "Config:       /tmp/installimage.conf"
log "Post-install: /tmp/post-install.sh"
echo ""
warn "This will WIPE both NVMe drives!"
warn "Drives: $DRIVE1 + $DRIVE2"
echo ""
read -rp "Continue? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    err "Aborted."
    exit 1
fi

log "Starting installimage..."
echo ""

installimage -a -c /tmp/installimage.conf -x /tmp/post-install.sh

RETVAL=$?

if [[ $RETVAL -eq 0 ]]; then
    echo ""
    header "Installation Complete!"
    echo ""
    log "Debian Trixie installed on RAID1 (mdraid)"
    log ""
    log "NEXT STEPS:"
    log "  1. Reboot:  reboot"
    log "  2. SSH in:  ssh root@136.243.41.254"
    log "  3. Run:     bash /root/first-boot.sh"
    log "     (installs Proxmox VE 9 + creates ZFS pool)"
    log "  4. Reboot again (new PVE kernel)"
    log "  5. Access:  https://136.243.41.254:8006"
    log "  6. From laptop: run Ansible playbooks"
    echo ""
else
    err "installimage failed with exit code $RETVAL"
    err "Check /tmp/installimage.log for details"
    exit 1
fi
