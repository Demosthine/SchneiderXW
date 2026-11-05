#!/usr/bin/env bash
#
# Install the complete pinned Plotly Graph Card release in Home Assistant
# Container and register its Lovelace resource.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/PlotlyGraphCard.sh"
[[ -f "$HELPER" ]] || { echo "ERROR: Shared helper not found: $HELPER" >&2; exit 1; }
source "$HELPER"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap 'rc=$?; if ((rc != 0)); then log "ERROR: Plotly installer failed (exit $rc)."; fi' EXIT

for command_name in curl python3 install; do
    command -v "$command_name" >/dev/null 2>&1 || die "Required command is unavailable: $command_name"
done

if [[ "$EUID" -eq 0 ]]; then
    TARGET_USER="${SUDO_USER:-}"
    [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] || die "When run as root, use sudo from the normal Home Assistant owner account."
else
    TARGET_USER="$(id -un)"
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Could not determine home directory for $TARGET_USER."

HA_DIR="$TARGET_HOME/homeassistant"
CONFIG_DIR="$HA_DIR/config"
CONFIG_YAML="$CONFIG_DIR/configuration.yaml"
TARGET_DIR="$CONFIG_DIR/www/plotly-graph-card"
[[ -f "$CONFIG_YAML" ]] || die "Home Assistant configuration not found: $CONFIG_YAML"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/plotly-graph-card.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

log "Downloading all JavaScript assets from $PLOTLY_GRAPH_CARD_REPO release $PLOTLY_GRAPH_CARD_VERSION."
plotly_stage_release "$WORK_DIR/bundle" "$WORK_DIR"

CONFIG_BACKUP=""
if ! grep -Fq -- "- url: $PLOTLY_GRAPH_CARD_RESOURCE" "$CONFIG_YAML"; then
    CONFIG_BACKUP="$CONFIG_YAML.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG_YAML" "$CONFIG_BACKUP"
fi

plotly_install_bundle_atomic "$WORK_DIR/bundle" "$TARGET_DIR" "$TARGET_USER"
if ! plotly_ensure_lovelace_resource "$CONFIG_YAML"; then
    log "Lovelace registration failed. The Plotly bundle remains installed; review configuration.yaml."
    exit 1
fi

log "Installed Plotly Graph Card $PLOTLY_GRAPH_CARD_VERSION with the complete JavaScript bundle."
log "Installation directory: $TARGET_DIR"
log "Lovelace resource: $PLOTLY_GRAPH_CARD_RESOURCE"
[[ -z "$CONFIG_BACKUP" ]] || log "Configuration backup: $CONFIG_BACKUP"
log "Home Assistant was not restarted."
