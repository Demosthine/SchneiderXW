# Raspberry Pi Setup Scripts

Bash setup and maintenance scripts for Raspberry Pi OS. Each script displays output in the terminal and appends it to a protected log file.

## Scripts

| Script | Purpose | Log |
|---|---|---|
| `Remove-Cups.sh` | Stop and remove CUPS services and installed CUPS/printer-driver packages | `/var/log/remove-cups.log` |
| `Install-Tailscale.sh` | Configure the Pi as a Tailscale IPv4 /24 subnet router | `/var/log/install-tailscale.log` |
| `Install-HomeAssistant.sh` | Install Docker Engine/Compose and deploy Home Assistant Container | `/var/log/install-homeassistant.log` |

## Requirements and execution

- Raspberry Pi 4 running Raspberry Pi OS.
- Bash, sudo access, and internet access during installation.
- Review each script and its effects before running it.

Run scripts with Bash, not sh:

```bash
sudo bash ./Remove-Cups.sh
sudo bash ./Install-Tailscale.sh
sudo bash ./Install-HomeAssistant.sh
```

The scripts do not reboot the Pi automatically.

## Remove CUPS

Stops/disables CUPS services and sockets, purges installed CUPS-related and printer-driver packages, removes CUPS configuration/log/cache directories, and verifies removal.

**Important:** `apt-get autoremove -y` may remove other packages APT considers unused. Review package dependencies and system state first. The script does not remove `/var/spool/cups`, which may contain print queue data.

## Install Tailscale subnet routing

Before running the script, create a Tailscale auth key and store it in the root-only file `/root/tailscale-authkey`. Do not place the key in the script or commit it to Git. Set ownership to root and permissions to 600.

The installer detects the default IPv4 interface and LAN subnet, and stops unless the subnet is /24. It enables IPv4/IPv6 forwarding, installs Tailscale if needed, and authenticates using the protected key file. If the node is already connected, it updates only the requested preferences.

**Manual step:** Approve the advertised subnet route in the Tailscale admin console unless your tailnet policy automatically approves it: https://login.tailscale.com/admin/machines

Remove the key file after enrollment if it is no longer needed.

## Install Home Assistant Container

Run from the normal user account using sudo. The script identifies the invoking user, updates the OS, installs Docker Engine and Compose from Docker's Debian APT repository, enables Docker/containerd, adds that user to the docker group, and deploys Home Assistant.

Home Assistant data is stored under `~/homeassistant/` with `compose.yaml` and a persistent `config/` directory. The Compose service uses host networking, privileged mode, read-only localtime and D-Bus mounts, the stable Home Assistant image, restart unless-stopped, and the `America/Phoenix` timezone.

Home Assistant is normally available at `http://<raspberry-pi-ip>:8123`.

**Security:** Membership in the docker group effectively grants root-level control of the host. Add only trusted users. Log out and back in before expecting new group membership to apply.

The script does not automatically remove conflicting Docker/containerd packages or overwrite an existing Compose file. It supports Bookworm and Trixie, on arm64 or armhf, and stops on other detected releases or architectures.

## Logging and validation

Logs are created under `/var/log` with mode 600. Run syntax checks:

```bash
bash -n Remove-Cups.sh
bash -n Install-Tailscale.sh
bash -n Install-HomeAssistant.sh
```

A successful `bash -n` check verifies shell syntax only. It does not install packages, authenticate Tailscale, deploy Home Assistant, or prove operation on Raspberry Pi hardware. These scripts have not been integration-tested on a physical Raspberry Pi as part of this release.

## Official references

- [Tailscale up command](https://tailscale.com/docs/reference/tailscale-cli/up)
- [Tailscale subnet routers](https://tailscale.com/docs/features/subnet-routers)
- [Docker Engine installation on Debian](https://docs.docker.com/engine/install/debian/)
- [Docker Engine installation on Raspberry Pi OS](https://docs.docker.com/engine/install/raspberry-pi-os/)
- [Home Assistant Container installation](https://www.home-assistant.io/installation/linux/)
