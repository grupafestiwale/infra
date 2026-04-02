# Grupa Festiwale — Infrastructure Review Document

**Prepared for:** DevOps Review  
**Date:** 2026-04-02  
**Author:** Piotr Bajorek (CTO) + Claude Code  
**Repository:** github.com/grupafestiwale/infra (private)  
**Codebase:** 85 files, 4777 lines (Ansible + Jinja2 + Bash)

---

## 1. Executive Summary

Single Hetzner dedicated server running Proxmox VE 9.1 with 5 LXC containers + 2 VMs, segmented across 6 VLANs. Full Ansible automation (10 playbooks, 15 roles). Public traffic via Cloudflare Tunnel, admin via Tailscale mesh VPN. SSO through Authentik federated with Microsoft Entra ID. Secrets managed in Doppler.

**Business context:** Festival company (~6.1M PLN/year, 12 employees), running AI-augmented operations (automated workflows, document processing, LLM-powered tools, CRM).

---

## 2. Hardware

### 2.1 Hetzner Dedicated Server (pve1.grupafestiwale.pl)

| Spec | Value |
|------|-------|
| CPU | AMD Ryzen 9 5950X — 16C/32T @ 3.4–4.9 GHz |
| RAM | 128 GB DDR4 ECC |
| Storage | 2x 3.84 TB NVMe SSD (ZFS mirror = 3.84 TB usable) |
| Network | 1 Gbit/s unmetered |
| OS | Proxmox VE 9.1-1 (Debian 13 Trixie) |
| Location | Hetzner DC, Germany |

### 2.2 Future: Office Server (not yet purchased)

- EPYC CPU + 6x22TB RAIDZ2 + RTX 3090
- Asterisk + VibeVoice (TTS/ASR) + Proxmox Backup Server
- Connected via Tailscale to Hetzner

### 2.3 Future: Threadripper Pro Workstation

- WX 9000 + RTX 5090 + Radeon AI Pro 32GB
- Mobile AI for on-site events (offline Fri–Sun, office Mon–Thu)

---

## 3. Network Architecture

### 3.1 VLAN Segmentation

```
Internet
    |
[Hetzner Public IP] ─── vmbr0 (eno1)
    |
    ├── vmbr10  VLAN 10  MGMT     10.10.10.0/24  ← LXC-01 Core, LXC-06 Auth
    ├── vmbr20  VLAN 20  DMZ      10.10.20.0/24  ← LXC-01 (eth1), LXC-06 (eth1)
    ├── vmbr30  VLAN 30  DATA     10.10.30.0/24  ← LXC-02 DB, LXC-03 Data
    ├── vmbr40  VLAN 40  APPS     10.10.40.0/24  ← VM-04 AI Prod
    ├── vmbr50  VLAN 50  DEV      10.10.50.0/24  ← VM-05 Dev
    └── vmbr60  VLAN 60  VAULT    10.10.60.0/24  ← LXC-00 Vault (isolated)
```

### 3.2 Inter-VLAN Firewall Rules

| Source | Destination | Rule |
|--------|-------------|------|
| VLAN 40 (Apps) | VLAN 30 (Data) | ALLOW (DB access) |
| VLAN 50 (Dev) | VLAN 30 (Data) | ALLOW (DB access) |
| VLAN 30 (Data) | VLAN 40/50 | ALLOW ESTABLISHED,RELATED only |
| VLAN 10/40/50 | VLAN 60:8200 | ALLOW (Vault API only) |
| Any VLAN | Any VLAN | DROP (default) |
| VLAN 10/20/40/50 | Internet (vmbr0) | NAT MASQUERADE |
| VLAN 30 (Data) | Internet | BLOCKED (no NAT) |
| VLAN 60 (Vault) | Internet | BLOCKED (no NAT) |

### 3.3 External Access

| Method | Purpose | Endpoint |
|--------|---------|----------|
| **Cloudflare Tunnel** | Public HTTPS traffic | *.grupafestiwale.pl → Traefik on LXC-01 |
| **Tailscale** | Admin/SSH access | Mesh VPN, Proxmox as exit node |
| **SSH (port 22)** | Emergency only | Key-only, password auth disabled |

---

## 4. Compute — Nodes & Resource Allocation

### 4.1 Overview

