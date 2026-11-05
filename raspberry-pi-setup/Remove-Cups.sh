#!/usr/bin/env bash
#
# Remove-Cups.sh
# Remove CUPS printing services and installed CUPS/printer-driver packages.
#
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    printf 'ERROR: Run this script as root: sudo bash ./%s\n' "$(basename "$0")" >&2
    exit 1
fi

LOG="/var/log/remove-cups.log"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

trap 'rc=$?; printf "\nERROR: Script failed at line %s (exit %s). See %s\n" "$LINENO" "$rc" "$LOG"; exit "$rc"' ERR

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

installed_cups_packages() {
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 2>/dev/null |
        awk '$2 == "installed" && ($1 ~ /^cups([:-]|$)/ || $1 ~ /^cups-/ || $1 ~ /^printer-driver-/) {print $1}'
}

log "Starting CUPS removal."
log "Log file: $LOG"

SERVICES=(
    cups.service
    cups.socket
    cups.path
    cups-browsed.service
)

for service in "${SERVICES[@]}"; do
    if systemctl list-unit-files "$service" --no-legend 2>/dev/null | grep -q "$service"; then
        log "Stopping and disabling $service."
        systemctl disable --now "$service" || log "NOTICE: Could not stop/disable $service; continuing."
    fi
done

mapfile -t PACKAGES < <(installed_cups_packages)

if ((${#PACKAGES[@]})); then
    log "Purging installed CUPS-related packages:"
    printf '  %s\n' "${PACKAGES[@]}"
    apt-get purge -y "${PACKAGES[@]}"
else
    log "No installed CUPS-related packages were detected."
fi

log "Skipping apt autoremove to avoid removing unrelated packages."

for directory in /etc/cups /var/log/cups /var/cache/cups; do
    if [[ -e "$directory" ]]; then
        log "Removing $directory."
        rm -rf -- "$directory"
    fi
done

mapfile -t REMAINING < <(installed_cups_packages)
if ((${#REMAINING[@]})); then
    log "ERROR: CUPS-related packages remain installed:"
    printf '  %s\n' "${REMAINING[@]}"
    exit 1
fi

if systemctl is-active --quiet cups.service 2>/dev/null ||
   systemctl is-active --quiet cups.socket 2>/dev/null ||
   systemctl is-active --quiet cups-browsed.service 2>/dev/null; then
    log "ERROR: A CUPS service is still active."
    exit 1
fi

log "CUPS removal and verification completed successfully."
log "No reboot was performed."
