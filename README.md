# AC Admin — Assetto Corsa Dedicated Server + Management Panel

A custom web-based management panel for [AssettoServer](https://github.com/compujuckel/AssettoServer), designed for Proxmox LXC on Ubuntu 22.04/24.04.

## Compatibility

| Component | Tested Version |
|-----------|---------------|
| AssettoServer | v0.0.54 |
| Custom Shaders Patch | v0.3.0-preview212 (ID: 3749) |
| Ubuntu | 22.04 / 24.04 |

**Important notes:**
- Do NOT add a `[DYNAMIC_TRACK]` section to `server_cfg.ini` — causes handshake failures
- Do NOT use `[PRACTICE]` or `[QUALIFY]` sections — only `[RACE]` is supported by AssettoServer
- Do NOT enable `EnableWeatherFx: true` unless all clients have a compatible CSP version
- CSP v0.2.11 is NOT compatible — use v0.3.0-preview212 or later
- Weather strings must use standard AC format (e.g. `3_clear`, `8_heavy_rain`) not WeatherFX format

---

## Features

- **Event Schedule** — queue up tracks and sessions with loop mode and auto-advance
- **Lap Board** — persistent SQLite lap time storage, survives reboots
- **Race History** — connection log and session history
- **Weather & Time of Day** control
- **Home Assistant integration** — push 16 server sensors via REST API
- **AI traffic** support
- **Discord integration** — webhooks for session changes and race results
- **Resource monitoring** — CPU (via Proxmox API), RAM, disk, network
- **User management** — admin and read-only roles
- **Syncthing content sync** — keep cars and tracks in sync with your PC or NAS (optional)

---

## Quick Install

```bash
bash <(wget -qO- https://raw.githubusercontent.com/wazzabooth/Assetto-Corsa-Server/main/install.sh)
```

The installer will prompt you for:
- Admin username and password
- Server name and max clients
- Cloudflare Tunnel token (optional)
- Proxmox CPU polling config (optional — recommended, see below)
- Syncthing content sync folders (optional — see below)

---

## Update

To update to the latest version without losing config, content or lap times:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/wazzabooth/Assetto-Corsa-Server/main/update.sh)
```

Previous version is automatically backed up to `/opt/assettoserver/backups/` before updating.

---

## Requirements

- Ubuntu 22.04 or 24.04 LXC (Proxmox recommended)
- 2GB RAM minimum (4GB recommended)
- 20GB+ disk space (more for track/car content)
- Python 3.10+

---

## Ports

| Port | Service |
|------|---------|
| 9600 TCP/UDP | AC Game Server |
| 8081 TCP | AC HTTP API |
| 8082 TCP | Web Panel |
| 8083 TCP | Management API |
| 8384 TCP | Syncthing GUI (if installed) |
| 22000 TCP/UDP | Syncthing sync protocol (if installed) |

> Port 9600 must be forwarded on your router for players to connect.
> The web panel (8082) can be proxied via Cloudflare Tunnel — no port forward needed.

---

## Proxmox CPU Monitoring

By default `psutil` reads host-level CPU stats inside an LXC container, which is meaningless. The installer can configure the panel to pull accurate per-container CPU usage from the Proxmox API instead.

### During install

The installer will ask:
```
Configure Proxmox CPU polling? [y/N]: y
Proxmox host IP (e.g. 192.168.1.66): 192.168.1.66
Proxmox API token (PVEAPIToken=root@pam!name=secret): PVEAPIToken=root@pam!acmanager=xxxx
This LXC's VMID (shown in Proxmox UI sidebar): 125
```

### Creating a Proxmox API token

1. Open Proxmox web UI → **Datacenter → Permissions → API Tokens**
2. Click **Add**
3. User: `root@pam`, Token ID: `acmanager`, uncheck **Privilege Separation**
4. Copy the token secret — it's only shown once

### On an existing install

```bash
bash <(wget -qO- https://raw.githubusercontent.com/wazzabooth/Assetto-Corsa-Server/main/configure_proxmox_cpu.sh)
```

Or edit `mgmt_api.py` directly — find `_PROXMOX_HOST`, `_PROXMOX_TOKEN`, `_PROXMOX_VMID` near the top of the file.

---

## Syncthing Content Sync

Syncthing keeps your AC server content (cars, tracks) in sync with your Windows PC or NAS. The server is set to **receive only** — your PC pushes changes, the server never modifies your source.

### During install

The installer will ask which folders to sync:
```
Install Syncthing? [y/N]: y

Folder path (or ENTER to finish): /opt/assettoserver/content/cars
Label for this folder: Cars

Folder path (or ENTER to finish): /opt/assettoserver/content/tracks
Label for this folder: Tracks

Folder path (or ENTER to finish): [ENTER]
```

### After install — connecting your PC

1. Install [Syncthing](https://syncthing.net) on your Windows PC
2. Open the server GUI at `http://SERVER-IP:8384`
3. Copy the **Device ID** shown in the server GUI (Actions → Show ID)
4. In Syncthing on your PC, click **Add Remote Device** and paste the Device ID
5. Share your cars/tracks folders with the server device
6. Accept the incoming share request in the server GUI
7. Set the folder type to **Send Only** on the PC side

### Notes
- The Syncthing GUI has no password by default (LAN only). To add one: GUI → Actions → Settings → GUI Authentication
- After adding new content, restart AssettoServer: `systemctl restart assettoserver`
- Sync status: `systemctl status syncthing`
- Logs: `journalctl -u syncthing -f`

---

## Home Assistant Integration

1. Go to **Settings** tab in the panel
2. Enter your HA URL and a Long-Lived Access Token
3. Enable the integration
4. Sensors appear in HA under `sensor.ac_server_*`

Available sensors: `players`, `connected`, `max_slots`, `session`, `track`, `status`, `event`, `next_event`, `events_total`, `loop`, `cpu`, `memory`, `disk`, `drivers`, `cars`, `best_laps`

---

## Admin API Endpoints

All endpoints require `X-Session-Token` header (obtained via `POST /auth/login`).

| Method | Path | Description |
|--------|------|-------------|
| POST | `/auth/login` | Get session token |
| GET | `/public/stats` | Live server status (no auth) |
| GET | `/mgmt/stats` | CPU, RAM, disk, network |
| GET | `/mgmt/laps` | Lap records from SQLite |
| POST | `/mgmt/restart` | Restart AssettoServer |
| POST | `/mgmt/kick` | Kick player by car ID |
| POST | `/mgmt/ban` | Ban player by GUID |

---

## File Structure

```
ac-admin.html              # Frontend single-page app
mgmt_api.py                # Flask backend API
webserver.py               # Static file + proxy server
install.sh                 # One-line install script
update.sh                  # One-line update script
configure_proxmox_cpu.sh   # Add Proxmox CPU to existing installs
cfg/                       # Runtime config (gitignored)
cfg.example/               # Example configs
content/                   # AC tracks and cars (gitignored)
```

---

## Credits

Built on top of [AssettoServer](https://github.com/compujuckel/AssettoServer) by compujuckel.
