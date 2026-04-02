#!/bin/bash
###############################################################################
# Grupa Festiwale - Proxmox VE 9.1 Bootstrap Script
#
# Runs on a FRESH Proxmox VE 9.1+ installation (pve1.grupafestiwale.pl)
# Installs Ansible, clones the infrastructure repo, and deploys everything.
#
# Usage (on the Proxmox host):
#   curl -fsSL https://raw.githubusercontent.com/grupafestiwale/infra/main/scripts/setup-proxmox.sh | bash
#   # or
#   scp setup-proxmox.sh root@pve1.grupafestiwale.pl:
#   ssh root@pve1.grupafestiwale.pl bash setup-proxmox.sh
#
# Prerequisites:
#   - Fresh Proxmox VE 9.1+ install with root SSH access
#   - ZFS mirror already configured during install (2x 3.84TB NVMe)
#   - Hetzner public IP configured on eno1
#   - Internet access
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INFRA_DIR="/opt/grupafestiwale-infra"
REPO_URL="${REPO_URL:-https://github.com/grupafestiwale/infra.git}"
BRANCH="${BRANCH:-main}"

log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARNING:${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; }

header() {
    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
}

###############################################################################
# STEP 0: PREFLIGHT CHECKS
###############################################################################
header "GRUPA FESTIWALE - Proxmox VE 9.1 Bootstrap"

# Must be root
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root"
    exit 1
fi

# Must be Proxmox VE 9.x
if ! command -v pveversion &>/dev/null; then
    err "pveversion not found. Is this a Proxmox VE host?"
    exit 1
fi

PVE_VER=$(pveversion)
log "Detected: $PVE_VER"

if ! echo "$PVE_VER" | grep -q "pve-manager/9"; then
    err "Expected Proxmox VE 9.x. Got: $PVE_VER"
    err "This script targets PVE 9.1+ (Debian 13 Trixie)"
    exit 1
fi

# Check Debian version
DEBIAN_VER=$(cat /etc/debian_version 2>/dev/null || echo "unknown")
log "Debian version: $DEBIAN_VER"

# Check ZFS pool
if zpool list rpool &>/dev/null; then
    log "ZFS pool 'rpool' found:"
    zpool list rpool
else
    warn "ZFS pool 'rpool' not found. If you used a different pool name, set zfs_pool in group_vars/all.yml"
fi

# Check RAM
TOTAL_RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
log "Total RAM: ${TOTAL_RAM_GB} GB"
if [[ $TOTAL_RAM_GB -lt 100 ]]; then
    warn "Expected 128 GB RAM, found ${TOTAL_RAM_GB} GB. Containers may OOM."
fi

# Check CPU
CPU_THREADS=$(nproc)
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)
log "CPU: $CPU_MODEL ($CPU_THREADS threads)"

echo ""
echo -e "${YELLOW}This script will:${NC}"
echo "  1. Configure PVE 9.1 repos (no-subscription)"
echo "  2. Install Ansible + dependencies"
echo "  3. Clone infrastructure repo to $INFRA_DIR"
echo "  4. Prompt you for secrets (vault password)"
echo "  5. Run site.yml to deploy ALL 9 phases"
echo ""
echo -e "${YELLOW}Infrastructure deployed:${NC}"
echo "  LXC-00  VAULT     (OpenBao, VLAN 60)"
echo "  LXC-01  CORE      (Traefik + Cloudflared + Tailscale, VLAN 10+20)"
echo "  LXC-02  DB        (PostgreSQL 16 + DragonflyDB + PgBouncer, VLAN 30)"
echo "  LXC-03  DATA      (NextCloud + Paperless-NGX, VLAN 30)"
echo "  VM-04   AI PROD   (Dify + N8N + LobeChat + Ollama + LiteLLM, VLAN 40)"
echo "  VM-05   DEV       (Coding + Agentic + CRM stacks, VLAN 50)"
echo "  LXC-06  AUTH      (Authentik + Entra ID SSO, VLAN 10+20)"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Aborted."
    exit 0
fi

###############################################################################
# STEP 1: CONFIGURE PVE 9.1 REPOS
###############################################################################
header "Step 1/6: Configuring PVE 9.1 Repositories"

# Remove enterprise repos
rm -f /etc/apt/sources.list.d/pve-enterprise.list
rm -f /etc/apt/sources.list.d/ceph-enterprise.list
log "Removed enterprise repos"

