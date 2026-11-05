# Raspberry Pi Setup Scripts

Bash setup and maintenance scripts for Raspberry Pi OS. Each installer displays output in the terminal and appends the same output to a protected log file.

## Scripts

| Script | Purpose | Log |
|---|---|---|
| `Install-RaspberryPi.sh` | Master installer: Home Assistant, private Samba share, and the eight requested dashboard JavaScript files | `/var/log/install-raspberrypi.log` |
| `Remove-Cups.sh` | Stop and remove CUPS services and installed CUPS/printer-driver packages | `/var/log/remove-cups.log` |
| `Install-Tailscale.sh` | Configure the Pi as a Tailscale IPv4 /24 subnet router | `/var/log/install-tailscale.log` |
| `Install-HomeAssistant.sh` | Install Docker Engine/Compose and deploy Home Assistant Container | `/var/log/install-homeassistant.log` |

## Master installation

Clone the authorized repository and run the master installer from the setup directory:

```bash
git clone https://github.com/Demosthine/SchneiderXW.git
cd SchneiderXW/raspberry-pi-setup
sudo bash ./Install-RaspberryPi.sh
```

The master installer:

1. Runs the maintained `Install-HomeAssistant.sh` script.
2. Installs Git, Samba, and ACL utilities.
3. Creates a private `HomeAssistant` Samba share for the invoking Linux user. On first setup, it prompts for a Samba password; an existing Samba account and password are preserved.
4. Clones the eight dashboard-card repositories from GitHub and installs their JavaScript files under `~/homeassistant/config/www/`.
5. Backs up any card files it replaces under `/var/backups/`.
6. Restarts Home Assistant, detects the Pi's LAN IPv4 address, and displays the IP-based Home Assistant URL and Windows UNC share path.

The master installer does not pull Home Assistant configuration templates in this version. That feature will be added in a later update. It does not run the CUPS removal or Tailscale installer.

### Dashboard resources

After Home Assistant onboarding, add each resource under **Settings → Dashboards → Resources**. Set each resource type to **JavaScript Module**.

| Resource URL |
|---|
| `/local/bubble-card.js` |
| `/local/gauge-card-pro.js` |
| `/local/kiosk-mode.js` |
| `/local/layout-card.js` |
| `/local/mushroom.js` |
| `/local/plotly-graph-card/plotly-graph-card.js` |
| `/local/power-flow-card-plus.js` |
| `/local/wallpanel.js` |

The JavaScript files are installed automatically, but Home Assistant dashboard resource registration remains a manual step. The installer cannot safely assume whether the dashboard is using storage mode or YAML mode.

### Samba access from Windows

Use the UNC path printed by the installer, in this form:

```text
\\<raspberry-pi-ip>\HomeAssistant
```

Sign in with the Linux username that ran the installer and the Samba password. The share is authenticated and private. The installer uses ACLs and Samba masks; it does not use world-writable `777` permissions.

## Individual scripts

Run scripts with Bash, not `sh`:

```bash
sudo bash ./Install-HomeAssistant.sh
sudo bash ./Install-Tailscale.sh
sudo bash ./Remove-Cups.sh
```

### Remove CUPS

Stops/disables CUPS services and sockets, purges installed CUPS-related and printer-driver packages, removes CUPS configuration/log/cache directories, and verifies removal.

**Important:** `apt-get autoremove -y` may remove other packages APT considers unused. Review package dependencies and system state first. The script does not remove `/var/spool/cups`, which may contain print queue data. This is a separate, potentially destructive maintenance action and is not run by the master installer.

### Install Tailscale subnet routing

Before running the script, create a Tailscale auth key and store it in the root-only file `/root/tailscale-authkey`. Do not place the key in the script or commit it to Git. Set ownership to root and permissions to 600.

The installer detects the default IPv4 interface and LAN subnet, and stops unless the subnet is /24. It enables IPv4/IPv6 forwarding, installs Tailscale if needed, and authenticates using the protected key file. If the node is already connected, it updates only the requested preferences.

**Manual step:** Approve the advertised subnet route in the Tailscale admin console unless your tailnet policy automatically approves it: https://login.tailscale.com/admin/machines

Remove the key file after enrollment if it is no longer needed.

### Install Home Assistant Container

Run from the normal user account using sudo. The script identifies the invoking user, updates the OS, installs Docker Engine and Compose from Docker's Debian APT repository, enables Docker/containerd, adds that user to the docker group, and deploys Home Assistant.

Home Assistant data is stored under `~/homeassistant/` with `compose.yaml` and a persistent `config/` directory. The Compose service uses host networking, privileged mode, read-only localtime and D-Bus mounts, the stable Home Assistant image, restart unless-stopped, and the `America/Phoenix` timezone.

**Security:** Membership in the docker group effectively grants root-level control of the host. Add only trusted users. Log out and back in before expecting new group membership to apply.

The script does not automatically remove conflicting Docker/containerd packages or overwrite an existing Compose file. It supports Bookworm and Trixie, on arm64 or armhf, and stops on other detected releases or architectures.

## Requirements, logging, and validation

- Raspberry Pi OS or Debian Bookworm/Trixie on arm64 or armhf.
- Bash, sudo access, and internet access during installation.
- Review each script and its effects before running it.
- The scripts do not reboot the Pi automatically.

Logs are created under `/var/log` with mode 600. Run syntax checks:

```bash
bash -n Install-RaspberryPi.sh
bash -n Remove-Cups.sh
bash -n Install-Tailscale.sh
bash -n Install-HomeAssistant.sh
```

A successful `bash -n` check verifies shell syntax only. It does not install packages, authenticate Tailscale, deploy Home Assistant, or prove operation on Raspberry Pi hardware. The master installer has not been integration-tested on a physical Raspberry Pi as part of this release.

## Official references

- [Tailscale up command](https://tailscale.com/docs/reference/tailscale-cli/up)
- [Tailscale subnet routers](https://tailscale.com/docs/features/subnet-routers)
- [Docker Engine installation on Debian](https://docs.docker.com/engine/install/debian/)
- [Docker Engine installation on Raspberry Pi OS](https://docs.docker.com/engine/install/raspberry-pi-os/)
- [Home Assistant Container installation](https://www.home-assistant.io/installation/linux/)
- [Home Assistant dashboard resources](https://www.home-assistant.io/dashboards/dashboards/)
