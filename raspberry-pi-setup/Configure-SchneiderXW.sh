#!/usr/bin/env bash
#
# Configure Home Assistant YAML directories and SchneiderXW recorder settings.
# Existing inline configuration and single-file includes are migrated, not discarded.
#
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    printf 'ERROR: Run this script as root: sudo bash ./%s\n' "$(basename "$0")" >&2
    exit 1
fi

LOG="/var/log/configure-schneiderxw.log"
install -d -m 0755 "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; printf "\nERROR: SchneiderXW configuration failed at line %s (exit %s). See %s\n" "$LINENO" "$rc" "$LOG"; exit "$rc"' ERR

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] ||
    die "Run this script with sudo from the normal user account."
TARGET_USER="$SUDO_USER"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Could not determine the home directory for $TARGET_USER."

HA_DIR="$TARGET_HOME/homeassistant"
CONFIG_DIR="$HA_DIR/config"
CONFIG_YAML="$CONFIG_DIR/configuration.yaml"
COMPOSE_FILE="$HA_DIR/compose.yaml"
[[ -d "$CONFIG_DIR" && -f "$CONFIG_YAML" && -f "$COMPOSE_FILE" ]] ||
    die "Home Assistant config or Compose file was not found. Run the main installer first."
docker compose -f "$COMPOSE_FILE" ps --status running --services | grep -Fxq homeassistant ||
    die "The Home Assistant container is not running."

declare -A INCLUDE_METHOD=(
    [Automations]="merge_list"
    [InputBooleans]="merge_named"
    [InputSelects]="merge_named"
    [ModBus503]="merge_list"
    [Scripts]="merge_named"
    [Templates]="merge_list"
)
declare -A CONFIG_KEY=(
    [Automations]="automation"
    [InputBooleans]="input_boolean"
    [InputSelects]="input_select"
    [ModBus503]="modbus"
    [Scripts]="script"
    [Templates]="template"
)

for folder in Automations InputBooleans InputSelects ModBus503 Scripts Templates; do
    install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" -m 0755 "$CONFIG_DIR/$folder"
done

BACKUP="$CONFIG_YAML.backup.schneiderxw.$(date +%Y%m%d-%H%M%S)"
cp -a "$CONFIG_YAML" "$BACKUP"
log "Backed up configuration.yaml to $BACKUP."

# The editor changes only the six requested top-level sections and recorder settings.
# It preserves unrelated YAML text and migrates existing inline sections or !include files.
python3 - "$CONFIG_DIR" "$CONFIG_YAML" <<'PY'
import os
import re
import shutil
import sys
from pathlib import Path

config_dir = Path(sys.argv[1]).resolve()
config_file = Path(sys.argv[2]).resolve()
text = config_file.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)

folders = {
    "automation": ("Automations", "merge_list", "automations.yaml", "list"),
    "input_boolean": ("InputBooleans", "merge_named", "input_booleans.yaml", "mapping"),
    "input_select": ("InputSelects", "merge_named", "input_selects.yaml", "mapping"),
    "modbus": ("ModBus503", "merge_list", "modbus.yaml", "list"),
    "script": ("Scripts", "merge_named", "scripts.yaml", "mapping"),
    "template": ("Templates", "merge_list", "templates.yaml", "list"),
}

def section_bounds(key):
    pattern = re.compile(rf"^{re.escape(key)}\s*:(.*?)(?:\r?\n)?$")
    found = [i for i, line in enumerate(lines) if pattern.match(line)]
    if len(found) > 1:
        raise RuntimeError(f"configuration.yaml contains multiple top-level {key}: sections; refusing to guess.")
    if not found:
        return None
    start = found[0]
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*\s*:", lines[i]):
            end = i
            break
    return start, end

def save_migrated(key, folder, default_name, shape):
    bounds = section_bounds(key)
    dest_dir = config_dir / folder
    dest_dir.mkdir(exist_ok=True)
    if bounds is None:
        # Migrate a conventional standalone file if present, then add the directory include.
        existing = config_dir / default_name
        if existing.is_file():
            destination = dest_dir / default_name
            if destination.exists():
                raise RuntimeError(f"Both {existing} and {destination} exist; resolve this duplicate manually.")
            shutil.move(str(existing), str(destination))
        if lines and not lines[-1].endswith("\\n"):
            lines[-1] += "\\n"
        if lines and lines[-1].strip():
            lines.append("\\n")
        method = "merge_list" if shape == "list" else "merge_named"
        lines.append(f"{key}: !include_dir_{method} {folder}/\\n")
        return

    start, end = bounds
    header = lines[start]
    value = re.sub(rf"^{re.escape(key)}\s*:", "", header, count=1).strip()
    body = lines[start + 1:end]

    expected = f"!include_dir_{'merge_list' if shape == 'list' else 'merge_named'} {folder}/"
    if value == expected:
        return

    # If already pointing to a directory include, do not silently combine two directories.
    if value.startswith("!include_dir_"):
        raise RuntimeError(f"{key}: already uses a different directory include ({value}); merge its files manually into {folder}/.")

    # Move a referenced single-file include into the new directory.
    include_match = re.fullmatch(r"!include\s+['\"]?([^'\"\s]+)['\"]?", value)
    if include_match:
        source = (config_dir / include_match.group(1)).resolve()
        if config_dir not in source.parents:
            raise RuntimeError(f"{key}: include path {include_match.group(1)} is outside the Home Assistant config directory.")
        if not source.is_file():
            raise RuntimeError(f"{key}: referenced include file does not exist: {source}")
        destination = dest_dir / source.name
        if destination.exists():
            raise RuntimeError(f"{key}: both {source} and {destination} exist; refusing to overwrite.")
        shutil.move(str(source), str(destination))
    elif value.startswith("!include"):
        raise RuntimeError(f"{key}: unsupported include directive {value}; migrate it manually before rerunning.")
    else:
        # Preserve inline YAML by extracting the section's value and de-indenting
        # exactly one top-level indentation level.
        content_lines = []
        if value:
            content_lines.append(value + "\n")
        for line in body:
            if line.startswith("  "):
                content_lines.append(line[2:])
            elif line.strip() == "":
                content_lines.append(line)
            else:
                raise RuntimeError(f"{key}: encountered an unexpected unindented line; refusing an unsafe migration.")
        content = "".join(content_lines)
        if not content.strip():
            content = "[]\n" if shape == "list" else "{}\n"
        destination = dest_dir / f"migrated-from-configuration.yaml"
        if destination.exists():
            raise RuntimeError(f"{key}: migration target already exists: {destination}")
        destination.write_text(content, encoding="utf-8")

    lines[start:end] = [f"{key}: {expected}\n"]