# Add no-subscription repos
cat > /etc/apt/sources.list.d/pve-no-subscription.list << 'EOF'
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF

cat > /etc/apt/sources.list.d/ceph-no-subscription.list << 'EOF'
deb http://download.proxmox.com/debian/ceph-squid trixie no-subscription
EOF

log "Added PVE 9.1 no-subscription repos (Trixie)"

# Update
log "Running apt update..."
apt-get update -qq

# Remove nag dialog
if [ -f /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js ]; then
    if grep -q "No valid subscription" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; then
        sed -Ei.bak "s/Ext.Msg.show\(\{[^}]+No valid subscription[^}]+\}\);//g" \
            /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
        log "Removed subscription nag dialog"
    fi
fi

###############################################################################
# STEP 2: INSTALL ANSIBLE + DEPENDENCIES
###############################################################################
header "Step 2/6: Installing Ansible"

apt-get install -y -qq \
    ansible \
    git \
    python3-pip \
    python3-jmespath \
    python3-netaddr \
    sshpass \
    pwgen \
    jq \
    curl \
    wget \
    gnupg \
    lsb-release \
    ca-certificates

ANSIBLE_VER=$(ansible --version | head -1)
log "Installed: $ANSIBLE_VER"

###############################################################################
# STEP 3: LOCATE / CLONE INFRASTRUCTURE REPO
###############################################################################
header "Step 3/6: Setting Up Infrastructure Repo"

# Detect if script is running from inside the repo (scp scenario)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PARENT="$(dirname "$SCRIPT_DIR")"

if [ -f "${SCRIPT_PARENT}/site.yml" ] && [ -d "${SCRIPT_PARENT}/playbooks" ]; then
    # Script is inside the repo already (scp'd or local copy)
    if [ "$SCRIPT_PARENT" != "$INFRA_DIR" ]; then
        log "Repo detected at $SCRIPT_PARENT — linking to $INFRA_DIR"
        ln -sfn "$SCRIPT_PARENT" "$INFRA_DIR"
    fi
    cd "$INFRA_DIR"
    log "Using local repo at $INFRA_DIR"
elif [ -d "$INFRA_DIR/.git" ]; then
    log "Repo already exists at $INFRA_DIR, pulling latest..."
    cd "$INFRA_DIR"
    git pull origin "$BRANCH"
elif [ -d "$INFRA_DIR/playbooks" ]; then
    log "Repo present at $INFRA_DIR (no git)"
    cd "$INFRA_DIR"
else
    log "Cloning $REPO_URL (branch: $BRANCH)..."
    git clone -b "$BRANCH" "$REPO_URL" "$INFRA_DIR"
    cd "$INFRA_DIR"
fi

log "Infrastructure repo ready at $INFRA_DIR"

###############################################################################
# STEP 4: CONFIGURE SECRETS
###############################################################################
header "Step 4/6: Configuring Secrets"

VAULT_FILE="$INFRA_DIR/group_vars/vault.yml"
VAULT_EXAMPLE="$INFRA_DIR/group_vars/vault.yml.example"

if [ -f "$VAULT_FILE" ]; then
    log "vault.yml already exists — skipping secret generation"
    echo -e "${YELLOW}If you need to re-edit: ansible-vault edit $VAULT_FILE${NC}"
else
    if [ ! -f "$VAULT_EXAMPLE" ]; then
        err "vault.yml.example not found at $VAULT_EXAMPLE"
        exit 1
    fi

    log "Generating vault.yml from template..."
    cp "$VAULT_EXAMPLE" "$VAULT_FILE"

    echo ""
    echo -e "${YELLOW}You MUST fill in the secrets before deployment.${NC}"
    echo ""
    echo "Required secrets:"
    echo "  - vault_proxmox_ip:            Hetzner public IP"
    echo "  - vault_cloudflare_api_token:   CF API token (Zone:DNS:Edit)"
    echo "  - vault_cloudflare_tunnel_id:   CF tunnel ID"
    echo "  - vault_cloudflare_zone_id:     CF zone ID"
    echo "  - vault_tailscale_auth_key:     Tailscale auth key"
    echo "  - vault_pg_password_*:          PostgreSQL passwords (10 DBs)"
    echo "  - vault_dragonflydb_password:   DragonflyDB password"
    echo "  - vault_openbao_token:          (auto-generated on first run)"
    echo "  - vault_openai_api_key:         OpenAI API key"
    echo "  - vault_anthropic_api_key:      Anthropic API key"
    echo "  - vault_pbs_*:                  PBS backup credentials"
    echo "  - vault_storagebox_*:           Hetzner StorageBox credentials"
    echo ""

    # Interactive or manual?
    read -p "Edit secrets now in nano? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        nano "$VAULT_FILE"
    else
        echo -e "${YELLOW}Edit manually later: nano $VAULT_FILE${NC}"
    fi

    # Check if user filled in at least the Proxmox IP
    if grep -q "CHANGE_ME" "$VAULT_FILE" 2>/dev/null; then
        warn "vault.yml still contains CHANGE_ME placeholders!"
        read -p "Continue anyway? Deployment will fail for unconfigured services. (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Edit secrets and re-run: bash $INFRA_DIR/scripts/setup-proxmox.sh${NC}"
            exit 0
        fi
    fi

    # Encrypt vault
    echo ""
    log "Encrypting vault.yml with ansible-vault..."
    echo -e "${YELLOW}Choose a strong vault password (you'll need it for future runs):${NC}"
    ansible-vault encrypt "$VAULT_FILE"
    log "vault.yml encrypted"
