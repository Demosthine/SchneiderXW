# Raspberry Pi Setup Scripts

Bash setup and maintenance scripts for Raspberry Pi OS. Scripts display output in the terminal and append it to protected log files. They do not automatically reboot the Pi.

## Scripts

| Script | Purpose | Log |
|---|---|---|
| `Install-RaspberryPi.sh` | Master workflow: Home Assistant, Samba, optional CUPS removal, conditional Tailscale setup, dashboard JavaScript files, and YAML resource registration | `/var/log/install-raspberrypi.log` |
| `Install-HomeAssistant.sh` | Install Docker Engine/Compose and deploy Home Assistant Container | `/var/log/install-homeassistant.log` |
| `Install-Tailscale.sh` | Configure the Pi as a Tailscale IPv4 /24 subnet router | `/var/log/install-tailscale.log` |
| `Remove-Cups.sh` | Stop and remove CUPS services and installed CUPS/printer-driver packages | `/var/log/remove-cups.log` |

## Master installation

On the Raspberry Pi, clone the authorized repository and run:

```bash
git clone https://github.com/Demosthine/SchneiderXW.git
cd SchneiderXW/raspberry-pi-setup
bash -n Install-RaspberryPi.sh
bash -n Install-HomeAssistant.sh
bash -n Install-Tailscale.sh
bash -n Remove-Cups.sh
sudo bash ./Install-RaspberryPi.sh
```

The master installer:

1. Runs `Install-HomeAssistant.sh` to install Docker and deploy Home Assistant Container.
2. Offers CUPS removal only after an interactive confirmation. CUPS removal uninstalls printing services and printer-driver packages. In a non-interactive run it skips CUPS removal; run `sudo bash ./Remove-Cups.sh` separately if required.
3. Runs `Install-Tailscale.sh` automatically only when `/root/tailscale-authkey` exists and is non-empty. Otherwise it skips Tailscale.
4. Creates a private authenticated Samba share named `HomeAssistant`. On first setup it prompts for a Samba password; an existing Samba account/password is preserved.
5. Clones the eight dashboard-card repositories from GitHub and stages their JavaScript files before installing them under `~/homeassistant/config/www/`.
6. Backs up replaced card files under `/var/backups/`.
7. Adds the eight resources to `configuration.yaml` under `lovelace:`, using `resource_mode: yaml` and `type: module`. It backs up the file before editing and validates the configuration before restarting Home Assistant.
8. Restarts Home Assistant, detects the Pi's LAN IPv4 address, and displays the IP-based Home Assistant URL and Windows UNC share path.

Configuration-template downloads are intentionally deferred. The installer does not change unrelated repository files or perform an automatic reboot.

### CUPS safety

CUPS removal is destructive to printing functionality. The master installer asks before running it. The standalone script can also be run separately.

The CUPS script purges installed CUPS/printer-driver packages, stops and disables CUPS services, removes CUPS configuration/log/cache directories, and verifies removal. It deliberately does **not** run `apt autoremove`, because that operation can remove unrelated packages APT considers unused. It does not remove `/var/spool/cups`, which may contain print queue data.

### Tailscale setup

To have the master installer configure Tailscale, first create an auth key and store it at `/root/tailscale-authkey` with root ownership and mode 600:

```bash
sudo install -o root -g root -m 600 /dev/null /root/tailscale-authkey
sudo nano /root/tailscale-authkey
```

Paste the auth key into the file without adding it to GitHub or the installer. The master script detects the file and runs `Install-Tailscale.sh`. The standalone Tailscale installer detects the default IPv4 interface and LAN subnet, and stops unless the subnet is /24. It enables IPv4/IPv6 forwarding and configures Tailscale to advertise the LAN route.

**Manual step:** Approve the advertised subnet route in the Tailscale admin console unless your tailnet policy automatically approves it: https://login.tailscale.com/admin/machines

Remove the auth key file after enrollment if it is no longer needed. The key file is never copied into the repository.

### Dashboard resources in configuration.yaml

The installer installs these files:

