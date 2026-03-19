# AC Admin — Assetto Corsa Dedicated Server + Management Panel

A custom web-based management panel for [AssettoServer](https://github.com/compujuckel/AssettoServer), designed for Proxmox LXC on Ubuntu 22.04/24.04.

## Features

- Single Race configuration with track/car picker
- Event Schedule with loop mode and auto-advance
- Lap Board & race history
- Weather & time of day control
- Home Assistant integration (push server stats as sensors)
- AI traffic support
- Discord integration
- Resource monitoring
- User management

## Quick Install
```bash
bash <(wget -qO- https://raw.githubusercontent.com/wazzabooth/Assetto-Corsa-Server/main/install.sh)
```

## Requirements

- Ubuntu 22.04 or 24.04 LXC (Proxmox recommended)
- 2GB RAM minimum (4GB recommended)
- 20GB+ disk space (more for track/car content)
- Python 3.10+

## Ports

| Port | Service |
|------|---------|
| 9600 TCP/UDP | AC Game Server |
| 8081 TCP | AC HTTP API |
| 8082 TCP | Web Panel |
| 8083 TCP | Management API |

> Note: Port 9600 must be forwarded on your router for players to connect.
> The web panel (8082) can be proxied via Cloudflare Tunnel — no port forward needed.

## Manual Setup

1. Clone the repo
2. Copy example configs: `cp cfg.example/* cfg/`
3. Run the install script or follow manual steps in the wiki
4. Access the panel at `http://YOUR-IP:8082`
5. Default login: `admin` / `changeme123` — **change this immediately**

## Home Assistant Integration

1. Go to Settings tab in the panel
2. Enter your HA URL and a Long-Lived Access Token
3. Enable the integration
4. Sensors will appear in HA under `sensor.ac_server_*`

## File Structure
```
ac-admin.html     # Frontend single-page app
mgmt_api.py       # Flask backend API
webserver.py      # Static file + proxy server
install.sh        # One-line install script
cfg/              # Runtime config (gitignored)
cfg.example/      # Example configs to copy
content/          # AC tracks and cars (gitignored)
```

## Credits

Built on top of [AssettoServer](https://github.com/compujuckel/AssettoServer) by compujuckel.