fi

###############################################################################
# STEP 5: DOWNLOAD DEBIAN 13 ISO (for VMs)
###############################################################################
header "Step 5/6: Downloading Debian 13 ISO"

ISO_DIR="/var/lib/vz/template/iso"
DEBIAN_ISO="debian-13-netinst.iso"

if [ -f "${ISO_DIR}/${DEBIAN_ISO}" ]; then
    log "Debian 13 ISO already present"
else
    log "Downloading Debian 13 netinst ISO..."
    # Try official Debian mirror
    DEBIAN_ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.0.0-amd64-netinst.iso"

    if wget -q --spider "$DEBIAN_ISO_URL" 2>/dev/null; then
        wget -q --show-progress -O "${ISO_DIR}/${DEBIAN_ISO}" "$DEBIAN_ISO_URL"
        log "Debian 13 ISO downloaded"
    else
        # Fallback: try to find the latest
        warn "Could not find exact Debian 13 ISO. Trying latest..."
        LATEST_URL=$(curl -fsSL "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/" 2>/dev/null \
            | grep -oP 'href="(debian-13[^"]*-netinst\.iso)"' | head -1 | cut -d'"' -f2)
        if [ -n "$LATEST_URL" ]; then
            wget -q --show-progress -O "${ISO_DIR}/${DEBIAN_ISO}" \
                "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/${LATEST_URL}"
            log "Downloaded: $LATEST_URL"
        else
            warn "Could not download Debian 13 ISO automatically."
            warn "Download manually to: ${ISO_DIR}/${DEBIAN_ISO}"
            warn "VMs (04, 05) will not be created without it."
        fi
    fi
fi

###############################################################################
# STEP 6: RUN ANSIBLE DEPLOYMENT
###############################################################################
header "Step 6/6: Deploying Infrastructure"

cd "$INFRA_DIR"

echo -e "${YELLOW}Deployment options:${NC}"
echo "  1) Full deployment (all 9 phases) — site.yml"
echo "  2) Proxmox init only (phase 0) — creates LXCs + VMs"
echo "  3) Phase-by-phase (interactive)"
echo "  4) Dry run (--check, no changes)"
echo ""
read -p "Choose [1-4]: " DEPLOY_CHOICE