| Resource URL | Installed file |
|---|---|
| `/local/bubble-card.js` | `www/bubble-card.js` |
| `/local/gauge-card-pro.js` | `www/gauge-card-pro.js` |
| `/local/kiosk-mode.js` | `www/kiosk-mode.js` |
| `/local/layout-card.js` | `www/layout-card.js` |
| `/local/mushroom.js` | `www/mushroom.js` |
| `/local/plotly-graph-card/plotly-graph-card.js` | `www/plotly-graph-card/plotly-graph-card.js` |
| `/local/power-flow-card-plus.js` | `www/power-flow-card-plus.js` |
| `/local/wallpanel.js` | `www/wallpanel.js` |

It adds the following structure to `configuration.yaml` when no top-level `lovelace:` section already exists:

```yaml
lovelace:
  resource_mode: yaml
  resources:
    - url: /local/bubble-card.js
      type: module
    - url: /local/gauge-card-pro.js
      type: module
    - url: /local/kiosk-mode.js
      type: module
    - url: /local/layout-card.js
      type: module
    - url: /local/mushroom.js
      type: module
    - url: /local/plotly-graph-card/plotly-graph-card.js
      type: module
    - url: /local/power-flow-card-plus.js
      type: module
    - url: /local/wallpanel.js
      type: module
```

**Existing Lovelace configuration:** The installer will not silently convert an existing storage-mode dashboard or merge into an existing partial Lovelace section. If it finds an existing `lovelace:` section that does not already contain all eight YAML resources, it stops and preserves the file. This avoids silently dropping resources that may be stored in Home Assistant's UI-managed storage. Existing YAML resources must be reviewed and migrated deliberately before rerunning.

Home Assistant's current documentation confirms that YAML-managed resources require `resource_mode: yaml`; the resources are loaded as JavaScript modules. After editing YAML, reload dashboard resources or restart Home Assistant. See [Home Assistant dashboard resources](https://www.home-assistant.io/dashboards/dashboards/) and [reload dashboard resources](https://www.home-assistant.io/actions/lovelace.reload_resources/).

### Samba access from Windows

Use the UNC path printed by the installer, in this form:

```text
\\<raspberry-pi-ip>\HomeAssistant
```

Sign in with the Linux username that ran the installer and the Samba password. The share is private and authenticated. ACLs and Samba masks are used; the installer does not apply world-writable `777` permissions.

## Individual scripts

Run scripts with Bash, not `sh`:

```bash
sudo bash ./Install-HomeAssistant.sh
sudo bash ./Install-Tailscale.sh
sudo bash ./Remove-Cups.sh
```

### Install Home Assistant Container

The script identifies the invoking user, updates the OS, installs Docker Engine and Compose from Docker's Debian APT repository, enables Docker/containerd, adds that user to the docker group, and deploys Home Assistant.

Home Assistant data is stored under `~/homeassistant/` with `compose.yaml` and a persistent `config/` directory. The Compose service uses host networking, privileged mode, read-only localtime and D-Bus mounts, the stable Home Assistant image, restart unless-stopped, and the `America/Phoenix` timezone.

**Security:** Membership in the docker group effectively grants root-level control of the host. Add only trusted users. Log out and back in before expecting new group membership to apply.

The script does not automatically remove conflicting Docker/containerd packages or overwrite an existing Compose file. It supports Bookworm and Trixie, on arm64 or armhf, and stops on other detected releases or architectures.

## Connect from Windows for validation

The simplest validation path is SSH from Windows Terminal or PowerShell. Keep the Pi and Windows PC on the same LAN for the initial connection.

### 1. Find the Raspberry Pi's IP address

Use one of these methods:

- Check the router's DHCP/client list for the Pi hostname.
- If mDNS is available on the network, try `ping raspberrypi.local` or the hostname configured in Raspberry Pi Imager.
- If you have a monitor and keyboard attached to the Pi, sign in locally and run:

```bash
hostname -I
ip -4 -br address
```

Use the Pi's LAN IPv4 address, not the router address.

### 2. Ensure SSH is enabled

For a new SD card, use Raspberry Pi Imager's OS customisation settings to set a username/password, hostname, network settings, and enable SSH before writing the card.

For an already-running Pi with a local monitor/keyboard, enable SSH:

```bash
sudo systemctl enable --now ssh
sudo systemctl status ssh --no-pager
```

If the `ssh` service is not installed, install the Raspberry Pi OS OpenSSH server package first:

