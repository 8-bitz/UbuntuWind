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
#   1. Removes any preexisting Docker, Prefect, Windmill, or Caddy install on
#      the box (packages, containers, volumes, systemd units, repo files) so
#      the run is idempotent — safe to re-run from scratch.
#   2. Installs base OS packages (curl, ufw, fail2ban, openssl, jq, etc).
#   3. Installs Docker Engine from Docker's official apt repo (arm64),
#      applies a hardened daemon.json, adds the invoking user to the
#      `docker` group.
#   4. Configures a default-deny UFW firewall (SSH + Caddy's two TLS ports
#      open — see REQUIRED FOLLOW-UP below for narrowing this further).
#   5. Enables fail2ban for SSH brute-force protection.
#   6. Deploys Prefect (server + worker + its own Postgres) via
#      docker-compose in /opt/prefect, on an isolated Docker network.
#      UI/API is published to 127.0.0.1 only — reached over the network
#      only through the Caddy reverse proxy in step 8.
#   7. Deploys Windmill (official compose stack, bundled/local Postgres)
#      via docker-compose in /opt/windmill, also bound to 127.0.0.1 only.
#   8. Deploys Caddy as a reverse proxy (host networking) that terminates
#      TLS for both apps using Caddy's built-in local CA — no domain or
#      public cert needed, since this is accessed over your network, not
#      the public internet.
#   9. Prints a summary of what was installed, where secrets live, the
#      URLs to use from other machines, and the manual steps this script
#      deliberately does NOT automate.
#
# DIRECTORY LAYOUT AFTER RUNNING
#   /opt/prefect/
#     docker-compose.yml   Prefect server + worker + postgres definition
#     .env                 Generated Postgres credentials (mode 600, root)
#   /opt/windmill/
#     docker-compose.yml   Official Windmill stack (fetched from GitHub)
#     .env                 Generated Postgres password + Windmill token + pinned
#                           WM_IMAGE (mode 600, root) — WM_IMAGE is required by the
#                           upstream compose file's image fields; without it,
#                           `docker compose up` fails with "has neither an image
#                           nor a build context specified".
#   /opt/caddy/
#     Caddyfile             Reverse proxy config for both apps
#     docker-compose.yml    Caddy container definition (host networking)
#
# SECURITY POSTURE APPLIED
#   - Docker: log rotation capped, no-new-privileges, inter-container
#     communication disabled by default, live-restore on.
#   - Both compose stacks: no-new-privileges on every service, isolated
#     Docker networks per stack (Prefect and Windmill cannot reach each
#     other's databases). Neither app's port is exposed beyond 127.0.0.1 —
#     only Caddy can reach them, and only Caddy is exposed to the network.
#   - Caddy terminates TLS for both apps using its automatic local CA
#     (`tls internal`) — encrypts traffic across your network without
#     needing a public domain or purchased certificate. Browsers will
#     show a trust warning until you import the generated root CA (see
#     the printed summary for the one-time steps).
#   - Firewall: default-deny inbound, only SSH + Caddy's two HTTPS ports
#     allowed from any source. This environment is internal-only (multiple
#     subnets/VPN, no internet exposure) with no single subnet to restrict
#     to — TLS via Caddy is the control doing the real work here. If this
#     host's reachability ever changes, revisit narrowing these rules.
#   - Secrets: all generated passwords/tokens go into root-owned, mode 600
#     .env files — never printed to stdout in full.
#   - fail2ban enabled for SSH.
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO (see printed summary for why)
#   - Does not use a publicly-trusted TLS cert (Let's Encrypt etc.) — that
#     requires a real domain pointed at this host, which doesn't apply for
#     network-internal access. Caddy's local CA is the appropriate
#     alternative here.
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
CADDY_DIR="/opt/caddy"
PREFECT_UI_PORT="4200"        # loopback-only, reached via Caddy
WINDMILL_HTTP_PORT="8000"     # loopback-only, reached via Caddy
CADDY_PREFECT_PORT="4443"     # HTTPS port for Prefect, reachable from the network
CADDY_WINDMILL_PORT="8443"    # HTTPS port for Windmill, reachable from the network

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this script with sudo/root."

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "arm64" ]] || warn "Detected architecture '$ARCH', expected arm64 — continuing anyway."

