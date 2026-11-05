#!/usr/bin/env bash
#
# Master Raspberry Pi setup:
# - Install Home Assistant using the maintained companion installer.
# - Configure a private Samba share for ~/homeassistant.
# - Clone and install the requested Home Assistant dashboard JavaScript cards.
#
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    printf 'ERROR: Run this script as root: sudo bash ./%s\n' "$(basename "$0")" >&2
    exit 1
fi

LOG="/var/log/install-raspberrypi.log"
install -d -m 0755 "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; printf "\nERROR: Master installer failed at line %s (exit %s). See %s\n" "$LINENO" "$rc" "$LOG"; exit "$rc"' ERR

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] ||
    die "Run this script with sudo from the normal user account."
TARGET_USER="$SUDO_USER"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Could not determine the home directory for $TARGET_USER."
TARGET_GROUP="$(id -gn "$TARGET_USER")"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HA_INSTALLER="$SCRIPT_DIR/Install-HomeAssistant.sh"
[[ -f "$HA_INSTALLER" ]] || die "Install-HomeAssistant.sh must be in the same directory. Clone the SchneiderXW repository and run this script from raspberry-pi-setup/."

. /etc/os-release
case "${ID:-}" in raspbian|debian) ;; *) die "Expected Raspberry Pi OS or Debian; detected ID=${ID:-unknown}.";; esac
case "$(dpkg --print-architecture)" in arm64|armhf) ;; *) die "Unsupported CPU architecture: $(dpkg --print-architecture).";; esac
case "${VERSION_CODENAME:-}" in bookworm|trixie) ;; *) die "This installer currently supports Bookworm and Trixie only; detected ${VERSION_CODENAME:-unknown}.";; esac

HA_DIR="$TARGET_HOME/homeassistant"
CONFIG_DIR="$HA_DIR/config"
WWW_DIR="$CONFIG_DIR/www"
COMPOSE_FILE="$HA_DIR/compose.yaml"

log "Starting Raspberry Pi setup for user $TARGET_USER."
log "The configuration-template pull is intentionally not part of this version."
log "Installing Home Assistant with the existing installer."
SUDO_USER="$TARGET_USER" bash "$HA_INSTALLER"

[[ -d "$CONFIG_DIR" && -f "$COMPOSE_FILE" ]] || die "Home Assistant configuration directory or Compose file is missing after installation."

log "Installing prerequisites for Samba and GitHub repository pulls."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y git curl python3 samba samba-common-bin acl

# Configure a private authenticated share. Never make the Home Assistant tree world-writable.
log "Configuring the private Samba share."
if ! pdbedit -L -u "$TARGET_USER" >/dev/null 2>&1; then
    printf '\nA Samba password is required for Windows network-drive access.\n'
    while true; do
        read -r -s -p "Enter a new Samba password for $TARGET_USER: " SMB_PASSWORD
        printf '\n'
        read -r -s -p "Confirm Samba password: " SMB_PASSWORD_CONFIRM
        printf '\n'
        [[ -n "$SMB_PASSWORD" ]] || { printf 'Password cannot be empty.\n'; continue; }
        [[ "$SMB_PASSWORD" == "$SMB_PASSWORD_CONFIRM" ]] && break
        printf 'Passwords did not match. Try again.\n'
    done
    printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -s -a "$TARGET_USER"
    unset SMB_PASSWORD SMB_PASSWORD_CONFIRM
else
    log "Samba account already exists for $TARGET_USER; keeping its existing password."
fi

# Grant the intended account access using POSIX ACLs; do not use chmod 777.
setfacl -m "u:$TARGET_USER:rwx" "$HA_DIR"
setfacl -d -m "u:$TARGET_USER:rwx" "$HA_DIR"
setfacl -R -m "u:$TARGET_USER:rwX" "$CONFIG_DIR"
while IFS= read -r -d '' directory; do
    setfacl -d -m "u:$TARGET_USER:rwx" "$directory"
done < <(find "$CONFIG_DIR" -type d -print0)

SMB_CONF="/etc/samba/smb.conf"
[[ -f "$SMB_CONF" ]] || die "$SMB_CONF was not found."
SMB_BACKUP="$SMB_CONF.backup.$(date +%Y%m%d-%H%M%S)"
cp -a "$SMB_CONF" "$SMB_BACKUP"

BEGIN_MARKER="# BEGIN MANAGED HOME ASSISTANT SHARE"
END_MARKER="# END MANAGED HOME ASSISTANT SHARE"
TEMP_SMB="$(mktemp)"
awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
' "$SMB_CONF" > "$TEMP_SMB"
if grep -Eiq '^[[:space:]]*\\[HomeAssistant\\][[:space:]]*