case $DEPLOY_CHOICE in
    1)
        log "Running FULL deployment..."
        ansible-playbook site.yml \
            -i inventory/hosts.yml \
            --ask-vault-pass \
            -e "ansible_connection=local" \
            2>&1 | tee /var/log/grupafestiwale-deploy.log

        DEPLOY_EXIT=$?
        ;;
    2)
        log "Running Phase 0 only (Proxmox init)..."
        ansible-playbook playbooks/00-proxmox-init.yml \
            -i inventory/hosts.yml \
            --ask-vault-pass \
            -e "ansible_connection=local" \
            2>&1 | tee /var/log/grupafestiwale-deploy.log

        DEPLOY_EXIT=$?
        ;;
    3)
        PLAYBOOKS=(
            "00-proxmox-init.yml:FAZA 0 - Proxmox VE + ZFS + SDN"
            "01-vault.yml:FAZA 1 - OpenBao Vault"
            "02-core.yml:FAZA 2 - Core (Tailscale + Traefik + Cloudflared)"
            "03-database.yml:FAZA 3 - Database (PostgreSQL + DragonflyDB)"
            "02b-auth.yml:FAZA 3b - Authentik (SSO + Entra ID)"
            "04-data.yml:FAZA 4 - Data (NextCloud + Paperless-NGX)"
            "05-ai-prod.yml:FAZA 5 - AI Production"
            "06-dev.yml:FAZA 6 - Development Environment"
            "07-monitoring.yml:FAZA 7 - Monitoring"
            "08-backup.yml:FAZA 8 - Backup"
            "09-hardening.yml:FAZA 9 - Security Hardening"
        )

        echo ""
        for i in "${!PLAYBOOKS[@]}"; do
            IFS=: read -r file desc <<< "${PLAYBOOKS[$i]}"
            echo "  $((i+1))) $desc"
        done
        echo ""
        read -p "Start from phase (1-11): " START_PHASE
        START_PHASE=$((START_PHASE - 1))

        DEPLOY_EXIT=0
        for i in "${!PLAYBOOKS[@]}"; do
            if [ "$i" -lt "$START_PHASE" ]; then
                continue
            fi
            IFS=: read -r file desc <<< "${PLAYBOOKS[$i]}"
            log "Running: $desc"
            ansible-playbook "playbooks/$file" \
                -i inventory/hosts.yml \
                --ask-vault-pass \
                -e "ansible_connection=local" \
                2>&1 | tee -a /var/log/grupafestiwale-deploy.log

            if [ $? -ne 0 ]; then
                err "Phase failed: $desc"
                read -p "Continue to next phase? (y/N) " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    DEPLOY_EXIT=1
                    break
                fi
            fi
        done
        ;;
    4)
        log "Dry run (no changes)..."
        ansible-playbook site.yml \
            -i inventory/hosts.yml \
            --ask-vault-pass \
            --check \
            -e "ansible_connection=local" \
            2>&1 | tee /var/log/grupafestiwale-deploy.log

        DEPLOY_EXIT=$?
        ;;
    *)
        err "Invalid choice"
        exit 1
        ;;
esac

###############################################################################
# DONE
###############################################################################
echo ""

if [ "${DEPLOY_EXIT:-0}" -eq 0 ]; then
    header "DEPLOYMENT COMPLETE"
    echo -e "${GREEN}Grupa Festiwale infrastructure is ready!${NC}"
    echo ""
    echo "  Proxmox:     https://pve1.grupafestiwale.pl:8006"
    echo "  Vault:       http://10.10.60.7:8200"
    echo "  Traefik:     http://10.10.10.2:8080"
    echo "  PostgreSQL:  10.10.30.3:5432"
    echo "  DragonflyDB: 10.10.30.3:6379"
    echo "  Authentik:   https://auth.grupafestiwale.pl"
    echo ""
    echo "  Public URLs (via Cloudflare Tunnel):"
    echo "    chat.grupafestiwale.pl     — LobeChat"
    echo "    n8n.grupafestiwale.pl      — N8N"
    echo "    dify.grupafestiwale.pl     — Dify AI"
    echo "    files.grupafestiwale.pl    — NextCloud"
    echo "    docs.grupafestiwale.pl     — Paperless-NGX"
    echo "    borys.grupafestiwale.pl    — AI Admin Panel"
    echo "    rekrutacja.grupafestiwale.pl — HR Panel"
    echo ""
    echo "  Dev (VM-05):"
    echo "    ssh vm-05-dev"
    echo "    /opt/dev/scripts/dev-manage.sh status"
    echo ""
    echo "  Logs: /var/log/grupafestiwale-deploy.log"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Unseal OpenBao: check /root/.openbao-init-keys.json on LXC-00"
    echo "  2. Configure Authentik: https://auth.grupafestiwale.pl/if/flow/initial-setup/"
    echo "  3. Connect Entra ID: Authentik Admin > Federation > Microsoft Entra ID"
    echo "  4. Install VMs: attach Debian 13 ISO and run OS install on VM-04, VM-05"
    echo "     Then run: ansible-playbook playbooks/05-ai-prod.yml playbooks/06-dev.yml"
    echo "  5. Verify monitoring: https://grafana.grupafestiwale.pl"
    echo ""
else
    header "DEPLOYMENT INCOMPLETE"
    err "Some phases failed. Check: /var/log/grupafestiwale-deploy.log"
    echo ""
    echo "To retry a specific phase:"
    echo "  cd $INFRA_DIR"
    echo "  ansible-playbook playbooks/XX-phase.yml -i inventory/hosts.yml --ask-vault-pass"
    echo ""
fi