| VMID | Name | Type | vCPU | RAM | Disk | VLAN | IP | Boot Order |
|------|------|------|------|-----|------|------|----|------------|
| 100 | LXC-00 VAULT | LXC | 2 | 4 GB | 20 GB | 60 | 10.10.60.7 | 1 |
| 101 | LXC-01 CORE | LXC | 2 | 8 GB | 30 GB | 10+20 | 10.10.10.2 / 10.10.20.2 | 2 |
| 102 | LXC-02 DB | LXC | 8 | 32 GB | 50 GB + ZFS | 30 | 10.10.30.3 | 3 |
| 103 | LXC-03 DATA | LXC | 4 | 8 GB | 30 GB + ZFS | 30 | 10.10.30.4 | 4 |
| 104 | VM-04 AI PROD | VM | 8 | 32 GB | 1 TB | 40 | 10.10.40.5 | 5 |
| 105 | VM-05 DEV | VM | 6 | 20 GB | 1 TB | 50 | 10.10.50.6 | 6 |
| 106 | LXC-06 AUTH | LXC | 2 | 4 GB | 20 GB | 10+20 | 10.10.10.8 / 10.10.20.8 | 4 |

### 4.2 Resource Totals

| Resource | Allocated | Available | Overcommit |
|----------|-----------|-----------|------------|
| vCPU | 32 (LXC) + 14 (VM) = 34 | 32 threads | 1.06x (OK for LXC, idle containers share kernel) |
| RAM | 4+8+32+8+32+20+4 = 108 GB | 128 GB | 20 GB free for ZFS ARC + Proxmox host |
| Disk (rootfs) | ~170 GB (LXC) + 2 TB (VM) | 3.84 TB | 1.67 TB free (43% buffer) |

### 4.3 ZFS Configuration

- **Pool:** `rpool` (mirror, 2x 3.84 TB NVMe, ashift=12)
- **Datasets:**
  - `rpool/data/db` — PostgreSQL (recordsize=8K, primarycache=metadata, logbias=latency)
  - `rpool/data/files` — NextCloud/Paperless (recordsize=1M, compression=lz4)
- **Auto-snapshots:** Hourly (keep 24) + Daily (keep 7)

---

## 5. Node Details

### 5.1 LXC-00 VAULT (OpenBao)

| | |
|---|---|
| **Purpose** | Secrets management (HashiCorp Vault fork, MPL license) |
| **Software** | OpenBao 2.1.0 |
| **VLAN** | 60 (isolated — no internet, API-only on port 8200) |
| **Init** | Auto-initialized with 5/3 Shamir keys |
| **Access** | From VLAN 10, 40, 50 on port 8200 only |

### 5.2 LXC-01 CORE (Traffic Hub)

| | |
|---|---|
| **Purpose** | All inbound traffic routing + monitoring + VPN |
| **Software** | Traefik v3.2 (binary, systemd), Cloudflared, Tailscale |
| **NICs** | eth0: VLAN 10 (10.10.10.2), eth1: VLAN 20 (10.10.20.2) |
| **Traefik** | Wildcard TLS via Cloudflare DNS challenge, forward-auth to Authentik |
| **Monitoring** | Prometheus (30d retention), Grafana, Alertmanager, Loki (7d retention) |

**Traffic flow:**
```
User → Cloudflare Tunnel → Cloudflared (LXC-01) → Traefik → Authentik (forward-auth)
                                                      ↓ (authenticated)
                                                   Backend service
```

### 5.3 LXC-02 DB (Database Engine)

| | |
|---|---|
| **Purpose** | Central database for all applications |
| **Software** | PostgreSQL 16 + RuVector + JSONB, DragonflyDB, PgBouncer |
| **VLAN** | 30 (Data — no internet access) |
| **Storage** | ZFS dataset mounted at /var/lib/postgresql |
| **Resources** | 8 vCPU, 32 GB RAM (largest LXC — this is the backbone) |

**PostgreSQL 16 tuning:**

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| shared_buffers | 8 GB | 25% of RAM |
| effective_cache_size | 24 GB | 75% of RAM |
| work_mem | 256 MB | Complex AI queries |
| maintenance_work_mem | 1 GB | Fast VACUUM/INDEX |
| max_parallel_workers_per_gather | 4 | Parallel query |
| wal_level | replica | PITR ready |