$BEGIN_MARKER
[HomeAssistant]
   path = $HA_DIR
   browseable = yes
   read only = no
   guest ok = no
   valid users = $TARGET_USER
   force user = $TARGET_USER
   force group = $TARGET_GROUP
   create mask = 0660
   directory mask = 2770
$END_MARKER
SHARE
install -o root -g root -m 0644 "$TEMP_SMB" "$SMB_CONF"
rm -f "$TEMP_SMB"

if ! testparm -s >/dev/null; then
    cp -a "$SMB_BACKUP" "$SMB_CONF"
    die "Samba configuration validation failed. The previous smb.conf was restored from $SMB_BACKUP."
fi
systemctl enable --now smbd
systemctl restart smbd
systemctl is-active --quiet smbd || die "Samba service is not active."

# Stage all eight repositories and validate every artifact before changing config/www.
log "Cloning the eight Home Assistant dashboard-card repositories."
WORK_DIR="$(mktemp -d /tmp/ha-cards.XXXXXX)"
STAGE_DIR="$WORK_DIR/stage"
mkdir -p "$STAGE_DIR"
cleanup() { rm -rf "$WORK_DIR"; }
trap 'rc=$?; cleanup; if ((rc != 0)); then printf "\nERROR: Master installer failed at line %s (exit %s). See %s\n" "$LINENO" "$rc" "$LOG"; fi; exit "$rc"' ERR
trap cleanup EXIT

install_card() {
    local repo="$1"
    local filename="$2"
    local destination="$3"
    local repo_dir="$WORK_DIR/${repo##*/}"
    local source_file=""

    git clone --depth 1 "https://github.com/$repo.git" "$repo_dir"

    source_file="$(find "$repo_dir" -type f -name "$filename" -print -quit || true)"
    if [[ -z "$source_file" ]]; then
        log "Artifact $filename not present in the cloned working tree; checking the latest GitHub release."
        local release_json="$WORK_DIR/${repo##*/}-release.json"
        curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$repo/releases/latest" -o "$release_json"
        local asset_url
        asset_url="$(python3 - "$release_json" "$filename" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    release = json.load(stream)
for asset in release.get("assets", []):
    if asset.get("name") == sys.argv[2]:
        print(asset.get("browser_download_url", ""))
        break
PY
)"
        [[ -n "$asset_url" ]] || die "Could not find $filename in $repo or its latest release."
        source_file="$WORK_DIR/$filename"
        curl -fsSL "$asset_url" -o "$source_file"
    fi

    [[ -s "$source_file" ]] || die "Downloaded artifact is empty: $repo/$filename"
    install -D -m 0644 "$source_file" "$STAGE_DIR/$destination"
    log "Staged $destination from $repo."
}

install_card "Clooos/Bubble-Card" "bubble-card.js" "bubble-card.js"
install_card "benjamin-dcs/gauge-card-pro" "gauge-card-pro.js" "gauge-card-pro.js"
install_card "NemesisRE/kiosk-mode" "kiosk-mode.js" "kiosk-mode.js"
install_card "thomasloven/lovelace-layout-card" "layout-card.js" "layout-card.js"
install_card "piitaya/lovelace-mushroom" "mushroom.js" "mushroom.js"
install_card "dbuezas/lovelace-plotly-graph-card" "plotly-graph-card.js" "plotly-graph-card/plotly-graph-card.js"
install_card "flixlix/power-flow-card-plus" "power-flow-card-plus.js" "power-flow-card-plus.js"
install_card "j-a-n/lovelace-wallpanel" "wallpanel.js" "wallpanel.js"

# Preserve replaced files before installing the staged set.
BACKUP_DIR="/var/backups/homeassistant-custom-cards-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WWW_DIR"
backup_count=0
while IFS= read -r -d '' staged_file; do
    relative_path="${staged_file#"$STAGE_DIR"/}"
    target_file="$WWW_DIR/$relative_path"
    if [[ -e "$target_file" ]]; then
        install -D -m 0644 "$target_file" "$BACKUP_DIR/$relative_path"
        backup_count=$((backup_count + 1))
    fi
done < <(find "$STAGE_DIR" -type f -print0)

while IFS= read -r -d '' staged_file; do
    relative_path="${staged_file#"$STAGE_DIR"/}"
    install -D -m 0644 "$staged_file" "$WWW_DIR/$relative_path"
    log "Installed /local/$relative_path"
done < <(find "$STAGE_DIR" -type f -print0)

if ((backup_count > 0)); then
    log "$backup_count existing card file(s) were backed up to $BACKUP_DIR before replacement."
fi

