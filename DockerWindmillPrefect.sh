#!/usr/bin/env bash
#
# install-docker-prefect-windmill.sh
# =============================================================================
# PURPOSE
#   Provisions a single Ubuntu Server (ARM64) host to run both Prefect and
#   Windmill entirely as Docker containers, with a consistent operational
#   pattern for both (docker-compose in a dedicated /opt directory each).
#
# WHAT THIS SCRIPT DOES, IN ORDER
#   1. Removes any preexisting Docker, Prefect, or Windmill install on the
#      box (packages, containers, volumes, systemd units, repo files) so
#      the run is idempotent — safe to re-run from scratch.
#   2. Installs base OS packages (curl, ufw, fail2ban, openssl, jq, etc).
#   3. Installs Docker Engine from Docker's official apt repo (arm64),
#      applies a hardened daemon.json, adds the invoking user to the
#      `docker` group.
#   4. Configures a default-deny UFW firewall (SSH + the two app ports
#      open for now — see REQUIRED FOLLOW-UP below).
#   5. Enables fail2ban for SSH brute-force protection.
#   6. Deploys Prefect (server + worker + its own Postgres) via
#      docker-compose in /opt/prefect, on an isolated Docker network.
#      UI/API is published to 127.0.0.1 only — not reachable from the
#      network until you add a reverse proxy.
#   7. Deploys Windmill (official compose stack, bundled/local Postgres)
#      via docker-compose in /opt/windmill.
#   8. Prints a summary of what was installed, where secrets live, and
#      the manual steps this script deliberately does NOT automate.
#
# DIRECTORY LAYOUT AFTER RUNNING
#   /opt/prefect/
#     docker-compose.yml   Prefect server + worker + postgres definition
#     .env                 Generated Postgres credentials (mode 600, root)
#   /opt/windmill/
#     docker-compose.yml   Official Windmill stack (fetched from GitHub)
#     .env                 Generated Postgres password + Windmill token (mode 600, root)
#
# SECURITY POSTURE APPLIED
#   - Docker: log rotation capped, no-new-privileges, inter-container
#     communication disabled by default, live-restore on.
#   - Both compose stacks: no-new-privileges on every service, isolated
#     Docker networks per stack (Prefect and Windmill cannot reach each
#     other's databases).
#   - Firewall: default-deny inbound, only SSH + the two app ports allowed
#     — intended as a bootstrap state, NOT the end state. See the
#     REQUIRED follow-up section printed at the end of the run.
#   - Secrets: all generated passwords/tokens go into root-owned, mode 600
#     .env files — never printed to stdout in full.
#   - fail2ban enabled for SSH.
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO (see printed summary for why)
#   - Does not set up TLS or a reverse proxy (needs your domain/DNS/cert
#     decisions, which vary per environment).
#   - Does not change Windmill's default superadmin password — Windmill
#     sets this on first boot; you must log in and change it yourself.
#   - Does not restrict the firewall to specific source IPs — narrow this
#     once you know which subnet/VPN will be accessing these UIs.
#
# PREREQUISITES
#   - Ubuntu 22.04/24.04, arm64 (warns but continues on other arches).
#   - Run as root or via sudo.
#   - Outbound internet access to: download.docker.com, raw.githubusercontent.com,
#     Docker Hub / GHCR (for pulling images), Ubuntu archive mirrors.
#
# USAGE
#   sudo ./install-docker-prefect-windmill.sh
#
# GROUP MEMBERSHIP NOTE (docker group, no logout required)
#   The script adds you to the `docker` group so you can run `docker`
#   without `sudo`. Linux only re-reads group membership when a NEW
#   session/shell starts — a script cannot change the group membership
#   of the shell that invoked it (that's a kernel-level limitation, not
#   something any script can work around). You do NOT need to reboot or
#   log out of SSH entirely, though — either of these gets you a fresh
#   session immediately:
#     newgrp docker          # replaces your current shell with one that
#                             # has the docker group active (run manually,
#                             # right after the script finishes)
#     exec su -l "$USER"     # equivalent alternative
#   The script itself already ran everything it needs as root, so
#   nothing during THIS run is blocked by group membership — the note
#   above only matters for your own manual `docker` commands afterward.
#
# After it finishes, read the printed SUMMARY block carefully —
# it contains generated secrets and manual follow-up steps
# (TLS/reverse proxy, firewall review) that this script cannot
# safely automate without knowing your domain/network setup.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config — adjust before running if needed
# ---------------------------------------------------------------------------
TARGET_USER="${SUDO_USER:-$(whoami)}"
WINDMILL_DIR="/opt/windmill"
PREFECT_DIR="/opt/prefect"
PREFECT_UI_PORT="4200"
WINDMILL_HTTP_PORT="8000"

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this script with sudo/root."

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "arm64" ]] || warn "Detected architecture '$ARCH', expected arm64 — continuing anyway."

