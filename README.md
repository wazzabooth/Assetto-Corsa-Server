# AC Admin — Assetto Corsa Dedicated Server + Management Panel

A custom web-based management panel for [AssettoServer](https://github.com/compujuckel/AssettoServer), designed for Proxmox LXC on Ubuntu 22.04/24.04.

## Compatibility

| Component | Tested Version |
|---|---|
| AssettoServer | v0.0.54 |
| Custom Shaders Patch | v0.3.0-preview212 (ID: 3749) |
| Ubuntu | 22.04 / 24.04 |

**Important notes:**

- Do NOT add a `[DYNAMIC_TRACK]` section to `server_cfg.ini` — causes handshake failures
- Do NOT use `[PRACTICE]` or `[QUALIFY]` sections — only `[RACE]` is supported by AssettoServer v0.0.54
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
- **All port numbers** (see port guide below)
- Cloudflare Tunnel token (optional)
- Proxmox CPU polling config (optional)
- Syncthing content sync folders (optional)

---

## Ports

Each AC server uses **four ports**:

| Port | Service | Router forward required? |
|---|---|---|
| AC HTTP port | AssettoServer HTTP API — used by Content Manager to find and join the server | **Yes** |
| Game TCP/UDP port | AssettoServer game traffic — used by AC client once connected | **Yes** |
| Web panel port | AC Admin web panel | No (LAN / Cloudflare Tunnel) |
| Mgmt API port | Flask backend API | No (internal only) |

> **The web panel and mgmt API are internal only.** You do not need to forward these on your router. Access the panel via LAN IP or Cloudflare Tunnel.

---

## Running Multiple Servers from the Same External IP

If you have more than one AC server behind the same router, each server must use **unique port numbers** for all four ports. Two servers cannot share the same external port.

### Recommended port layout

| Server | AC HTTP | Game TCP/UDP | Web Panel | Mgmt API |
|---|---|---|---|---|
| GT (server 1) | 8081 | 9600 | 8082 | 8083 |
| Road (server 2) | 8082 | 9601 | 8085 | 8086 |
| Nordschleife (server 3) | 8083 | 9602 | 8087 | 8088 |
| IoM (server 4) | 8084 | 9603 | 8089 | 8090 |

The installer will prompt you for all four port values. Enter the correct set for each server when running the install script on each LXC.

### Why the game port must match internally and externally

AssettoServer tells connecting clients which TCP/UDP port to use. If the internal game port (set in `server_cfg.ini`) does not match the external port your router forwards, the client will try to connect on the wrong port and fail with a handshake error.

**The internal game port must equal the external port forward destination.**

Example for the Road server:
- Router: external `9601` → internal `192.168.1.119:9601`
- `server_cfg.ini`: `UDP_PORT = 9601` and `TCP_PORT = 9601`

These must be the same number. The installer sets this automatically based on what you enter for the game port.

### Router port forwarding

For each server, create two port forward rules in your router:

```
External port [AC HTTP]       TCP     → [server LAN IP]:[AC HTTP port]
External port [game port]     TCP+UDP → [server LAN IP]:[game port]
```

Example for a four-server setup using the recommended layout above:

| Rule name | Protocol | External port | Internal IP | Internal port |
|---|---|---|---|---|
| AC GT - HTTP | TCP | 8081 | 192.168.1.184 | 8081 |
| AC GT - Game | TCP+UDP | 9600 | 192.168.1.184 | 9600 |
| AC Road - HTTP | TCP | 8082 | 192.168.1.119 | 8082 |
| AC Road - Game | TCP+UDP | 9601 | 192.168.1.119 | 9601 |
| AC Nords - HTTP | TCP | 8083 | 192.168.1.124 | 8083 |
| AC Nords - Game | TCP+UDP | 9602 | 192.168.1.124 | 9602 |
| AC IoM - HTTP | TCP | 8084 | 192.168.1.231 | 8084 |
| AC IoM - Game | TCP+UDP | 9603 | 192.168.1.231 | 9603 |

### Generating a join link

Once your server is running and ports are forwarded, players can join via Content Manager using:

```
https://acstuff.ru/s/q:race/online/join?ip=YOUR_EXTERNAL_IP&httpPort=AC_HTTP_PORT
```

Example:
```
https://acstuff.ru/s/q:race/online/join?ip=81.103.16.207&httpPort=8084
```

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
|---|---|---|
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