# Restart Home Assistant so the new files are present before the user configures resources.
log "Restarting Home Assistant."
cd "$HA_DIR"
docker compose restart homeassistant

LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
if [[ -z "$LAN_IP" ]]; then
    LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -n "$LAN_IP" ]] || die "Could not determine the Raspberry Pi LAN IPv4 address."
HA_URL="http://$LAN_IP:8123"

log "Waiting up to 180 seconds for Home Assistant to respond."
ready=0
for ((attempt=1; attempt<=60; attempt++)); do
    if curl -fsS --max-time 3 "$HA_URL/" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 3
done

printf '\n============================================================\n'
printf 'RASPBERRY PI SETUP FINISHED\n'
printf '============================================================\n'
printf 'Home Assistant: %s\n' "$HA_URL"
printf 'Windows network share: \\\\%s\\HomeAssistant\n' "$LAN_IP"
printf 'Home Assistant files: %s\n' "$HA_DIR"
printf 'Dashboard JavaScript files: %s\n' "$WWW_DIR"
printf 'Master log: %s\n' "$LOG"
printf '\n'
if ((ready)); then
    printf 'Home Assistant is responding. Open the URL above to complete onboarding.\n'
else
    printf 'Home Assistant did not respond within 180 seconds. Check: cd "%s" && docker compose logs --tail=100 homeassistant\n' "$HA_DIR"
fi
printf '\nAfter onboarding, add these resources under Settings > Dashboards > Resources.\n'
printf 'Set each resource type to JavaScript Module.\n'
printf '  /local/bubble-card.js\n'
printf '  /local/gauge-card-pro.js\n'
printf '  /local/kiosk-mode.js\n'
printf '  /local/layout-card.js\n'
printf '  /local/mushroom.js\n'
printf '  /local/plotly-graph-card/plotly-graph-card.js\n'
printf '  /local/power-flow-card-plus.js\n'
printf '  /local/wallpanel.js\n'
printf '\n'
if [[ -t 0 ]]; then
    read -r -p "Complete Home Assistant onboarding in your browser, then press Enter to finish: " _
else
    log "Non-interactive session: complete Home Assistant onboarding manually using $HA_URL."
fi
log "Setup complete. No reboot was performed."
 "$TEMP_SMB"; then
    rm -f "$TEMP_SMB"
    die "An unmanaged [HomeAssistant] Samba share already exists in $SMB_CONF. It was not overwritten; resolve that share before rerunning."
fi
cat >> "$TEMP_SMB" <<SHARE

$BEGIN_MARKER
[HomeAssistant]
   path = $HA_DIR
   browseable = yes
   read only = no
   guest ok = no
   valid users = $TARGET_USER
   force user = $TARGET_USER
   force group = $TARGET_GROUP
   create mask = 0660
   directory mask = 2770
$END_MARKER
SHARE
install -o root -g root -m 0644 "$TEMP_SMB" "$SMB_CONF"
rm -f "$TEMP_SMB"

if ! testparm -s >/dev/null; then
    cp -a "$SMB_BACKUP" "$SMB_CONF"
    die "Samba configuration validation failed. The previous smb.conf was restored from $SMB_BACKUP."
fi
systemctl enable --now smbd
systemctl restart smbd
systemctl is-active --quiet smbd || die "Samba service is not active."

# Stage all eight repositories and validate every artifact before changing config/www.
log "Cloning the eight Home Assistant dashboard-card repositories."
WORK_DIR="$(mktemp -d /tmp/ha-cards.XXXXXX)"
STAGE_DIR="$WORK_DIR/stage"
mkdir -p "$STAGE_DIR"
cleanup() { rm -rf "$WORK_DIR"; }
trap 'rc=$?; cleanup; if ((rc != 0)); then printf "\nERROR: Master installer failed at line %s (exit %s). See %s\n" "$LINENO" "$rc" "$LOG"; fi; exit "$rc"' ERR
trap cleanup EXIT

install_card() {
    local repo="$1"
    local filename="$2"
    local destination="$3"
    local repo_dir="$WORK_DIR/${repo##*/}"
    local source_file=""

    git clone --depth 1 "https://github.com/$repo.git" "$repo_dir"

    source_file="$(find "$repo_dir" -type f -name "$filename" -print -quit || true)"
    if [[ -z "$source_file" ]]; then
        log "Artifact $filename not present in the cloned working tree; checking the latest GitHub release."
        local release_json="$WORK_DIR/${repo##*/}-release.json"
        curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$repo/releases/latest" -o "$release_json"
        local asset_url
        asset_url="$(python3 - "$release_json" "$filename" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    release = json.load(stream)
for asset in release.get("assets", []):
    if asset.get("name") == sys.argv[2]:
        print(asset.get("browser_download_url", ""))
        break
PY
)"
        [[ -n "$asset_url" ]] || die "Could not find $filename in $repo or its latest release."
        source_file="$WORK_DIR/$filename"
        curl -fsSL "$asset_url" -o "$source_file"
    fi

    [[ -s "$source_file" ]] || die "Downloaded artifact is empty: $repo/$filename"
    install -D -m 0644 "$source_file" "$STAGE_DIR/$destination"
    log "Staged $destination from $repo."
}

