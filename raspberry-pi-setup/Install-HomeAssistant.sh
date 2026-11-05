#!/usr/bin/env bash
#
# Install Docker Engine/Compose and deploy Home Assistant Container.
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    printf 'ERROR: Run this script as root: sudo bash ./%s\n' "$(basename "$0")" >&2
    exit 1
fi

LOG="/var/log/install-homeassistant.log"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; printf "\nERROR: Script failed at line %s (exit %s). See %s\n" "$LINENO" "$rc" "$LOG"; exit "$rc"' ERR

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] ||
    die "Run this script with sudo from the normal user account so the target user can be identified."
TARGET_USER="$SUDO_USER"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Could not determine the home directory for $TARGET_USER."

HA_DIR="$TARGET_HOME/homeassistant"
CONFIG_DIR="$HA_DIR/config"
COMPOSE_FILE="$HA_DIR/compose.yaml"
DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
DOCKER_SOURCE="/etc/apt/sources.list.d/docker.sources"

. /etc/os-release
OS_CODENAME="${VERSION_CODENAME:-}"
[[ -n "$OS_CODENAME" ]] || die "Could not determine the OS release codename."
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in arm64|armhf) ;; *) die "Unsupported architecture: $ARCH";; esac
case "${ID:-}" in raspbian|debian) ;; *) die "Expected Raspberry Pi OS or Debian; detected ID=${ID:-unknown}.";; esac

# Docker's current Debian repository publishes armhf packages for ARMv7.
# Restrict this installer to current Debian/Raspberry Pi OS releases.
case "$OS_CODENAME" in bookworm|trixie) ;; *) die "This installer supports Bookworm and Trixie only; detected $OS_CODENAME.";; esac

log "Target user: $TARGET_USER"
log "OS: ${PRETTY_NAME:-$ID} / $OS_CODENAME; architecture: $ARCH"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl

CONFLICTS=()
for package in docker.io docker-doc docker-compose podman-docker containerd runc; do
    if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
        CONFLICTS+=("$package")
    fi
done
if (("${#CONFLICTS[@]}")); then
    die "Conflicting packages are installed: ${CONFLICTS[*]}. No packages were removed; review the existing container host first."
fi

install -d -m 0755 /etc/apt/keyrings
if [[ ! -f "$DOCKER_KEYRING" ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg -o "$DOCKER_KEYRING"
    chmod 0644 "$DOCKER_KEYRING"
fi

if [[ ! -f "$DOCKER_SOURCE" ]]; then
    cat > "$DOCKER_SOURCE" <<REPO
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $OS_CODENAME
Components: stable
Architectures: $ARCH
Signed-By: $DOCKER_KEYRING
REPO
    chmod 0644 "$DOCKER_SOURCE"
else
    grep -q 'download.docker.com/linux/debian' "$DOCKER_SOURCE" ||
        die "$DOCKER_SOURCE exists but is not Docker's Debian repository; it was not overwritten."
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now containerd
systemctl enable --now docker
systemctl is-active --quiet containerd || die "containerd is not active."
systemctl is-active --quiet docker || die "Docker is not active."

getent group docker >/dev/null || groupadd docker
usermod -aG docker "$TARGET_USER"
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
log "The user must log out and back in for docker group membership to apply."
log "No reboot was performed."
