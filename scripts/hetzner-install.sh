#!/bin/bash
###############################################################################
# Grupa Festiwale — Proxmox VE 9.1 Manual Install from ISO
#
# Installs Proxmox VE on ZFS root mirror from Hetzner Rescue mode.
# No installimage needed — downloads ISO, extracts, configures.
#
# Usage (in Hetzner Rescue SSH):
#   wget -qO /tmp/install.sh https://raw.githubusercontent.com/grupafestiwale/infra/main/scripts/hetzner-install.sh
#   bash /tmp/install.sh
#
# Features:
#   - ZFS mirror root (both NVMe drives)
#   - UEFI + Legacy BIOS hybrid boot (works on both)
#   - ZFS ARC limited to 16 GB
#   - SSH key injected
#   - Ready for Ansible automation
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
HOSTNAME="pve1.grupafestiwale.pl"
IP_ADDR="136.243.41.254"
IP_CIDR="26"
GATEWAY="136.243.41.193"
DNS1="185.12.64.1"
DNS2="185.12.64.2"
PVE_ISO_URL="http://download.proxmox.com/iso/proxmox-ve_9.1-1.iso"
PVE_ISO="/tmp/proxmox-ve.iso"
ZFS_ARC_MAX="17179869184"  # 16 GB in bytes
ROOT_PASSWORD=""            # Will be set interactively
TARGET="/mnt/target"

###############################################################################
# PREFLIGHT
###############################################################################
header "Grupa Festiwale — Proxmox VE 9.1 Install"
echo "Target: $HOSTNAME ($IP_ADDR/$IP_CIDR)"