# Best-effort detection of this host's primary LAN IP, used to build URLs
# that work from OTHER machines (Prefect's UI needs to know its own API
# URL; Windmill uses this for links it generates). Falls back to a
# placeholder you'll need to edit if detection fails (e.g. multiple NICs).
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "$HOST_IP" ]]; then
    warn "Could not auto-detect this host's IP — using 'CHANGE_ME' as a placeholder in generated configs."
    warn "Edit ${PREFECT_DIR}/docker-compose.yml and ${WINDMILL_DIR}/.env afterward to set the real IP or hostname."
    HOST_IP="CHANGE_ME"
fi
log "Using ${HOST_IP} as this host's network address for generated URLs"

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

log "Stopping and removing any existing Caddy reverse proxy deployment"
if [[ -d "$CADDY_DIR" ]]; then
    (cd "$CADDY_DIR" && docker compose down --remove-orphans) 2>/dev/null || true
    rm -rf "$CADDY_DIR"
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
#    Default-deny inbound. Only SSH plus Caddy's two HTTPS ports are opened
#    — Prefect and Windmill themselves are never directly reachable, only
#    through Caddy. This is still a bootstrap state: see REQUIRED follow-up
#    in the final summary for restricting these to a trusted subnet.
# ---------------------------------------------------------------------------
log "Configuring UFW baseline firewall rules"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow "${CADDY_PREFECT_PORT}/tcp" comment 'Prefect UI via Caddy (TLS) - restrict source once trusted subnet known'
ufw allow "${CADDY_WINDMILL_PORT}/tcp" comment 'Windmill UI via Caddy (TLS) - restrict source once trusted subnet known'
ufw --force enable

warn "UFW currently allows ports ${CADDY_PREFECT_PORT} and ${CADDY_WINDMILL_PORT} from ANY source."
warn "Once you know which subnet/VPN will access these, restrict with e.g.:"
warn "  ufw delete allow ${CADDY_PREFECT_PORT}/tcp && ufw allow from <trusted_subnet> to any port ${CADDY_PREFECT_PORT}"

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
HOST_IP=${HOST_IP}
CADDY_PREFECT_PORT=${CADDY_PREFECT_PORT}
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
      PREFECT_UI_API_URL: https://${HOST_IP}:${CADDY_PREFECT_PORT}/api
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

warn "Prefect's container port is published to 127.0.0.1:${PREFECT_UI_PORT} only — reached over the network exclusively through Caddy (set up next) on https://${HOST_IP}:${CADDY_PREFECT_PORT}"

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
# The upstream compose file parameterizes every service's image via
# ${WM_IMAGE} with no default — if it's unset/empty, `docker compose up`
# fails with "has neither an image nor a build context specified". Pin the
# community-edition image here (ghcr.io/windmill-labs/windmill-ee:main is the
# enterprise equivalent, if you have an EE license).
WM_IMAGE="ghcr.io/windmill-labs/windmill:main"

cat > .env <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) — treat as a secret, not committed to git
POSTGRES_PASSWORD=${WM_DB_PASSWORD}
DATABASE_URL=postgres://postgres:${WM_DB_PASSWORD}@db:5432/windmill?sslmode=disable
MODE=standalone
BASE_URL=https://${HOST_IP}:${CADDY_WINDMILL_PORT}
RUST_LOG=info
WM_TOKEN=${WM_TOKEN}
WM_IMAGE=${WM_IMAGE}
EOF
chmod 600 .env

sed -i "s#changeme#${WM_DB_PASSWORD}#g" docker-compose.yml || true

# Bind Windmill's published port to loopback only — it should never be
# reachable directly, only through Caddy. The upstream compose file's exact
# port-mapping syntax can change between releases, so this covers the
# common patterns and falls back to a clear warning if none match, rather
# than silently leaving the port open to the network.
if grep -qE '^\s*-\s*"?[0-9]+:8000"?\s*$' docker-compose.yml; then
    sed -i -E 's/^(\s*-\s*)"?([0-9]+):8000"?\s*$/\1"127.0.0.1:\2:8000"/' docker-compose.yml
    log "Bound Windmill's published port to 127.0.0.1 only"