**Databases (10):**
`n8n`, `dify`, `nextcloud`, `paperless`, `agentdb`, `litellm`, `lobechat`, `authentik`, `borys`, `rekrutacja`

**pg_hba.conf** — per-database, per-IP ACL. Each app can only access its own database from its own VLAN IP.

**DragonflyDB** (Redis-compatible, 80% less RAM, 25x faster):
- Bound to 10.10.30.3 only (internal)
- maxmemory: 6 GB, 4 proactor threads
- Used by: Authentik (sessions), N8N (queue), Dify (cache), LobeChat (cache)

**PgBouncer:**
- Transaction pooling mode
- max_client_conn: 1000 (for ticket sale spikes)
- default_pool_size: 30

**Backup:** Daily pg_dumpall cron (7-day retention) + WAL archiving for PITR

### 5.4 LXC-03 DATA (Files & Documents)

| | |
|---|---|
| **Purpose** | File storage and document management |
| **Software** | NextCloud (Docker), Paperless-NGX (Docker + OCR pl+en) |
| **VLAN** | 30 (Data) |
| **Storage** | ZFS dataset at /srv/data, Hetzner StorageBox (SSHFS, planned) |

### 5.5 VM-04 AI PROD (Production AI Stack)

| | |
|---|---|
| **Purpose** | All AI/ML production services |
| **OS** | Debian 13 + Docker CE + Docker Compose v2 |
| **VLAN** | 40 (Apps) |
| **Resources** | 8 vCPU, 32 GB RAM, 1 TB disk |

**Docker stack (12 containers):**

| Container | Port | RAM Limit | Description |
|-----------|------|-----------|-------------|
| Traefik | 80/443 | — | Local reverse proxy (Docker auto-discovery) |
| Socket Proxy | — | — | Tecnativa Docker socket proxy (security) |
| Ollama | 11434 | 16 GB | Local LLM inference (llama3, mistral) |
| LiteLLM | 4000 | 1 GB | LLM router (OpenAI + Anthropic + Ollama) |
| Dify | 3000 | 4 GB | AI platform (api + web + sandbox) |
| N8N | 5678 | 2 GB | Workflow automation |
| LobeChat | 3210 | 512 MB | Chat UI (proxied through LiteLLM) |
| RuFlo | 3001 | 512 MB | Agent runtime |
| Borys | 3100 | 1 GB | Next.JS AI admin panel |
| Rekrutacja | 3200 | 1 GB | Next.JS HR panel |
| CF Companion | — | 128 MB | Auto-creates DNS records |

**Docker networks:** `frontend` (Traefik-connected), `backend` (DB-connected, internal)

**LiteLLM routing config:**
- gpt-4o, claude-sonnet-4-20250514, claude-haiku-4-5-20251001 (cloud)
- llama3-8b, mistral-7b (local Ollama)
- Cost-based routing, DragonflyDB cache, PostgreSQL logging

### 5.6 VM-05 DEV (Development Environment)

| | |
|---|---|
| **Purpose** | Testable dev tools, selectively started to fit RAM |
| **OS** | Debian 13 + Docker CE + Traefik (auto-discovery) |
| **VLAN** | 50 (Dev) |
| **Resources** | 6 vCPU, 20 GB RAM, 1 TB disk |

**5 selectable stacks (managed by dev-manage.sh):**

| Stack | Containers | RAM | Description |
|-------|------------|-----|-------------|
| **coding** | OpenHands, Bolt.diy, Tabby | ~8 GB | AI coding assistants + code completion |
| **agentic** | DeerFlow 2.0, Hermes Agent, CrewAI, OpenViking | ~6 GB | Agent orchestration + context DB |
| **crm** | Bitrix24, MySQL, Odoo Community | ~5 GB | CRM evaluation |
| **browser** | Lightpanda | ~0.5 GB | Headless browser for agents (CDP) |
| **n8n-dev** | N8N Dev | ~1 GB | Workflow development |

**RAM budget (17 GB available after system + Traefik):**
- coding + browser = 8.5 GB (OK)
- agentic + browser + n8n = 7.5 GB (OK)
- coding + agentic + browser = 14.5 GB (tight but OK)
- ALL AT ONCE = 20.5 GB (OOM!)

