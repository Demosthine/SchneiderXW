# Raspberry Pi Setup Scripts

Bash setup and maintenance scripts for Raspberry Pi OS. Scripts display output in the terminal and append it to protected log files. They do not automatically reboot the Pi.

## Scripts

| Script | Purpose | Log |
|---|---|---|
| `Install-RaspberryPi.sh` | Master workflow: CUPS, Tailscale, Docker, Home Assistant/onboarding, Samba, dashboard resource preloading | `/var/log/install-raspberrypi.log` |
| `Remove-Cups.sh` | Stop and remove CUPS services and installed CUPS/printer-driver packages | `/var/log/remove-cups.log` |
| `Install-Tailscale.sh` | Configure the Pi as a Tailscale IPv4 /24 subnet router | `/var/log/install-tailscale.log` |
| `Install-Docker.sh` | Install Docker Engine, containerd, and Docker Compose | `/var/log/install-docker.log` |
| `Install-HomeAssistant.sh` | Deploy Home Assistant Container using the installed Docker Engine | `/var/log/install-homeassistant.log` |

## Master installation

On the Raspberry Pi, clone the authorized repository and run:

```bash
git clone https://github.com/Demosthine/SchneiderXW.git
cd SchneiderXW/raspberry-pi-setup
bash -n Install-RaspberryPi.sh
bash -n Remove-Cups.sh
bash -n Install-Tailscale.sh
bash -n Install-Docker.sh
bash -n Install-HomeAssistant.sh
sudo bash ./Install-RaspberryPi.sh
```

The master installer follows this sequence:

1. **Remove CUPS:** asks for explicit interactive confirmation before uninstalling printing services and printer-driver packages. A non-interactive run skips this step.
2. **Install Tailscale:** runs `Install-Tailscale.sh`. If the Pi is already authenticated, it configures the subnet route without requesting a key. Otherwise, it prompts for a one-time authentication key with terminal input hidden.
3. **Install Docker:** runs `Install-Docker.sh` to install and enable Docker Engine, containerd, and Compose.
4. **Install Home Assistant and onboard:** runs `Install-HomeAssistant.sh`, waits for Home Assistant to respond, and pauses so you can complete first-run onboarding in a browser.
5. **Install Samba:** creates the private authenticated `HomeAssistant` share. On first setup it prompts for a Samba password; an existing Samba account/password is preserved.
6. **Pre-load resources:** clones and stages the eight dashboard-card repositories, backs up replaced files, installs the JavaScript files under `~/homeassistant/config/www/`, and registers them in `configuration.yaml`. The configuration is checked before Home Assistant is restarted.

The installer does not silently switch an existing Lovelace storage configuration to YAML mode. Configuration-template downloads remain deferred. No unrelated repository files are changed and no automatic reboot is performed.

### CUPS safety

CUPS removal is destructive to printing functionality. The master installer asks before running it. The standalone script can also be run separately.

The CUPS script purges installed CUPS/printer-driver packages, stops and disables CUPS services, removes CUPS configuration/log/cache directories, and verifies removal. It deliberately does **not** run `apt autoremove`, because that operation can remove unrelated packages APT considers unused. It does not remove `/var/spool/cups`, which may contain print queue data.

### Tailscale setup

Before running the installer, create a **one-time** authentication key in the Tailscale admin console under **Settings → Keys**: https://login.tailscale.com/admin/settings/keys

Recommended key settings for this Raspberry Pi:

- **Reusable:** Off (one-time use).
- **Ephemeral:** Off. This is a persistent server, not a short-lived workload.
- **Pre-approved:** On if your tailnet requires device approval.
- **Expiration:** A short validity window, such as one day. The one-time key is revoked after successful use; the device remains authenticated using its own node identity.

When the master installer reaches the Tailscale step, paste the key at the hidden terminal prompt. The key is not echoed, logged, committed to GitHub, or saved as a persistent file. The installer writes it briefly to a root-only temporary file under `/run` and deletes that file immediately after successful enrollment; an exit cleanup also removes it if setup fails.

If the Pi is already authenticated with Tailscale, no key is requested. The script simply configures the advertised LAN route. The standalone installer follows the same behavior. It detects the default IPv4 interface and LAN subnet, and stops unless the subnet is /24. It enables IPv4/IPv6 forwarding and configures Tailscale to advertise the LAN route.

**Manual step:** Approve the advertised subnet route in the Tailscale admin console unless your tailnet policy automatically approves it: https://login.tailscale.com/admin/machines

Do not put authentication keys in the repository, script source, shell command line, or a permanent file.

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

Run scripts with Bash, not `sh`. The standalone dependency order is:

```bash
sudo bash ./Remove-Cups.sh
sudo bash ./Install-Tailscale.sh
sudo bash ./Install-Docker.sh
sudo bash ./Install-HomeAssistant.sh
```

The master installer handles Samba and resource preloading after the Home Assistant onboarding pause.

### Install Docker and Home Assistant

`Install-Docker.sh` updates OS packages, installs Docker Engine and Compose from Docker's Debian APT repository, enables Docker/containerd, and adds the invoking user to the docker group. It does not deploy Home Assistant.

`Install-HomeAssistant.sh` requires Docker and the Compose plugin to be installed and active. It creates `~/homeassistant/compose.yaml` only if absent, then pulls and starts Home Assistant Container. The service uses host networking, privileged mode, read-only localtime and D-Bus mounts, the stable Home Assistant image, restart unless-stopped, and the `America/Phoenix` timezone.

**Security:** Membership in the docker group effectively grants root-level control of the host. Add only trusted users. Log out and back in before expecting new group membership to apply.

The Docker installer does not automatically remove conflicting Docker/containerd packages. Both installers support Bookworm and Trixie, on arm64 or armhf, and stop on other detected releases or architectures.

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

Tailscale should be active after the installer configures it. If setup was not run or authentication was declined, inspect `/var/log/install-tailscale.log` and rerun `sudo bash ./Install-Tailscale.sh` from an interactive terminal.

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
bash -n Remove-Cups.sh
bash -n Install-Tailscale.sh
bash -n Install-Docker.sh
bash -n Install-HomeAssistant.sh
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