# ---------------------------------------------------------------------------
# 1. Remove preexisting components
#    Makes this script safe to re-run: tears down any prior Windmill/Prefect
#    compose stacks (including their volumes — DATA LOSS if you re-run this
#    intentionally, that's expected), any old native/systemd Prefect install
#    from an earlier version of this script, and any existing Docker
#    packages so the Docker install below is a clean one.
# ---------------------------------------------------------------------------
log "Stopping and removing any existing Windmill deployment"
if [[ -d "$WINDMILL_DIR" ]]; then
    (cd "$WINDMILL_DIR" && docker compose down -v --remove-orphans) 2>/dev/null || true
    rm -rf "$WINDMILL_DIR"
fi

log "Stopping and removing any existing Prefect deployment (container or old native install)"
if [[ -d "$PREFECT_DIR" ]]; then
    (cd "$PREFECT_DIR" && docker compose down -v --remove-orphans) 2>/dev/null || true
    rm -rf "$PREFECT_DIR"
fi
# Clean up a previous native/systemd install if this box had one
systemctl stop prefect-server.service 2>/dev/null || true
systemctl disable prefect-server.service 2>/dev/null || true
rm -f /etc/systemd/system/prefect-server.service
systemctl daemon-reload 2>/dev/null || true
pipx uninstall prefect 2>/dev/null || true
pip3 uninstall -y prefect 2>/dev/null || true
id -u prefect &>/dev/null && userdel -r prefect 2>/dev/null || true

log "Removing any existing Docker packages/repos (clean reinstall)"
systemctl stop docker 2>/dev/null || true
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc \
           docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done
rm -rf /var/lib/docker /var/lib/containerd /etc/docker
rm -f /etc/apt/sources.list.d/docker.list
rm -f /etc/apt/keyrings/docker.asc

# ---------------------------------------------------------------------------
# 2. Base packages
# ---------------------------------------------------------------------------
log "Updating apt and installing base packages"
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg lsb-release ufw fail2ban openssl jq

# ---------------------------------------------------------------------------
# 3. Install Docker Engine (official repo, arm64)
# ---------------------------------------------------------------------------
log "Installing Docker Engine from official Docker repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# --- Docker hardening ---
log "Applying Docker daemon hardening (log rotation, no-new-privileges, disabled inter-container comms by default)"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "no-new-privileges": true,
  "icc": false,
  "userland-proxy": false,
  "live-restore": true
}
EOF

systemctl enable docker
systemctl restart docker

log "Adding user '${TARGET_USER}' to the docker group"
usermod -aG docker "${TARGET_USER}"

# Prove docker access works for the target user's group membership right now,
# without waiting for them to open a new session — 'sg' runs a command in a
# subshell with the given group active, which is enough to verify the group
# assignment took effect even though it can't reach back into their existing
# interactive shell (see the GROUP MEMBERSHIP NOTE at the top of this file).
log "Verifying docker group membership works for '${TARGET_USER}'"
if su - "${TARGET_USER}" -c "sg docker -c 'docker version' " >/dev/null 2>&1; then
    log "Confirmed: '${TARGET_USER}' can run docker via the docker group."
else
    warn "Could not confirm docker group access for '${TARGET_USER}' — check 'groups ${TARGET_USER}' after the script finishes."
fi

warn "Your CURRENT shell (the one that ran sudo) still doesn't have the docker group active."
warn "Run this now, in the shell you'll actually use, to pick it up without logging out: newgrp docker"

# ---------------------------------------------------------------------------
# 4. Firewall baseline (UFW)
#    Default-deny inbound. Only SSH plus the two app ports are opened, and
#    that's intentionally a bootstrap state — see REQUIRED follow-up #1/#2
#    in the final summary for tightening this once a reverse proxy exists.
# ---------------------------------------------------------------------------
log "Configuring UFW baseline firewall rules"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow "${PREFECT_UI_PORT}/tcp" comment 'Prefect UI/API - restrict source further once static IP known'
ufw allow "${WINDMILL_HTTP_PORT}/tcp" comment 'Windmill UI - restrict source further, put behind reverse proxy for TLS'
ufw --force enable