# Migrate six sections. The order is stable and independent of dictionary order.
for key in ("automation", "input_boolean", "input_select", "modbus", "script", "template"):
    folder, method, default_name, shape = folders[key]
    save_migrated(key, folder, default_name, shape)

# Update recorder settings without rewriting unrelated recorder options.
bounds = section_bounds("recorder")
if bounds is None:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    if lines and lines[-1].strip():
        lines.append("\n")
    lines.extend(["recorder:\n", "  purge_keep_days: 7\n", "  commit_interval: 5\n"])
else:
    start, end = bounds
    header_value = re.sub(r"^recorder\s*:", "", lines[start]).strip()
    if header_value:
        raise RuntimeError(f"recorder: expected an inline mapping, found {header_value}; migrate that include manually.")
    block = lines[start:end]
    for setting, value in (("purge_keep_days", "7"), ("commit_interval", "5")):
        matches = [i for i, line in enumerate(block) if re.match(rf"^  {setting}\s*:", line)]
        if len(matches) > 1:
            raise RuntimeError(f"recorder contains duplicate {setting} entries.")
        if matches:
            idx = matches[0]
            ending = "\n" if block[idx].endswith("\n") else ""
            block[idx] = f"  {setting}: {value}{ending}"
        else:
            block.append(f"  {setting}: {value}\n")
    lines[start:end] = block

config_file.write_text("".join(lines), encoding="utf-8")
PY

chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$CONFIG_YAML"
chmod 0644 "$CONFIG_YAML"
# Ensure files created or migrated here remain editable through the authenticated Samba share.
for folder in Automations InputBooleans InputSelects ModBus503 Scripts Templates; do
    chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" "$CONFIG_DIR/$folder"
    setfacl -m "u:$TARGET_USER:rwx" "$CONFIG_DIR/$folder"
    setfacl -d -m "u:$TARGET_USER:rwx" "$CONFIG_DIR/$folder"
done

printf '\nSchneiderXW configuration files are available here:\n'
printf '  https://www.demosthine.com/Schneider\n\n'
printf 'Download the Home Assistant YAML configuration files and place each file in its matching folder:\n'
for folder in Automations InputBooleans InputSelects ModBus503 Scripts Templates; do
    printf '  %s/\n' "$CONFIG_DIR/$folder"
done
printf '\nDo not place these files in the config root. Keep each file in its corresponding folder.\n'

if [[ ! -t 0 ]]; then
    die "A terminal is required to confirm the SchneiderXW files have been downloaded. Run this script interactively."
fi

while true; do
    read -r -p "Have you downloaded and placed the SchneiderXW YAML files in all six folders? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] && break
    printf 'Download and organize the files, then answer Y.\n'
done

missing=0
for folder in Automations InputBooleans InputSelects ModBus503 Scripts Templates; do
    count="$(find "$CONFIG_DIR/$folder" -maxdepth 1 -type f \( -iname '*.yaml' -o -iname '*.yml' \) -size +0c | wc -l)"
    if ((count == 0)); then
        printf 'MISSING: No non-empty YAML file found in %s\n' "$CONFIG_DIR/$folder"
        missing=1
    else
        log "$folder: found $count non-empty YAML file(s)."
    fi
done
((missing == 0)) || die "One or more folders are missing YAML files. Download the files and rerun this script."

log "Validating Home Assistant configuration."
if ! docker compose -f "$COMPOSE_FILE" exec -T homeassistant python -m homeassistant --script check_config --config /config; then
    die "Home Assistant configuration validation failed. The backup is available at $BACKUP. Review the reported YAML errors before restarting."
fi

if [[ "${MASTER_INSTALLER:-0}" == "1" ]]; then
    log "Configuration validated. The master installer will restart Home Assistant after its remaining setup steps."
else
    log "Restarting Home Assistant to load the SchneiderXW configuration."
    docker compose -f "$COMPOSE_FILE" restart homeassistant
    LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [[ -n "$LAN_IP" ]] || LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    ready=0
    for ((attempt=1; attempt<=60; attempt++)); do
        if curl -fsS --max-time 3 "http://$LAN_IP:8123/" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 3
    done
    ((ready)) || die "Home Assistant did not respond after restart. Inspect: docker compose -f \"$COMPOSE_FILE\" logs --tail=100 homeassistant"
fi

log "SchneiderXW Home Assistant configuration completed successfully. No reboot was performed."