**Cloudflare Companion for Dev:** Auto-creates `*.dev.grupafestiwale.pl` DNS on Docker events

### 5.7 LXC-06 AUTH (Identity Provider)

| | |
|---|---|
| **Purpose** | SSO for all applications |
| **Software** | Authentik (Docker: server + worker) |
| **NICs** | eth0: VLAN 10 (10.10.10.8), eth1: VLAN 20 (10.10.20.8) |
| **Federation** | Microsoft Entra ID (M365 Business Basic) |
| **Backend** | PostgreSQL (authentik DB) + DragonflyDB (sessions) |

**Auth flow:**
```
User → app.grupafestiwale.pl → Traefik → forward-auth → Authentik
                                                            ↓
                                                     Entra ID (M365)
                                                            ↓
                                                     MFA + login
                                                            ↓
                                                     ← X-authentik-* headers → App
```

**Protected apps:** chat, n8n, dify, borys, rekrutacja, docs, files, ruflo, grafana  
**Unprotected:** api.grupafestiwale.pl (API key auth), auth.grupafestiwale.pl (login page)

---

## 6. Public DNS & Routing

### 6.1 Subdomains

| Subdomain | Backend | Port | Auth |
|-----------|---------|------|------|
| chat.grupafestiwale.pl | LobeChat (VM-04) | 3210 | Authentik + Entra ID |
| n8n.grupafestiwale.pl | N8N (VM-04) | 5678 | Authentik + Entra ID |
| dify.grupafestiwale.pl | Dify (VM-04) | 3000 | Authentik + Entra ID |
| api.grupafestiwale.pl | LiteLLM (VM-04) | 4000 | API Key |
| ruflo.grupafestiwale.pl | RuFlo (VM-04) | 3001 | Authentik + Entra ID |
| borys.grupafestiwale.pl | Borys (VM-04) | 3100 | Authentik + Entra ID |
| rekrutacja.grupafestiwale.pl | Rekrutacja (VM-04) | 3200 | Authentik + Entra ID |
| files.grupafestiwale.pl | NextCloud (LXC-03) | 8080 | Authentik + Entra ID |
| docs.grupafestiwale.pl | Paperless (LXC-03) | 8000 | Authentik + Entra ID |
| auth.grupafestiwale.pl | Authentik (LXC-06) | 9000 | Public (login page) |
| grafana.grupafestiwale.pl | Grafana (LXC-01) | 3000 | Authentik + Entra ID |
| *.dev.grupafestiwale.pl | Traefik Dev (VM-05) | auto | Tailscale only |

### 6.2 TLS

- Wildcard cert: `*.grupafestiwale.pl` via Cloudflare DNS-01 challenge
- Managed by Traefik on LXC-01 (ACME, auto-renewal)
- All traffic HTTPS-only (Cloudflare Full Strict)

---

## 7. Security Architecture

### 7.1 Layers

| Layer | Mechanism |
|-------|-----------|
| **Perimeter** | Cloudflare WAF + DDoS protection (free tier) |
| **Tunnel** | Cloudflared (no public ports exposed except SSH) |
| **VPN** | Tailscale (admin access, WireGuard-based) |
| **Firewall** | Proxmox FW (datacenter level, DROP default) + iptables inter-VLAN |
| **VLAN isolation** | 6 VLANs, DB/Vault have no internet |
| **Auth** | Authentik + Entra ID (MFA via M365) |
| **Secrets** | Doppler (SaaS) → vault.yml at deploy time. OpenBao for runtime secrets |
| **Docker** | Socket proxy (Tecnativa), unprivileged containers, resource limits |
| **SSH** | Key-only, password disabled |
| **TLS** | Wildcard via Cloudflare DNS challenge, end-to-end |

### 7.2 Attack Surface

| Exposed | Access Method | Protection |
|---------|---------------|------------|
| *.grupafestiwale.pl (HTTPS) | Cloudflare Tunnel | CF WAF + Authentik SSO + MFA |
| SSH (port 22) | Direct IP | Key-only, fail2ban (planned) |
| Proxmox UI (8006) | Tailscale only | VPN + local auth |
| Dev services | Tailscale only | VPN |

### 7.3 Secrets Flow