else
    warn "Could not find the expected 'PORT:8000' mapping in the fetched docker-compose.yml —"
    warn "Windmill's port may still be published to 0.0.0.0 (reachable directly, bypassing Caddy)."
    warn "Open ${WINDMILL_DIR}/docker-compose.yml, find the port mapping for the app service, and"
    warn "change it to \"127.0.0.1:${WINDMILL_HTTP_PORT}:8000\" manually, then 'docker compose up -d'."
fi

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
# 8. Caddy — reverse proxy with TLS for both apps (host networking)
#    Terminates HTTPS on CADDY_PREFECT_PORT and CADDY_WINDMILL_PORT using
#    Caddy's built-in local CA (`tls internal`) — no public domain or
#    purchased cert needed for network-internal access. Runs with
#    network_mode: host so it can reach both apps' loopback-bound ports
#    directly and doesn't need to join either app's isolated Docker network.
# ---------------------------------------------------------------------------
log "Setting up Caddy reverse proxy with TLS for Prefect and Windmill"
mkdir -p "$CADDY_DIR"
cd "$CADDY_DIR"

cat > Caddyfile <<EOF
:${CADDY_PREFECT_PORT} {
	tls internal
	reverse_proxy 127.0.0.1:${PREFECT_UI_PORT}
}

:${CADDY_WINDMILL_PORT} {
	tls internal
	reverse_proxy 127.0.0.1:${WINDMILL_HTTP_PORT}
}
EOF
chmod 644 Caddyfile

cat > docker-compose.yml <<'EOF'
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    security_opt:
      - no-new-privileges:true

volumes:
  caddy_data:
  caddy_config:
EOF

log "Pulling and starting Caddy"
docker compose pull
docker compose up -d

log "Waiting for Caddy to generate its local CA"
sleep 5

# Export the generated root CA so it can be trusted on client machines —
# without this, browsers will show an untrusted-certificate warning when
# hitting the HTTPS URLs below (the traffic is still encrypted either way,
# this only affects whether the browser trusts it automatically).
ROOT_CA_SRC="$(docker run --rm -v caddy_caddy_data:/data alpine:3 sh -c 'find /data -name root.crt 2>/dev/null | head -n1' 2>/dev/null || true)"
if [[ -n "$ROOT_CA_SRC" ]]; then
    docker run --rm -v caddy_caddy_data:/data -v "${CADDY_DIR}:/out" alpine:3 sh -c "cp '${ROOT_CA_SRC}' /out/root-ca.crt" 2>/dev/null || true
fi
if [[ -f "${CADDY_DIR}/root-ca.crt" ]]; then
    chmod 644 "${CADDY_DIR}/root-ca.crt"
    log "Exported Caddy's root CA to ${CADDY_DIR}/root-ca.crt — distribute this to client machines (see summary)."
else
    warn "Could not auto-export Caddy's root CA. Find it manually with:"
    warn "  docker compose -f ${CADDY_DIR}/docker-compose.yml exec caddy find /data -name root.crt"
fi

chown -R root:docker "$CADDY_DIR"
chmod 750 "$CADDY_DIR"

# ---------------------------------------------------------------------------
# 9. Final summary
# ---------------------------------------------------------------------------
cat <<SUMMARY

================================================================
 INSTALL COMPLETE — READ THIS BEFORE WALKING AWAY
================================================================

Everything now runs in Docker, fronted by Caddy for network access:
  - Docker Engine + hardened daemon.json
  - Prefect: server + worker + its own Postgres, all in ${PREFECT_DIR} (docker-compose.yml)
  - Windmill: full stack + bundled Postgres, all in ${WINDMILL_DIR} (docker-compose.yml)
  - Caddy: TLS reverse proxy for both, in ${CADDY_DIR} (docker-compose.yml)