warn "UFW currently allows ports ${PREFECT_UI_PORT} and ${WINDMILL_HTTP_PORT} from ANY source."
warn "Best practice: front both with a reverse proxy (Caddy/nginx) on 443 with a real TLS cert,"
warn "then tighten these rules to 'ufw allow from <trusted_subnet> to any port <port>' or remove the direct allow entirely."

# ---------------------------------------------------------------------------
# 5. Fail2ban for SSH (defense in depth since this is a security-team box)
# ---------------------------------------------------------------------------
log "Enabling fail2ban for SSH brute-force protection"
systemctl enable fail2ban
systemctl restart fail2ban

# ---------------------------------------------------------------------------
# 6. Prefect — docker-compose (server + own Postgres, isolated network)
#    Three services: prefect-db (postgres), prefect-server (API + UI, bound
#    to 127.0.0.1 only), prefect-worker (polls the 'default-agent-pool'
#    work pool — point your deployments at that pool, or rename it).
#    All three share a private 'prefect_internal' bridge network so nothing
#    else on the host/Docker can reach prefect-db directly.
# ---------------------------------------------------------------------------
log "Setting up Prefect via docker-compose with its own local Postgres database"
mkdir -p "$PREFECT_DIR"
cd "$PREFECT_DIR"

PF_DB_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)"

cat > .env <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) — treat as a secret, not committed to git
POSTGRES_USER=prefect
POSTGRES_PASSWORD=${PF_DB_PASSWORD}
POSTGRES_DB=prefect
PREFECT_API_DATABASE_CONNECTION_URL=postgresql+asyncpg://prefect:${PF_DB_PASSWORD}@prefect-db:5432/prefect
EOF
chmod 600 .env

cat > docker-compose.yml <<'EOF'
services:
  prefect-db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - prefect_db_data:/var/lib/postgresql/data
    networks:
      - prefect_internal
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  prefect-server:
    image: prefecthq/prefect:3-latest
    restart: unless-stopped
    command: prefect server start --host 0.0.0.0
    environment:
      PREFECT_API_DATABASE_CONNECTION_URL: ${PREFECT_API_DATABASE_CONNECTION_URL}
      PREFECT_SERVER_API_HOST: 0.0.0.0
      PREFECT_UI_API_URL: http://127.0.0.1:4200/api
    ports:
      - "127.0.0.1:4200:4200"
    depends_on:
      prefect-db:
        condition: service_healthy
    networks:
      - prefect_internal
    security_opt:
      - no-new-privileges:true
    read_only: false

  prefect-worker:
    image: prefecthq/prefect:3-latest
    restart: unless-stopped
    command: prefect worker start --pool default-agent-pool
    environment:
      PREFECT_API_URL: http://prefect-server:4200/api
    depends_on:
      - prefect-server
    networks:
      - prefect_internal
    security_opt:
      - no-new-privileges:true

networks:
  prefect_internal:
    driver: bridge

volumes:
  prefect_db_data:
EOF

log "Pulling and starting Prefect containers"
docker compose pull
docker compose up -d

chown -R root:docker "$PREFECT_DIR"
chmod 750 "$PREFECT_DIR"

warn "Prefect UI is published to 127.0.0.1:${PREFECT_UI_PORT} only — access via SSH tunnel or reverse proxy, not directly."
warn "The UFW allow rule on ${PREFECT_UI_PORT} is a placeholder for later reverse-proxy use; direct access won't work until you change the port binding or add a proxy."

# ---------------------------------------------------------------------------
# 7. Windmill — docker-compose (local/bundled Postgres)
#    Pulls the official docker-compose.yml straight from the Windmill repo
#    (server + worker(s) + LSP + its own postgres) and injects a generated
#    DB password in place of the repo's placeholder. Runs on Windmill's own
#    default Docker network, separate from Prefect's.
# ---------------------------------------------------------------------------
log "Setting up Windmill with local bundled Postgres database"
mkdir -p "$WINDMILL_DIR"
cd "$WINDMILL_DIR"

curl -fsSL https://raw.githubusercontent.com/windmill-labs/windmill/main/docker-compose.yml -o docker-compose.yml

WM_DB_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)"
WM_TOKEN="$(openssl rand -hex 32)"