install_card "Clooos/Bubble-Card" "bubble-card.js" "bubble-card.js"
install_card "benjamin-dcs/gauge-card-pro" "gauge-card-pro.js" "gauge-card-pro.js"
install_card "NemesisRE/kiosk-mode" "kiosk-mode.js" "kiosk-mode.js"
install_card "thomasloven/lovelace-layout-card" "layout-card.js" "layout-card.js"
install_card "piitaya/lovelace-mushroom" "mushroom.js" "mushroom.js"
install_card "dbuezas/lovelace-plotly-graph-card" "plotly-graph-card.js" "plotly-graph-card/plotly-graph-card.js"
install_card "flixlix/power-flow-card-plus" "power-flow-card-plus.js" "power-flow-card-plus.js"
install_card "j-a-n/lovelace-wallpanel" "wallpanel.js" "wallpanel.js"

# Preserve replaced files before installing the staged set.
BACKUP_DIR="/var/backups/homeassistant-custom-cards-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WWW_DIR"
backup_count=0
while IFS= read -r -d '' staged_file; do
    relative_path="${staged_file#"$STAGE_DIR"/}"
    target_file="$WWW_DIR/$relative_path"
    if [[ -e "$target_file" ]]; then
        install -D -m 0644 "$target_file" "$BACKUP_DIR/$relative_path"
        backup_count=$((backup_count + 1))
    fi
done < <(find "$STAGE_DIR" -type f -print0)

while IFS= read -r -d '' staged_file; do
    relative_path="${staged_file#"$STAGE_DIR"/}"
    install -D -m 0644 "$staged_file" "$WWW_DIR/$relative_path"
    log "Installed /local/$relative_path"
done < <(find "$STAGE_DIR" -type f -print0)

if ((backup_count > 0)); then
    log "$backup_count existing card file(s) were backed up to $BACKUP_DIR before replacement."
fi

# Restart Home Assistant so the new files are present before the user configures resources.
log "Restarting Home Assistant."
cd "$HA_DIR"
docker compose restart homeassistant

LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
if [[ -z "$LAN_IP" ]]; then
    LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -n "$LAN_IP" ]] || die "Could not determine the Raspberry Pi LAN IPv4 address."
HA_URL="http://$LAN_IP:8123"

log "Waiting up to 180 seconds for Home Assistant to respond."
ready=0
for ((attempt=1; attempt<=60; attempt++)); do
    if curl -fsS --max-time 3 "$HA_URL/" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 3
done

printf '\n============================================================\n'
printf 'RASPBERRY PI SETUP FINISHED\n'
printf '============================================================\n'
printf 'Home Assistant: %s\n' "$HA_URL"
printf 'Windows network share: \\\\%s\\HomeAssistant\n' "$LAN_IP"
printf 'Home Assistant files: %s\n' "$HA_DIR"
printf 'Dashboard JavaScript files: %s\n' "$WWW_DIR"
printf 'Master log: %s\n' "$LOG"
printf '\n'
if ((ready)); then
    printf 'Home Assistant is responding. Open the URL above to complete onboarding.\n'
else
    printf 'Home Assistant did not respond within 180 seconds. Check: cd "%s" && docker compose logs --tail=100 homeassistant\n' "$HA_DIR"
fi
printf '\nAfter onboarding, add these resources under Settings > Dashboards > Resources.\n'
printf 'Set each resource type to JavaScript Module.\n'
printf '  /local/bubble-card.js\n'
printf '  /local/gauge-card-pro.js\n'
printf '  /local/kiosk-mode.js\n'
printf '  /local/layout-card.js\n'
printf '  /local/mushroom.js\n'
printf '  /local/plotly-graph-card/plotly-graph-card.js\n'
printf '  /local/power-flow-card-plus.js\n'
printf '  /local/wallpanel.js\n'
printf '\n'
if [[ -t 0 ]]; then
    read -r -p "Complete Home Assistant onboarding in your browser, then press Enter to finish: " _
else
    log "Non-interactive session: complete Home Assistant onboarding manually using $HA_URL."
fi
log "Setup complete. No reboot was performed."