```bash
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

### 3. Connect from Windows

Open **Windows Terminal** or **PowerShell**:

```powershell
Test-NetConnection <PI-IP-ADDRESS> -Port 22
ssh <LINUX-USERNAME>@<PI-IP-ADDRESS>
```

Replace both placeholders. On the first connection, verify the host fingerprint and type `yes`; then enter the Linux account password. The password is not displayed as you type.

If Windows reports that `ssh` is not recognized, install the Windows OpenSSH Client from **Settings → System → Optional features → View features**, or run PowerShell as Administrator:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

### 4. Validate the installation on the Pi

Run these commands in the SSH session:

```bash
hostnamectl
cat /etc/os-release
dpkg --print-architecture
ip -4 -br address

sudo systemctl is-active docker
sudo systemctl is-active containerd
sudo systemctl is-active smbd

sudo docker compose -f ~/homeassistant/compose.yaml ps
sudo docker compose -f ~/homeassistant/compose.yaml logs --tail=100 homeassistant

sudo testparm -s
sudo pdbedit -L
ls -lh ~/homeassistant/config/www
grep -n -A22 '^lovelace:' ~/homeassistant/config/configuration.yaml
```

If Tailscale was configured, also run:

```bash
sudo tailscale status
sudo tailscale ip -4
```

A missing Tailscale service is expected when `/root/tailscale-authkey` was not provisioned and the master installer skipped that step.

### 5. Test Home Assistant and Samba from Windows

In PowerShell, check the two application ports:

```powershell
Test-NetConnection <PI-IP-ADDRESS> -Port 8123
Test-NetConnection <PI-IP-ADDRESS> -Port 445
```

Then open `http://<PI-IP-ADDRESS>:8123` in a browser. Complete the Home Assistant onboarding if this is a new installation.

In File Explorer, enter the share path:

```text
\\<PI-IP-ADDRESS>\HomeAssistant
```

Sign in with the Pi's Linux username and the Samba password created by the installer. Create a small test file, confirm it appears in `/home/<LINUX-USERNAME>/homeassistant/`, then delete the test file. Do not use Windows' saved credentials for a different username if authentication fails; remove the stale entry from **Credential Manager → Windows Credentials** and reconnect.

### 6. Validate the YAML resources

The installer registers the eight JavaScript modules in `configuration.yaml` and runs Home Assistant's configuration check before restarting when it creates that section. Confirm that all eight URLs are present:

```bash
grep -n -A22 '^lovelace:' ~/homeassistant/config/configuration.yaml
```

After Home Assistant is running, use a browser hard refresh (`Ctrl+Shift+R`) to clear cached JavaScript. If a card fails to load, inspect the browser developer console and Home Assistant logs; a file existing in `www/` alone does not prove the frontend successfully loaded it.

## Validation and logs

- Supported OS: Raspberry Pi OS or Debian Bookworm/Trixie, arm64 or armhf.
- Requires sudo access and internet access during installation.
- Logs are stored under `/var/log` with mode 600.
- No script automatically reboots the Pi.
- The scripts have not been integration-tested on physical Raspberry Pi hardware as part of this update.

Check shell syntax before execution:

```bash
bash -n Install-RaspberryPi.sh
bash -n Install-HomeAssistant.sh
bash -n Install-Tailscale.sh
bash -n Remove-Cups.sh
```

A successful `bash -n` check verifies shell syntax only. It does not verify package installation, Docker deployment, Tailscale route approval, Samba access, or Home Assistant startup.

## Official references

- [Home Assistant dashboard resources](https://www.home-assistant.io/dashboards/dashboards/)
- [Home Assistant reload dashboard resources](https://www.home-assistant.io/actions/lovelace.reload_resources/)
- [Home Assistant configuration.yaml](https://www.home-assistant.io/docs/configuration/)
- [Tailscale up command](https://tailscale.com/docs/reference/tailscale-cli/up)
- [Tailscale subnet routers](https://tailscale.com/docs/features/subnet-routers)
- [Docker Engine installation on Debian](https://docs.docker.com/engine/install/debian/)
- [Docker Engine installation on Raspberry Pi OS](https://docs.docker.com/engine/install/raspberry-pi-os/)
- [Home Assistant Container installation](https://www.home-assistant.io/installation/linux/)