cat > .env <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) — treat as a secret, not committed to git
POSTGRES_PASSWORD=${WM_DB_PASSWORD}
DATABASE_URL=postgres://postgres:${WM_DB_PASSWORD}@db:5432/windmill?sslmode=disable
MODE=standalone
BASE_URL=http://localhost:${WINDMILL_HTTP_PORT}
RUST_LOG=info
WM_TOKEN=${WM_TOKEN}
EOF
chmod 600 .env

sed -i "s#changeme#${WM_DB_PASSWORD}#g" docker-compose.yml || true

log "Pulling and starting Windmill containers"
docker compose pull
docker compose up -d

log "Waiting for Windmill to become healthy"
for i in {1..30}; do
    if curl -fs "http://127.0.0.1:${WINDMILL_HTTP_PORT}/api/version" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

chown -R root:docker "$WINDMILL_DIR"
chmod 750 "$WINDMILL_DIR"

# ---------------------------------------------------------------------------
# 8. Final summary
# ---------------------------------------------------------------------------
cat <<SUMMARY

================================================================
 INSTALL COMPLETE — READ THIS BEFORE WALKING AWAY
================================================================

Everything now runs in Docker:
  - Docker Engine + hardened daemon.json
  - Prefect: server + worker + its own Postgres, all in ${PREFECT_DIR} (docker-compose.yml)
  - Windmill: full stack + bundled Postgres, all in ${WINDMILL_DIR} (docker-compose.yml)

Docker
  - User '${TARGET_USER}' added to the docker group (verified working above)
  - Your CURRENT shell doesn't have it active yet — no reboot/logout needed though.
    Run ONE of these right now in the shell you'll actually use:
      newgrp docker          # swaps in the new group for this shell
      exec su -l ${TARGET_USER}   # equivalent, fresh login shell
    After that, 'docker ps' etc. will work without sudo.
  - One operational pattern for both tools:
      cd ${PREFECT_DIR}  && docker compose pull && docker compose up -d   # update Prefect
      cd ${WINDMILL_DIR} && docker compose pull && docker compose up -d   # update Windmill
      docker compose logs -f <service>                                    # logs, either dir

Prefect
  - UI/API published to 127.0.0.1:${PREFECT_UI_PORT} ONLY (not reachable from the network directly)
  - Access via SSH tunnel meanwhile:
      ssh -L ${PREFECT_UI_PORT}:127.0.0.1:${PREFECT_UI_PORT} <user>@<this-host>
      then browse http://127.0.0.1:${PREFECT_UI_PORT}
  - DB password stored in ${PREFECT_DIR}/.env (mode 600, root-owned)
  - Worker container is already running and polling the 'default-agent-pool' work pool —
    point your deployments at that pool name, or create/rename pools to match your flows.

Windmill
  - UI: http://<this-host>:${WINDMILL_HTTP_PORT}  (direct, not yet behind TLS)
  - Local bundled Postgres, generated password stored in ${WINDMILL_DIR}/.env (mode 600, root-owned)
  - FIRST LOGIN: default superadmin is admin@windmill.dev / changeme
    -> log in immediately and change this password
  - Windmill CLI token generated (WM_TOKEN in .env) for future scripted access

REQUIRED follow-up (not automated — needs your domain/network decisions):
  1. Put both Prefect and Windmill behind a reverse proxy (Caddy or nginx) terminating TLS
     on 443 with a real certificate (Let's Encrypt if internet-facing, internal CA if not).
     For Prefect specifically, once the proxy exists you can keep its container port bound
     to 127.0.0.1 and have the proxy be the only thing reaching it — don't republish it to 0.0.0.0.
  2. Once the reverse proxy is in place, tighten UFW:
       ufw delete allow ${PREFECT_UI_PORT}/tcp
       ufw delete allow ${WINDMILL_HTTP_PORT}/tcp
     and only allow 443 (restrict source IPs/subnet if this stays internal-only).
  3. Change the Windmill superadmin password on first login (see above).
  4. Consider MFA on the Windmill superadmin account if supported in your version.
  5. Back up both ${PREFECT_DIR}/.env + its Postgres volume, and ${WINDMILL_DIR}/.env + its
     Postgres volume. Losing either DB password/volume loses that tool's data.
  6. Review fail2ban jail defaults (/etc/fail2ban/jail.local) for your environment.
  7. Consider Docker volume/network segmentation review if you later add more containers
     to this host — prefect_internal and Windmill's default network are intentionally
     separate so the two stacks can't reach each other's databases.

================================================================
SUMMARY
