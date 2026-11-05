#!/usr/bin/env bash
#
# Deploy Home Assistant Container after Install-Docker.sh has completed.
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    printf 'ERROR: Run this script as root: sudo bash ./%s\n' "$(basename "$0")" >&2
    exit 1
fi

LOG="/var/log/install-homeassistant.log"
install -d -m 0755 "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; printf "\nERROR: Home Assistant installer failed at line %s (exit %s). See %s\n" "$LINENO" "$rc" "$LOG"; exit "$rc"' ERR

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] ||
    die "Run this script with sudo from the normal user account."
TARGET_USER="$SUDO_USER"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Could not determine the home directory for $TARGET_USER."

command -v docker >/dev/null 2>&1 || die "Docker is not installed. Run sudo bash ./Install-Docker.sh first."
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable. Run Install-Docker.sh first."
systemctl is-active --quiet docker || die "Docker is not active. Run Install-Docker.sh first."

HA_DIR="$TARGET_HOME/homeassistant"
CONFIG_DIR="$HA_DIR/config"
COMPOSE_FILE="$HA_DIR/compose.yaml"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 "$HA_DIR" "$CONFIG_DIR"

if [[ ! -e "$COMPOSE_FILE" ]]; then
    cat > "$COMPOSE_FILE" <<'COMPOSE'
services:
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:stable
    volumes:
      - ./config:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    environment:
      TZ: America/Phoenix
    restart: unless-stopped
    privileged: true
    network_mode: host
COMPOSE
    chown "$TARGET_USER:$TARGET_USER" "$COMPOSE_FILE"
    chmod 0644 "$COMPOSE_FILE"
else
    log "Compose file already exists; it will not be overwritten."
fi

cd "$HA_DIR"
docker compose config --services | grep -Fxq homeassistant ||
    die "The Compose file does not define a homeassistant service; it was not modified."
docker compose pull homeassistant
docker compose up -d homeassistant

CONTAINER_ID="$(docker compose ps -q homeassistant)"
[[ -n "$CONTAINER_ID" ]] || die "Could not find the Home Assistant container."
[[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_ID")" == "true" ]] || {
    docker compose logs --tail=100 homeassistant
    die "Home Assistant container is not running."
}

LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
log "Home Assistant container is running."
docker compose ps
log "Access Home Assistant at: http://${LAN_IP:-<raspberry-pi-ip>}:8123"
log "Configuration directory: $CONFIG_DIR"
log "Compose file: $COMPOSE_FILE"
log "Complete initial onboarding in a browser before continuing with Samba and dashboard resources."
log "No reboot was performed."
