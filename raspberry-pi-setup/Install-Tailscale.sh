#!/usr/bin/env bash
#
# Install Tailscale and configure this Raspberry Pi as an IPv4 /24 subnet router.
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    printf 'ERROR: Run this script as root: sudo bash ./%s\n' "$(basename "$0")" >&2
    exit 1
fi

LOG="/var/log/install-tailscale.log"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; printf "\nERROR: Script failed at line %s (exit %s). See %s\n" "$LINENO" "$rc" "$LOG"; exit "$rc"' ERR

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

AUTH_KEY_FILE=""
SYSCTL_FILE="/etc/sysctl.d/99-tailscale-subnet-router.conf"

log "Starting Tailscale subnet-router setup."
cleanup_auth_key() {
    if [[ -n "${AUTH_KEY_FILE:-}" && -f "$AUTH_KEY_FILE" ]]; then
        rm -f -- "$AUTH_KEY_FILE"
    fi
}
trap cleanup_auth_key EXIT

if ! command -v ip >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 python3 ca-certificates curl
fi

DEFAULT_IFACE="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
[[ -n "$DEFAULT_IFACE" ]] || die "Could not detect the default IPv4 network interface."
IP_CIDR="$(ip -o -4 address show dev "$DEFAULT_IFACE" scope global | awk 'NR == 1 {print $4}')"
[[ -n "$IP_CIDR" ]] || die "Could not detect a global IPv4 address on $DEFAULT_IFACE."
LAN_CIDR="$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$IP_CIDR")"
[[ "${LAN_CIDR##*/}" == "24" ]] || die "Detected LAN $LAN_CIDR is not /24. This installer intentionally supports /24 only."

if [[ -e "$SYSCTL_FILE" ]]; then
    grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$SYSCTL_FILE" &&
    grep -Eq '^[[:space:]]*net\.ipv6\.conf\.all\.forwarding[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$SYSCTL_FILE" ||
        die "$SYSCTL_FILE exists but lacks required forwarding settings; it was not overwritten."
else
    cat > "$SYSCTL_FILE" <<'SYSCTL'
# IP forwarding required for Tailscale subnet routing.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
    chmod 644 "$SYSCTL_FILE"
fi

sysctl --system
[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || die "IPv4 forwarding is not enabled."
[[ "$(sysctl -n net.ipv6.conf.all.forwarding)" == "1" ]] || die "IPv6 forwarding is not enabled."

if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled
systemctl is-active --quiet tailscaled || die "tailscaled is not active."

STATUS_JSON="$(tailscale status --json 2>/dev/null || true)"
BACKEND_STATE="$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys; 
try: print(json.load(sys.stdin).get("BackendState",""))
except (json.JSONDecodeError,AttributeError): print("")')"

if [[ "$BACKEND_STATE" == "Running" ]]; then
    log "Tailscale is already authenticated; no auth key is needed."
    tailscale set --accept-routes=true --advertise-routes="$LAN_CIDR"
else
    [[ -r /dev/tty ]] || die "Tailscale needs an auth key, but no interactive terminal is available. Run this script from an interactive terminal."
    printf '\nA one-time Tailscale authentication key is required for this device.\n' > /dev/tty
    printf 'Paste the key (input is hidden): ' > /dev/tty
    IFS= read -r -s AUTH_KEY </dev/tty || die "Could not read the Tailscale authentication key."
    printf '\n' > /dev/tty
    [[ -n "$AUTH_KEY" ]] || die "No Tailscale authentication key was entered."

    umask 077
    AUTH_KEY_FILE="$(mktemp /run/tailscale-authkey.XXXXXX)"
    chown root:root "$AUTH_KEY_FILE"
    chmod 600 "$AUTH_KEY_FILE"
    printf '%s' "$AUTH_KEY" > "$AUTH_KEY_FILE"
    unset AUTH_KEY

    tailscale up --auth-key="file:$AUTH_KEY_FILE" --accept-routes=true --advertise-routes="$LAN_CIDR"
    rm -f -- "$AUTH_KEY_FILE"
    AUTH_KEY_FILE=""
    log "Tailscale authentication completed; the temporary key file was deleted."
fi

log "Tailscale status:"
tailscale status
log "Subnet route configured: $LAN_CIDR"
log "ACTION REQUIRED: Approve this advertised subnet route in the Tailscale admin console:"
log "https://login.tailscale.com/admin/machines"
log "No reboot was performed."