```
Doppler (SaaS) ──doppler-to-vault.sh──→ group_vars/vault.yml (plaintext, local only)
                                              ↓
                                        Ansible deploy
                                              ↓
                                    Rendered into configs on target nodes
                                    (env vars, config files, pg_hba.conf)
```

---

## 8. Monitoring & Alerting

### 8.1 Stack (all on LXC-01)

| Component | Retention | Purpose |
|-----------|-----------|---------|
| Prometheus | 30 days | Metrics collection |
| Grafana | — | Dashboards |
| Alertmanager | — | Alert routing (webhook to N8N) |
| Loki (TSDB) | 7 days | Log aggregation |
| node_exporter | — | On every node |
| postgres_exporter | — | PG metrics |
| cAdvisor | — | Docker container metrics (VM-04, VM-05) |

### 8.2 Alert Rules

| Alert | Condition | Severity |
|-------|-----------|----------|
| NodeDown | node_exporter unreachable 2m | critical |
| HighCPU | >90% for 10m | warning |
| HighMemory | >85% for 5m | warning |
| DiskSpace | >85% used | warning |
| PostgreSQLDown | pg_up == 0 for 1m | critical |
| HighConnections | >800 active | warning |
| SlowQueries | avg >500ms | warning |
| ContainerDown | container not running 2m | warning |
| BackupMissing | last backup >26h ago | critical |

---

## 9. Backup Strategy

### 9.1 Current (on-server)

| What | Method | Schedule | Retention |
|------|--------|----------|-----------|
| ZFS snapshots | zfs-auto-snapshot | Hourly + Daily | 24h + 7d |
| PostgreSQL | pg_dumpall | Daily 02:00 | 7 days |
| WAL archive | Continuous | Streaming | PITR capable |

### 9.2 Planned (offsite)

| Target | Method | Schedule |
|--------|--------|----------|
| PBS (office server) | Proxmox vzdump | Daily (per-node schedules) |
| Hetzner StorageBox (BX11) | rsync over SFTP | Weekly |

---

## 10. Ansible Automation

### 10.1 Playbook Order (site.yml)

| Phase | Playbook | Target | What it deploys |
|-------|----------|--------|-----------------|
| 0 | 00-proxmox-init.yml | Proxmox host | ZFS, VLANs, firewall, LXC/VM creation |
| 1 | 01-vault.yml | LXC-00 | OpenBao install + init |
| 2 | 02-core.yml | LXC-01 | Tailscale, Traefik, Cloudflared, Monitoring |
| 3 | 03-database.yml | LXC-02 | PostgreSQL, DragonflyDB, PgBouncer |
| 3b | 02b-auth.yml | LXC-06 | Authentik + Entra ID integration |
| 4 | 04-data.yml | LXC-03 | NextCloud, Paperless-NGX |
| 5 | 05-ai-prod.yml | VM-04 | Docker + full AI stack (12 containers) |
| 6 | 06-dev.yml | VM-05 | Docker + Traefik + 5 dev stacks |
| 7 | 07-monitoring.yml | LXC-01 | Prometheus, Grafana, Loki, alerts |
| 8 | 08-backup.yml | Proxmox | PBS schedules, StorageBox rsync |
| 9 | 09-hardening.yml | All | Security hardening |

### 10.2 Roles (15)

```
roles/
  ai-stack/          — Docker compose for VM-04 (12 containers)
  authentik/         — Authentik Docker + Entra ID
  cloudflare-companion/ — Auto DNS for Docker events
  cloudflared/       — CF Tunnel daemon
  common/            — Base packages, NTP, locale, node_exporter
  dev-stacks/        — 5 dev compose files + management script
  docker/            — Docker CE + compose v2 install
  dragonflydb/       — DragonflyDB install + config
  monitoring/        — Prometheus + Grafana + Alertmanager + Loki
  nextcloud/         — NextCloud Docker + StorageBox mount
  openbao/           — OpenBao install + auto-init
  paperless/         — Paperless-NGX Docker + OCR
  pgbouncer/         — Connection pooling
  postgresql/        — PG16 + RuVector + tuning + pg_hba
  tailscale/         — Tailscale VPN install
  traefik/           — Traefik v3 binary + dynamic config
```

### 10.3 Bootstrap

