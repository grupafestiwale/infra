#!/bin/bash
###############################################################################
# Generate Ansible vault.yml from Doppler secrets
#
# Usage:
#   ./doppler-to-vault.sh                    # dev config (default)
#   ./doppler-to-vault.sh prd                # production config
#   DOPPLER_TOKEN=dp.xxx ./doppler-to-vault.sh  # service token (CI/CD)
###############################################################################

set -euo pipefail

CONFIG="${1:-dev}"
PROJECT="infra"
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/group_vars"
OUTPUT_FILE="${OUTPUT_DIR}/vault.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Check doppler CLI
if ! command -v doppler &>/dev/null; then
    echo -e "${RED}Doppler CLI not installed. Run: brew install dopplerhq/cli/doppler${NC}"
    exit 1
fi

echo -e "${GREEN}Pulling secrets from Doppler (project: $PROJECT, config: $CONFIG)...${NC}"

# Fetch all secrets as JSON
SECRETS=$(doppler secrets download --project "$PROJECT" --config "$CONFIG" --no-file --format json 2>/dev/null)

if [ -z "$SECRETS" ] || [ "$SECRETS" = "{}" ]; then
    echo -e "${RED}No secrets found in Doppler project '$PROJECT' config '$CONFIG'${NC}"
    exit 1
fi

# Helper to extract value
get() {
    echo "$SECRETS" | jq -r ".[\"$1\"] // \"CHANGE_ME\""
}

# Generate vault.yml
cat > "$OUTPUT_FILE" << VAULT
---
# Auto-generated from Doppler (project: $PROJECT, config: $CONFIG)
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# DO NOT edit manually — update in Doppler and re-run doppler-to-vault.sh

# Hetzner
vault_proxmox_ip: "$(get PROXMOX_IP)"

# Cloudflare
vault_cloudflare_api_token: "$(get CLOUDFLARE_API_TOKEN)"
vault_cloudflare_tunnel_token: "$(get CLOUDFLARE_TUNNEL_TOKEN)"
vault_cloudflare_tunnel_id: "$(get CLOUDFLARE_TUNNEL_ID)"
vault_cloudflare_zone_id: "$(get CLOUDFLARE_ZONE_ID)"

# Tailscale
vault_tailscale_authkey: "$(get TAILSCALE_AUTHKEY)"

# PostgreSQL
vault_pg_superuser_password: "$(get PG_SUPERUSER_PASSWORD)"
vault_pg_n8n_password: "$(get PG_N8N_PASSWORD)"
vault_pg_dify_password: "$(get PG_DIFY_PASSWORD)"
vault_pg_nextcloud_password: "$(get PG_NEXTCLOUD_PASSWORD)"
vault_pg_paperless_password: "$(get PG_PAPERLESS_PASSWORD)"
vault_pg_agentdb_password: "$(get PG_AGENTDB_PASSWORD)"
vault_pg_litellm_password: "$(get PG_LITELLM_PASSWORD)"
vault_pg_lobechat_password: "$(get PG_LOBECHAT_PASSWORD)"
vault_pg_authentik_password: "$(get PG_AUTHENTIK_PASSWORD)"
vault_pg_borys_password: "$(get PG_BORYS_PASSWORD)"
vault_pg_rekrutacja_password: "$(get PG_REKRUTACJA_PASSWORD)"

# DragonflyDB
vault_dragonflydb_password: "$(get DRAGONFLYDB_PASSWORD)"

# OpenBao
vault_openbao_unseal_keys: $(get OPENBAO_UNSEAL_KEYS)
vault_openbao_root_token: "$(get OPENBAO_ROOT_TOKEN)"

# LLM API Keys
vault_openai_api_key: "$(get OPENAI_API_KEY)"
vault_anthropic_api_key: "$(get ANTHROPIC_API_KEY)"
vault_minimax_api_key: "$(get MINIMAX_API_KEY)"

# Microsoft Entra ID / M365
vault_entra_id_app_id: "$(get ENTRA_ID_APP_ID)"
vault_entra_id_secret: "$(get ENTRA_ID_SECRET)"
vault_m365_tenant_id: "$(get M365_TENANT_ID)"
vault_m365_client_id: "$(get M365_CLIENT_ID)"
vault_m365_client_secret: "$(get M365_CLIENT_SECRET)"

# Integrations
vault_bitrix_webhook: "$(get BITRIX_WEBHOOK)"
vault_github_token: "$(get GITHUB_TOKEN)"
vault_allegro_client_id: "$(get ALLEGRO_CLIENT_ID)"
vault_allegro_client_secret: "$(get ALLEGRO_CLIENT_SECRET)"

# Telegram Bots
vault_telegram_bot_piotr: "$(get TELEGRAM_BOT_PIOTR)"
vault_telegram_bot_grazyna: "$(get TELEGRAM_BOT_GRAZYNA)"
vault_telegram_bot_claw: "$(get TELEGRAM_BOT_CLAW)"

# Backup
vault_pbs_server: "$(get PBS_SERVER)"
vault_pbs_fingerprint: "$(get PBS_FINGERPRINT)"
vault_pbs_password: "$(get PBS_PASSWORD)"
vault_storagebox_host: "$(get STORAGEBOX_HOST)"
vault_storagebox_user: "$(get STORAGEBOX_USER)"
vault_storagebox_password: "$(get STORAGEBOX_PASSWORD)"
VAULT

TOTAL_SECRETS=41
# Check for unfilled secrets
UNFILLED=$(grep -c "CHANGE_ME" "$OUTPUT_FILE" || true)
if [ "$UNFILLED" -gt 0 ]; then
    echo -e "${RED}WARNING: $UNFILLED secrets still set to CHANGE_ME — fill them in Doppler!${NC}"
fi

echo -e "${GREEN}Generated: $OUTPUT_FILE ($((TOTAL_SECRETS - UNFILLED))/${TOTAL_SECRETS} secrets filled)${NC}"
echo ""
echo "Next: ansible-playbook site.yml -i inventory/hosts.yml"
echo "  (no --ask-vault-pass needed — vault.yml is plaintext, secrets come from Doppler)"
