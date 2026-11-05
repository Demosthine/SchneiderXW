#!/usr/bin/env bash
#
# Install the eight Home Assistant dashboard JavaScript resources and
# register them in configuration.yaml, without reinstalling Docker,
# Tailscale, Home Assistant, or changing Samba.
#
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    printf 'ERROR: Run this script as root: sudo bash ./%s\n' "$(basename "$0")" >&2
    exit 1
fi

LOG="/var/log/install-ha-dashboard-resources.log"
install -d -m 0755 "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; printf "\nERROR: Dashboard resource installer failed at line %s (exit %s). See %s\n" "$LINENO" "$rc" "$LOG"; exit "$rc"' ERR

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] ||
    die "Run this script with sudo from the normal user account."

TARGET_USER="$SUDO_USER"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] ||
    die "Could not determine the home directory for $TARGET_USER."

for command_name in docker git curl python3; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "Required command is unavailable: $command_name"
done

docker compose version >/dev/null 2>&1 ||
    die "Docker Compose plugin is unavailable."
systemctl is-active --quiet docker ||
    die "Docker is not active."

HA_DIR="$TARGET_HOME/homeassistant"
CONFIG_DIR="$HA_DIR/config"
WWW_DIR="$CONFIG_DIR/www"
COMPOSE_FILE="$HA_DIR/compose.yaml"
CONFIG_YAML="$CONFIG_DIR/configuration.yaml"

[[ -f "$COMPOSE_FILE" ]] || die "Compose file not found: $COMPOSE_FILE"
[[ -f "$CONFIG_YAML" ]] || die "Home Assistant configuration not found: $CONFIG_YAML"

cd "$HA_DIR"
docker compose config --services | grep -Fxq homeassistant ||
    die "The Compose file does not define a homeassistant service."

CONTAINER_ID="$(docker compose ps -q homeassistant)"
[[ -n "$CONTAINER_ID" ]] || die "Home Assistant container is not running."
[[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_ID")" == "true" ]] ||
    die "Home Assistant container is not running."

RESOURCE_URLS=(
    /local/bubble-card.js
    /local/gauge-card-pro.js
    /local/kiosk-mode.js
    /local/layout-card.js
    /local/mushroom.js
    /local/plotly-graph-card/plotly-graph-card.js
    /local/power-flow-card-plus.js
    /local/wallpanel.js
)

HAS_LOVELACE=0
if grep -Eq '^lovelace:' "$CONFIG_YAML"; then
    HAS_LOVELACE=1
    grep -Eq '^[[:space:]]{2}resource_mode:[[:space:]]*yaml([[:space:]]|$)' "$CONFIG_YAML" ||
        die "An existing lovelace: section does not already use resource_mode: yaml. No files or configuration were changed."
    for resource_url in "${RESOURCE_URLS[@]}"; do
        grep -Fq -- "- url: $resource_url" "$CONFIG_YAML" ||
            die "An existing lovelace: section is incomplete ($resource_url is missing). No files or configuration were changed."
    done
    log "Existing YAML Lovelace configuration contains all eight required resources; it will be preserved."
else
    log "No lovelace: section exists. The installer will add YAML resource mode after staging the files."
fi

WORK_DIR="$(mktemp -d /tmp/ha-dashboard-resources.XXXXXX)"
STAGE_DIR="$WORK_DIR/stage"
mkdir -p "$STAGE_DIR"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap 'rc=$?; cleanup; if ((rc != 0)); then printf "\nERROR: Dashboard resource installer failed at line %s (exit %s). See %s\n" "$LINENO" "$rc" "$LOG"; fi; exit "$rc"' ERR
trap cleanup EXIT

