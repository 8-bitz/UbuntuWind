#!/usr/bin/env bash
#
# update-host-ip.sh
# =============================================================================
# PURPOSE
#   Companion script to DockerWindmillPrefect.sh. Re-points the Prefect and
#   Windmill deployments at this host's CURRENT IP address, for use whenever
#   DHCP (or a NIC change, etc.) gives the box a new address.
#
# WHAT ACTUALLY DEPENDS ON THE HOST IP (and what does NOT)
#   - /opt/prefect/.env  -> HOST_IP=...
#       Interpolated directly into /opt/prefect/docker-compose.yml as
#       PREFECT_UI_API_URL: https://${HOST_IP}:${CADDY_PREFECT_PORT}/api
#       This is the one setting that actually breaks when the IP changes —
#       Prefect's UI will keep telling the browser to call the OLD address.
#   - /opt/windmill/.env -> BASE_URL=...
#       Recorded for reference/consistency. As of the current upstream
#       Windmill docker-compose.yml, BASE_URL is not actually wired into the
#       windmill_server container's environment (only DATABASE_URL and MODE
#       are), so this update is precautionary — harmless either way, and
#       correct if a future Windmill compose file starts consuming it.
#   - Caddy (/opt/caddy) -> NOT touched.
#       The Caddyfile listens on ":<port>" and reverse-proxies to
#       127.0.0.1:<port> — no IP address is baked into it, and its local CA
#       cert isn't tied to a specific IP either. No changes needed here.
#   - UFW firewall rules -> NOT touched.
#       Rules are port-based ("allow 4443/tcp"), not source/host-IP-based
#       (unless you've since manually restricted them to a specific subnet —
#       this script does not touch firewall rules at all, so any manual
#       restriction you've applied is left exactly as-is).
#
# USAGE
#   sudo ./update-host-ip.sh              # auto-detect the current IP
#   sudo ./update-host-ip.sh 10.20.30.40   # force a specific IP (e.g. if
#                                          # auto-detection picks the wrong
#                                          # NIC on a multi-homed box)
#
# WHAT IT DOES
#   1. Detects (or accepts) the new IP.
#   2. Reads the OLD HOST_IP out of /opt/prefect/.env.
#   3. If unchanged, does nothing (unless --force is passed).
#   4. Updates HOST_IP in /opt/prefect/.env and BASE_URL in
#      /opt/windmill/.env.
#   5. Runs `docker compose up -d` in both directories so the changed
#      config actually takes effect (Compose recreates only the containers
#      whose resolved config actually changed — this is a normal,
#      non-destructive operation, no data is lost).
#   6. Prints the new access URLs.
# =============================================================================

set -euo pipefail

PREFECT_DIR="/opt/prefect"
WINDMILL_DIR="/opt/windmill"
FORCE=0

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this script with sudo/root (it edits root-owned 600 .env files)."

# ---------------------------------------------------------------------------
# Parse args: optional explicit IP, optional --force
# ---------------------------------------------------------------------------
NEW_IP=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) NEW_IP="$arg" ;;
    esac
done

if [[ -z "$NEW_IP" ]]; then
    NEW_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -n "$NEW_IP" ]] || die "Could not auto-detect an IP and none was given. Usage: sudo ./update-host-ip.sh <new-ip>"

# Very loose sanity check — catches typos, not a full validator
[[ "$NEW_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "'${NEW_IP}' doesn't look like an IPv4 address."

[[ -f "${PREFECT_DIR}/.env" ]] || die "${PREFECT_DIR}/.env not found — has DockerWindmillPrefect.sh been run on this host?"
[[ -f "${WINDMILL_DIR}/.env" ]] || die "${WINDMILL_DIR}/.env not found — has DockerWindmillPrefect.sh been run on this host?"

# ---------------------------------------------------------------------------
# Read current values
# ---------------------------------------------------------------------------
OLD_IP="$(grep -E '^HOST_IP=' "${PREFECT_DIR}/.env" | head -n1 | cut -d= -f2- || true)"
CADDY_PREFECT_PORT="$(grep -E '^CADDY_PREFECT_PORT=' "${PREFECT_DIR}/.env" | head -n1 | cut -d= -f2- || true)"
[[ -n "$OLD_IP" ]] || die "Could not find HOST_IP= in ${PREFECT_DIR}/.env"
[[ -n "$CADDY_PREFECT_PORT" ]] || die "Could not find CADDY_PREFECT_PORT= in ${PREFECT_DIR}/.env"

# Pull the Windmill HTTPS port back out of its existing BASE_URL rather than
# assuming a value, so this script doesn't need to know it separately.
OLD_WM_BASE_URL="$(grep -E '^BASE_URL=' "${WINDMILL_DIR}/.env" | head -n1 | cut -d= -f2- || true)"
CADDY_WINDMILL_PORT="$(echo "$OLD_WM_BASE_URL" | sed -E 's#^https?://[^:]+:([0-9]+).*$#\1#')"
[[ -n "$CADDY_WINDMILL_PORT" ]] || die "Could not determine Windmill's Caddy port from BASE_URL in ${WINDMILL_DIR}/.env"

log "Old HOST_IP: ${OLD_IP}"
log "New HOST_IP: ${NEW_IP}"

if [[ "$OLD_IP" == "$NEW_IP" && "$FORCE" -eq 0 ]]; then
    log "IP hasn't changed — nothing to do. (Pass --force to re-apply anyway.)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Update Prefect's .env (HOST_IP -> feeds PREFECT_UI_API_URL in compose)
# ---------------------------------------------------------------------------
log "Updating ${PREFECT_DIR}/.env"
sed -i "s#^HOST_IP=.*#HOST_IP=${NEW_IP}#" "${PREFECT_DIR}/.env"

# ---------------------------------------------------------------------------
# Update Windmill's .env (BASE_URL — precautionary, see header note above)
# ---------------------------------------------------------------------------
log "Updating ${WINDMILL_DIR}/.env"
sed -i "s#^BASE_URL=.*#BASE_URL=https://${NEW_IP}:${CADDY_WINDMILL_PORT}#" "${WINDMILL_DIR}/.env"

# ---------------------------------------------------------------------------
# Recreate containers whose resolved config changed. `docker compose up -d`
# is safe/non-destructive here: it only recreates containers whose config
# hash actually changed (Prefect's server), and no-ops on the rest.
# ---------------------------------------------------------------------------
log "Re-applying Prefect stack"
(cd "$PREFECT_DIR" && docker compose up -d)

log "Re-applying Windmill stack"
(cd "$WINDMILL_DIR" && docker compose up -d)

log "Done."
cat <<SUMMARY

================================================================
 HOST IP UPDATED: ${OLD_IP} -> ${NEW_IP}
================================================================
New access URLs (from other machines on the network):
  Prefect:  https://${NEW_IP}:${CADDY_PREFECT_PORT}
  Windmill: https://${NEW_IP}:${CADDY_WINDMILL_PORT}

No changes were needed for:
  - Caddy (${CADDY_DIR:-/opt/caddy}) — its config isn't IP-specific, and its
    TLS cert (Caddy's local CA) doesn't need re-trusting because of this.
  - UFW firewall rules — they're port-based, not IP-based.

If DHCP keeps handing this box a new address and that's becoming a problem,
the real fix is a DHCP reservation or a static IP for this host rather than
re-running this script each time.
================================================================
SUMMARY