```bash
# On fresh Proxmox VE 9.1:
git clone https://github.com/grupafestiwale/infra.git /opt/grupafestiwale-infra
bash /opt/grupafestiwale-infra/scripts/setup-proxmox.sh
# → Installs Ansible, pulls secrets from Doppler, deploys everything
```

---

## 11. Known Limitations & TODOs

| Item | Status | Notes |
|------|--------|-------|
| VMs require manual Debian 13 install | TODO | LXC is auto-created, but VMs need ISO boot + OS install before Ansible can configure them |
| fail2ban not yet configured | TODO | Playbook 09-hardening.yml placeholder |
| Alertmanager destination | TODO | Webhook to N8N configured, but N8N flow not yet built |
| StorageBox not purchased | TODO | Offsite backup delayed, ZFS snapshots + PBS sufficient for now |
| PBS (office server) | TODO | Server not yet purchased |
| Authentik Entra ID flow | MANUAL | Requires manual setup in Authentik UI after deploy |
| vCPU overcommit 1.06x | ACCEPTED | LXC shares kernel, idle containers don't consume CPU |
| Dev stacks can OOM if all started | BY DESIGN | dev-manage.sh enforces selective startup with RAM warnings |
| `lobechat` duplicated in postgresql_databases | BUG | Line 130 in all.yml — remove duplicate |

---

## 12. Diagram

```
                            ┌─────────────────────────────────┐
                            │        INTERNET                  │
                            └──────────┬──────────────────────┘
                                       │
                            ┌──────────▼──────────────────────┐
                            │    Cloudflare (WAF + Tunnel)     │
                            │    *.grupafestiwale.pl            │
                            └──────────┬──────────────────────┘
                                       │ Tunnel
                            ┌──────────▼──────────────────────┐
                            │  PROXMOX VE 9.1 HOST             │
                            │  Ryzen 9 5950X / 128GB / 2x3.8T │
                            │  ZFS Mirror (rpool)              │
                            └──────────┬──────────────────────┘
                                       │
        ┌──────────────────────────────┼──────────────────────────────┐
        │                              │                              │
   ┌────▼────┐  ┌────────────┐  ┌─────▼─────┐  ┌──────────┐  ┌─────▼─────┐
   │ VLAN 60 │  │  VLAN 10   │  │  VLAN 30  │  │ VLAN 40  │  │ VLAN 50   │
   │ Vault   │  │  MGMT+DMZ  │  │  DATA     │  │ APPS     │  │ DEV       │
   └────┬────┘  └─────┬──────┘  └─────┬─────┘  └────┬─────┘  └─────┬─────┘
        │             │               │              │              │
   ┌────▼────┐  ┌─────▼──────┐ ┌─────▼─────┐ ┌─────▼──────┐ ┌─────▼──────┐
   │ LXC-00  │  │  LXC-01    │ │  LXC-02   │ │  VM-04     │ │  VM-05     │
   │ OpenBao │  │  Traefik   │ │  PG16     │ │  AI Prod   │ │  Dev       │
   │         │  │  CF Tunnel │ │  Dragonfly│ │  12 contrs │ │  5 stacks  │
   │         │  │  Tailscale │ │  PgBouncer│ │            │ │            │
   │         │  │  Prometheus│ │           │ │            │ │            │
   │         │  │  Grafana   │ │           │ │            │ │            │
   └─────────┘  │  Loki      │ └───────────┘ └────────────┘ └────────────┘
                └─────┬──────┘
                      │
                ┌─────▼──────┐
                │  LXC-06    │
                │  Authentik │
                │  + Entra ID│
                └────────────┘
```

---

## 13. Cost Estimate (monthly)

| Item | Cost |
|------|------|
| Hetzner AX52 (dedicated) | ~65 EUR |
| Cloudflare (free plan) | 0 EUR |
| Tailscale (free, <100 devices) | 0 EUR |
| Doppler (free, <5 users) | 0 EUR |
| M365 Business Basic (12 users) | ~72 EUR |
| Hetzner StorageBox BX11 (planned) | ~4 EUR |
| OpenAI API | variable |
| Anthropic API | variable |
| **Total (fixed)** | **~141 EUR/month** |

---

*End of review document. Questions and feedback welcome.*