install_card() {
    local repo="$1"
    local filename="$2"
    local destination="$3"
    local repo_dir="$WORK_DIR/${repo##*/}"
    local source_file=""

    log "Cloning https://github.com/$repo.git"
    git clone --depth 1 "https://github.com/$repo.git" "$repo_dir"

    source_file="$(find "$repo_dir" -type f -name "$filename" -print -quit || true)"
    if [[ -z "$source_file" ]]; then
        log "Artifact $filename was not in the working tree; checking the latest GitHub release."
        local release_json="$WORK_DIR/${repo##*/}-release.json"
        curl -fsSL -H 'Accept: application/vnd.github+json' \
            "https://api.github.com/repos/$repo/releases/latest" -o "$release_json"

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
    log "Staged $destination"
}

log "Starting dashboard resource installation for $TARGET_USER."

install_card "Clooos/Bubble-Card" "bubble-card.js" "bubble-card.js"
install_card "benjamin-dcs/gauge-card-pro" "gauge-card-pro.js" "gauge-card-pro.js"
install_card "NemesisRE/kiosk-mode" "kiosk-mode.js" "kiosk-mode.js"
install_card "thomasloven/lovelace-layout-card" "layout-card.js" "layout-card.js"
install_card "piitaya/lovelace-mushroom" "mushroom.js" "mushroom.js"
install_card "dbuezas/lovelace-plotly-graph-card" "plotly-graph-card.js" "plotly-graph-card/plotly-graph-card.js"
install_card "flixlix/power-flow-card-plus" "power-flow-card-plus.js" "power-flow-card-plus.js"
install_card "j-a-n/lovelace-wallpanel" "wallpanel.js" "wallpanel.js"

STAGED_COUNT="$(find "$STAGE_DIR" -type f | wc -l)"
[[ "$STAGED_COUNT" -eq 8 ]] || die "Expected eight staged JavaScript files; found $STAGED_COUNT."
log "All eight JavaScript resources were downloaded and verified."

# Preserve any files that will be replaced.
BACKUP_DIR="/var/backups/homeassistant-dashboard-resources-$(date +%Y%m%d-%H%M%S)"
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
    log "$backup_count existing resource file(s) backed up to $BACKUP_DIR."
else
    rmdir "$BACKUP_DIR" 2>/dev/null || true
    BACKUP_DIR=""
fi

CONFIG_BACKUP=""
if ((HAS_LOVELACE == 0)); then
    CONFIG_BACKUP="$CONFIG_YAML.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG_YAML" "$CONFIG_BACKUP"

    {
        printf '\n# Home Assistant dashboard resources managed by Install-HADashboardResources.sh\n'
        printf 'lovelace:\n'
        printf '  resource_mode: yaml\n'
        printf '  resources:\n'
        for resource_url in "${RESOURCE_URLS[@]}"; do
            printf '    - url: %s\n      type: module\n' "$resource_url"
        done
    } >> "$CONFIG_YAML"

    log "Registered all eight resources in configuration.yaml (backup: $CONFIG_BACKUP)."
else
    log "Preserved the existing complete Lovelace resource configuration."
fi

log "Validating Home Assistant configuration."
if ! docker compose exec -T homeassistant \
    python -m homeassistant --script check_config --config /config; then
    if [[ -n "$CONFIG_BACKUP" ]]; then
        cp -a "$CONFIG_BACKUP" "$CONFIG_YAML"
        log "Restored configuration.yaml from $CONFIG_BACKUP."
    fi
    die "Home Assistant configuration validation failed. Home Assistant was not restarted."
fi

log "Home Assistant configuration validation succeeded."
log "Installed dashboard resources:"
find "$WWW_DIR" -type f -printf '  %P (%s bytes)\n' | sort
[[ -z "$CONFIG_BACKUP" ]] || log "Configuration backup: $CONFIG_BACKUP"
[[ -z "$BACKUP_DIR" ]] || log "Resource backup: $BACKUP_DIR"
log "Dashboard resource installation complete. Home Assistant was not restarted."
log "Next step: run Configure-SchneiderXW.sh, validate the complete configuration, then restart Home Assistant once."