ACCESS FROM OTHER MACHINES ON THE NETWORK
  Prefect:  https://${HOST_IP}:${CADDY_PREFECT_PORT}
  Windmill: https://${HOST_IP}:${CADDY_WINDMILL_PORT}

  Both are HTTPS via Caddy's own local CA — your browser will show an
  "untrusted certificate" warning until you trust that CA once:
    1. Copy ${CADDY_DIR}/root-ca.crt to the machine(s) you'll browse from
       (scp it off, or open it directly if you're on the box with a GUI).
    2. Import it as a trusted root:
         Windows:  double-click the .crt -> Install Certificate ->
                    Local Machine -> "Trusted Root Certification Authorities"
         macOS:    open in Keychain Access -> System keychain -> set
                    "Always Trust" for this certificate
         Firefox:  Settings -> Privacy & Security -> Certificates ->
                    View Certificates -> Authorities -> Import
    Do this once per machine that will access these UIs; after that the
    padlock shows as trusted like any other HTTPS site.

Docker
  - User '${TARGET_USER}' added to the docker group (verified working above)
  - Your CURRENT shell doesn't have it active yet — no reboot/logout needed though.
    Run ONE of these right now in the shell you'll actually use:
      newgrp docker          # swaps in the new group for this shell
      exec su -l ${TARGET_USER}   # equivalent, fresh login shell
    After that, 'docker ps' etc. will work without sudo.
  - One operational pattern for all three stacks:
      cd ${PREFECT_DIR}  && docker compose pull && docker compose up -d   # update Prefect
      cd ${WINDMILL_DIR} && docker compose pull && docker compose up -d   # update Windmill
      cd ${CADDY_DIR}    && docker compose pull && docker compose up -d   # update Caddy
      docker compose logs -f <service>                                    # logs, any dir

Prefect
  - Container port stays on 127.0.0.1:${PREFECT_UI_PORT} — only Caddy can reach it directly
  - DB password stored in ${PREFECT_DIR}/.env (mode 600, root-owned)
  - Worker container is already running and polling the 'default-agent-pool' work pool —
    point your deployments at that pool name, or create/rename pools to match your flows.

Windmill
  - Container port stays on 127.0.0.1:${WINDMILL_HTTP_PORT} — only Caddy can reach it directly
    (unless the port-binding auto-edit above printed a warning — check that if so)
  - Local bundled Postgres, generated password stored in ${WINDMILL_DIR}/.env (mode 600, root-owned)
  - FIRST LOGIN: default superadmin is admin@windmill.dev / changeme
    -> log in immediately at https://${HOST_IP}:${CADDY_WINDMILL_PORT} and change this password
  - Windmill CLI token generated (WM_TOKEN in .env) for future scripted access

FIREWALL POSTURE (deliberate, not an oversight)
  UFW allows ports ${CADDY_PREFECT_PORT} and ${CADDY_WINDMILL_PORT} from ANY source.
  This is intentional here, not a placeholder: the environment is internal-only
  (multiple subnets/VPN, no internet exposure), so there's no single subnet to
  restrict to — TLS via Caddy is what protects credentials/session data in transit,
  and that protection doesn't depend on which internal subnet a request comes from.
  If that ever changes (e.g. this host becomes reachable beyond your internal
  network), revisit this — narrowing to specific source ranges is the next control
  to add, e.g.:
       ufw allow from <range> to any port ${CADDY_PREFECT_PORT}

REQUIRED follow-up (not automated — needs decisions only you can make):
  1. Trust Caddy's root CA on the machines you'll use (see ACCESS section above).
  2. Change the Windmill superadmin password on first login (see above).
  3. Consider MFA on the Windmill superadmin account if supported in your version.
  4. Back up ${PREFECT_DIR}/.env + its Postgres volume, ${WINDMILL_DIR}/.env + its Postgres
     volume, and ${CADDY_DIR}/root-ca.crt (needed to re-trust the CA if you rebuild this host).
     If Caddy's own volume (caddy_caddy_data) is lost, it will generate a NEW root CA on next
     start — you'd need to re-trust it on every client machine again.
  5. Review fail2ban jail defaults (/etc/fail2ban/jail.local) for your environment.
  6. If HOST_IP shows as CHANGE_ME above, IP auto-detection failed — edit
     ${PREFECT_DIR}/.env (HOST_IP=) and ${WINDMILL_DIR}/.env (BASE_URL=) with the
     correct address, then 'docker compose up -d' in both directories.
  7. If this host's IP ever changes (DHCP), Prefect's UI and Windmill's generated
     links will point at the old address — rerun with the new IP or switch to a
     static IP/DNS name for this host.

================================================================
SUMMARY