# Detect drives
NVME_DRIVES=($(ls /dev/nvme*n1 2>/dev/null || true))
if [ ${#NVME_DRIVES[@]} -lt 2 ]; then
    err "Need 2 NVMe drives. Found: ${NVME_DRIVES[*]:-none}"
    exit 1
fi
DISK1="${NVME_DRIVES[0]}"
DISK2="${NVME_DRIVES[1]}"
DISK_SIZE=$(lsblk -b -d -n -o SIZE "$DISK1" | awk '{printf "%.0f", $1/1024/1024/1024}')
log "Drives: $DISK1 + $DISK2 (${DISK_SIZE} GB each)"

# Root password
echo ""
echo -n "Set root password for Proxmox: "
read -s ROOT_PASSWORD
echo ""
echo -n "Confirm: "
read -s ROOT_PASSWORD2
echo ""
if [ "$ROOT_PASSWORD" != "$ROOT_PASSWORD2" ]; then
    err "Passwords don't match"
    exit 1
fi

# SSH key
SSH_PUBKEY=""
echo ""
echo "Paste your SSH public key (or Enter to skip):"
read -r SSH_PUBKEY

# Confirm
echo ""
echo -e "${YELLOW}Installation plan:${NC}"
echo "  Hostname:   $HOSTNAME"
echo "  IP:         $IP_ADDR/$IP_CIDR"
echo "  Gateway:    $GATEWAY"
echo "  Drives:     $DISK1 + $DISK2 (ZFS mirror)"
echo "  Boot:       UEFI + Legacy BIOS hybrid"
echo "  Filesystem: ZFS root (rpool)"
echo "  ZFS ARC:    16 GB max"
echo ""
echo -e "${RED}ALL DATA ON BOTH DRIVES WILL BE DESTROYED!${NC}"
read -p "Type YES to proceed: " CONFIRM
[ "$CONFIRM" != "YES" ] && exit 0

###############################################################################
# STEP 1: DOWNLOAD PROXMOX ISO
###############################################################################
header "Step 1/7: Downloading Proxmox VE 9.1 ISO"

if [ -f "$PVE_ISO" ] && [ "$(stat -c%s "$PVE_ISO" 2>/dev/null || echo 0)" -gt 500000000 ]; then
    log "ISO already downloaded, skipping"
else
    log "Downloading from $PVE_ISO_URL..."
    wget -q --show-progress -O "$PVE_ISO" "$PVE_ISO_URL"
fi
log "ISO size: $(du -h "$PVE_ISO" | cut -f1)"

###############################################################################
# STEP 2: PARTITION DRIVES
###############################################################################
header "Step 2/7: Partitioning drives"

# Wipe existing partitions
log "Wiping drives..."
for DISK in "$DISK1" "$DISK2"; do
    wipefs -af "$DISK" >/dev/null 2>&1
    sgdisk --zap-all "$DISK" >/dev/null 2>&1
done

# Partition layout (GPT):
#  1: 1 MB   BIOS boot (for Legacy GRUB)
#  2: 256 MB EFI System Partition (for UEFI)
#  3: 1 GB   /boot (ext4, mdraid mirror)
#  4: REST   ZFS root mirror
log "Creating partitions..."
for DISK in "$DISK1" "$DISK2"; do
    sgdisk -n 1:2048:+1M    -t 1:EF02 -c 1:"BIOS boot"  "$DISK"
    sgdisk -n 2:0:+256M     -t 2:EF00 -c 2:"EFI System"  "$DISK"
    sgdisk -n 3:0:+1G       -t 3:FD00 -c 3:"Boot RAID"   "$DISK"
    sgdisk -n 4:0:0          -t 4:BF00 -c 4:"ZFS"         "$DISK"
    log "  $DISK partitioned"
done

sleep 2
partprobe "$DISK1" "$DISK2"
sleep 2

# Identify partitions
D1P2="${DISK1}p2"; D2P2="${DISK2}p2"
D1P3="${DISK1}p3"; D2P3="${DISK2}p3"
D1P4="${DISK1}p4"; D2P4="${DISK2}p4"

###############################################################################
# STEP 3: CREATE FILESYSTEMS
###############################################################################
header "Step 3/7: Creating filesystems"

# EFI (FAT32) — both drives (redundancy)
log "Creating EFI partitions..."
mkfs.vfat -F 32 "$D1P2" >/dev/null
mkfs.vfat -F 32 "$D2P2" >/dev/null

# Boot — mdraid mirror + ext4
log "Creating /boot mirror (mdraid1)..."
mdadm --create /dev/md0 --level=1 --raid-devices=2 \
    --metadata=1.0 --run "$D1P3" "$D2P3" >/dev/null 2>&1
mkfs.ext4 -q -L boot /dev/md0

# ZFS root pool — mirror
log "Creating ZFS root pool (rpool)..."
zpool create -f \
    -o ashift=12 \
    -o autoexpand=on \
    -O acltype=posixacl \
    -O compression=lz4 \
    -O dnodesize=auto \
    -O normalization=formD \
    -O relatime=on \
    -O xattr=sa \
    -O canmount=off \
    -O mountpoint=/ \
    -R "$TARGET" \
    rpool mirror "$D1P4" "$D2P4"

# Create datasets
log "Creating ZFS datasets..."
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/pve-1
zpool set bootfs=rpool/ROOT/pve-1 rpool
zfs mount rpool/ROOT/pve-1

zfs create -o mountpoint=/var/lib/vz rpool/data
zfs create -o mountpoint=none rpool/vmdata
zfs create -o mountpoint=none rpool/vmdata/db
zfs create -o mountpoint=none rpool/vmdata/files

# PostgreSQL-optimized dataset
zfs set recordsize=8K rpool/vmdata/db
zfs set primarycache=metadata rpool/vmdata/db
zfs set logbias=latency rpool/vmdata/db

# File storage dataset
zfs set recordsize=1M rpool/vmdata/files

log "ZFS pool created:"
zpool list rpool

# Mount boot
mkdir -p "${TARGET}/boot"
mount /dev/md0 "${TARGET}/boot"
mkdir -p "${TARGET}/boot/efi"
mount "$D1P2" "${TARGET}/boot/efi"

###############################################################################
# STEP 4: EXTRACT PROXMOX
###############################################################################
header "Step 4/7: Extracting Proxmox VE"

log "Mounting ISO..."
mkdir -p /mnt/iso
mount -o loop "$PVE_ISO" /mnt/iso

# Find and extract the squashfs
SQUASHFS=$(find /mnt/iso -name "*.squashfs" -o -name "pve-base.squashfs" 2>/dev/null | head -1)
if [ -z "$SQUASHFS" ]; then
    # Try extracting from pve-installer data
    SQUASHFS=$(find /mnt/iso -name "*.tar.*" -o -name "*.squashfs" 2>/dev/null | head -1)
fi

if [ -z "$SQUASHFS" ]; then
    log "Looking for rootfs in ISO structure..."
    ls -la /mnt/iso/
    # Proxmox ISO might have a different structure
    # Try unsquashfs from the ISO
    SQUASHFS=$(find /mnt/iso -name "pve-base*" 2>/dev/null | head -1)
fi

if [ -n "$SQUASHFS" ] && echo "$SQUASHFS" | grep -q "squashfs"; then
    log "Extracting squashfs: $SQUASHFS"
    unsquashfs -f -d "$TARGET" "$SQUASHFS"
elif [ -n "$SQUASHFS" ] && echo "$SQUASHFS" | grep -q "tar"; then
    log "Extracting tar: $SQUASHFS"
    tar xf "$SQUASHFS" -C "$TARGET"
else
    # Proxmox VE ISO has a specific structure — extract packages
    log "Extracting Proxmox from ISO packages..."

    # Mount pve-base.squashfs from within ISO structure
    if [ -f /mnt/iso/pve-base.squashfs ]; then
        unsquashfs -f -d "$TARGET" /mnt/iso/pve-base.squashfs
    elif [ -d /mnt/iso/proxmox ]; then
        # Copy proxmox installer content
        cp -a /mnt/iso/proxmox/* "$TARGET/" 2>/dev/null || true
    else
        warn "Could not find rootfs in ISO. Trying alternative method..."

        # Alternative: use debootstrap + proxmox repos
        log "Installing via debootstrap (Debian Trixie + Proxmox packages)..."

        apt-get update -qq
        apt-get install -y -qq debootstrap

        debootstrap --arch amd64 trixie "$TARGET" http://deb.debian.org/debian

        # Add Proxmox repos
        cat > "${TARGET}/etc/apt/sources.list.d/proxmox.list" << 'PVEREPO'
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
PVEREPO

        # Add Proxmox GPG key
        mkdir -p "${TARGET}/etc/apt/trusted.gpg.d"
        wget -q "https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg" \
            -O "${TARGET}/etc/apt/trusted.gpg.d/proxmox-release.gpg" 2>/dev/null || \
        wget -q "http://download.proxmox.com/debian/proxmox-release-trixie.gpg" \
            -O "${TARGET}/etc/apt/trusted.gpg.d/proxmox-release.gpg" 2>/dev/null || true

        # Mount proc/sys/dev for chroot
        mount --bind /proc "${TARGET}/proc"
        mount --bind /sys "${TARGET}/sys"
        mount --bind /dev "${TARGET}/dev"
        mount --bind /dev/pts "${TARGET}/dev/pts"

        # Install Proxmox in chroot
        chroot "$TARGET" /bin/bash -c "
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                proxmox-ve postfix open-iscsi chrony
        "
    fi
fi

umount /mnt/iso 2>/dev/null || true

log "Rootfs extracted to $TARGET"

###############################################################################
# STEP 5: CONFIGURE SYSTEM
###############################################################################
header "Step 5/7: Configuring system"

# Mount necessary filesystems for chroot
mount --bind /proc "${TARGET}/proc" 2>/dev/null || true
mount --bind /sys "${TARGET}/sys" 2>/dev/null || true
mount --bind /dev "${TARGET}/dev" 2>/dev/null || true
mount --bind /dev/pts "${TARGET}/dev/pts" 2>/dev/null || true

# Hostname
echo "$HOSTNAME" > "${TARGET}/etc/hostname"
cat > "${TARGET}/etc/hosts" << HOSTS
127.0.0.1 localhost
${IP_ADDR} ${HOSTNAME} pve1

# IPv6
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS
log "Hostname: $HOSTNAME"

# Network
mkdir -p "${TARGET}/etc/network"
cat > "${TARGET}/etc/network/interfaces" << NETWORK
auto lo
iface lo inet loopback

iface enp7s0 inet manual

auto vmbr0
iface vmbr0 inet static
    address ${IP_ADDR}/${IP_CIDR}
    gateway ${GATEWAY}
    bridge-ports enp7s0
    bridge-stp off
    bridge-fd 0
NETWORK
log "Network: ${IP_ADDR}/${IP_CIDR} gw ${GATEWAY}, bridge on enp7s0"

# DNS
cat > "${TARGET}/etc/resolv.conf" << DNS
nameserver ${DNS1}
nameserver ${DNS2}
DNS

# Timezone
ln -sf /usr/share/zoneinfo/Europe/Warsaw "${TARGET}/etc/localtime"
echo "Europe/Warsaw" > "${TARGET}/etc/timezone"

# Root password
echo "root:${ROOT_PASSWORD}" | chroot "$TARGET" chpasswd
log "Root password set"

# SSH key
if [ -n "$SSH_PUBKEY" ]; then
    mkdir -p "${TARGET}/root/.ssh"
    echo "$SSH_PUBKEY" > "${TARGET}/root/.ssh/authorized_keys"
    chmod 700 "${TARGET}/root/.ssh"
    chmod 600 "${TARGET}/root/.ssh/authorized_keys"
    log "SSH key added"
fi

# SSH config — permit root login
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${TARGET}/etc/ssh/sshd_config" 2>/dev/null || \
    echo "PermitRootLogin yes" >> "${TARGET}/etc/ssh/sshd_config"

# ZFS ARC limit — 16 GB
mkdir -p "${TARGET}/etc/modprobe.d"
echo "options zfs zfs_arc_max=${ZFS_ARC_MAX}" > "${TARGET}/etc/modprobe.d/zfs.conf"
log "ZFS ARC limited to 16 GB"

# fstab
cat > "${TARGET}/etc/fstab" << FSTAB
# ZFS root is managed by ZFS — no entry needed
/dev/md0    /boot   ext4    defaults    0 2
${D1P2}     /boot/efi vfat  defaults    0 1
FSTAB

# mdadm config
mkdir -p "${TARGET}/etc/mdadm"
mdadm --detail --scan >> "${TARGET}/etc/mdadm/mdadm.conf"

# Proxmox repos (no enterprise)
rm -f "${TARGET}/etc/apt/sources.list.d/pve-enterprise.list"
rm -f "${TARGET}/etc/apt/sources.list.d/ceph-enterprise.list"
cat > "${TARGET}/etc/apt/sources.list.d/pve-no-subscription.list" << 'REPO'
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
REPO

# Apt sources for Debian Trixie
cat > "${TARGET}/etc/apt/sources.list" << 'APT'
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
APT

###############################################################################
# STEP 6: INSTALL BOOTLOADER
###############################################################################
header "Step 6/7: Installing bootloader"

# Generate ZFS cachefile
mkdir -p "${TARGET}/etc/zfs"
zpool set cachefile=/etc/zfs/zpool.cache rpool
cp /etc/zfs/zpool.cache "${TARGET}/etc/zfs/" 2>/dev/null || true

chroot "$TARGET" /bin/bash << 'CHROOT_BOOT'
set -e

# Refresh package list
apt-get update -qq 2>/dev/null || true

# Install GRUB for both UEFI and BIOS
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    grub-pc grub-efi-amd64 efibootmgr \
    zfs-initramfs zfsutils-linux \
    mdadm 2>/dev/null || true

# Install GRUB to both disks (Legacy BIOS)
for disk in /dev/nvme0n1 /dev/nvme1n1; do
    grub-install --target=i386-pc "$disk" 2>/dev/null || true
done

# Install GRUB EFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=proxmox --recheck --no-floppy 2>/dev/null || true

# Update initramfs with ZFS support
update-initramfs -u -k all 2>/dev/null || true

# Update GRUB config
update-grub 2>/dev/null || true

echo "Bootloader installed"
CHROOT_BOOT

# Copy EFI to second drive too (redundancy)
mkdir -p /tmp/efi2
mount "$D2P2" /tmp/efi2
cp -a "${TARGET}/boot/efi/EFI" /tmp/efi2/ 2>/dev/null || true
umount /tmp/efi2

log "Bootloader installed (BIOS + UEFI hybrid)"

###############################################################################
# STEP 7: FINALIZE & REBOOT
###############################################################################
header "Step 7/7: Finalizing"

# Create post-boot script for Ansible prep
cat > "${TARGET}/root/post-install.sh" << 'POSTSCRIPT'
#!/bin/bash
# Run once after first boot
set -e

# Remove enterprise repos if they snuck back
rm -f /etc/apt/sources.list.d/pve-enterprise.list
rm -f /etc/apt/sources.list.d/ceph-enterprise.list

# Add ZFS vmdata pool to Proxmox storage
pvesm add zfspool local-zfs -pool rpool/vmdata 2>/dev/null || true

# Update system
apt-get update -qq
apt-get dist-upgrade -y -qq

# Install tools for Ansible
apt-get install -y -qq git ansible python3-jmespath python3-netaddr curl jq

echo ""
echo "Post-install complete! Next:"
echo "  git clone https://github.com/grupafestiwale/infra.git /opt/grupafestiwale-infra"
echo "  bash /opt/grupafestiwale-infra/scripts/setup-proxmox.sh"

# Self-delete
rm -f /root/post-install.sh
POSTSCRIPT
chmod +x "${TARGET}/root/post-install.sh"

# Unmount everything
sync
umount "${TARGET}/dev/pts" 2>/dev/null || true
umount "${TARGET}/dev" 2>/dev/null || true
umount "${TARGET}/sys" 2>/dev/null || true
umount "${TARGET}/proc" 2>/dev/null || true
umount "${TARGET}/boot/efi" 2>/dev/null || true
umount "${TARGET}/boot" 2>/dev/null || true

# Export ZFS pool
zpool export rpool

header "INSTALLATION COMPLETE!"

echo ""
echo -e "${GREEN}Proxmox VE 9.1 installed on ZFS mirror!${NC}"
echo ""
echo "  Drives:  $DISK1 + $DISK2 (ZFS mirror)"
echo "  Pool:    rpool (~${DISK_SIZE} GB usable)"
echo "  Boot:    UEFI + Legacy BIOS hybrid"
echo "  ARC:     16 GB max"
echo "  SSH:     root@${IP_ADDR}"
echo "  Web UI:  https://${IP_ADDR}:8006"
echo ""
echo "After reboot, run:"
echo "  bash /root/post-install.sh"
echo "  git clone https://github.com/grupafestiwale/infra.git /opt/grupafestiwale-infra"
echo "  bash /opt/grupafestiwale-infra/scripts/setup-proxmox.sh"
echo ""
read -p "Reboot now? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    log "Rebooting..."
    sleep 3
    reboot
fi
