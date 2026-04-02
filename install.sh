#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  AC Admin — Assetto Corsa Dedicated Server + Custom Management Panel
#  Install Script for Ubuntu 22.04 / 24.04 LXC (Proxmox)
#
#  Usage (one-liner):
#    bash <(wget -qO- https://raw.githubusercontent.com/wazzabooth/Assetto-Corsa-Server/main/install.sh)
#
#  Or download and run:
#    wget https://raw.githubusercontent.com/wazzabooth/Assetto-Corsa-Server/main/install.sh
#    bash install.sh
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERR ]${NC}  $*"; exit 1; }
banner() {
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"
}

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run as root: sudo bash install.sh"

# ── Config ────────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/assettoserver"
REPO_BASE="https://raw.githubusercontent.com/wazzabooth/Assetto-Corsa-Server/main"
AS_GITHUB="https://api.github.com/repos/compujuckel/AssettoServer/releases/latest"

AC_HTTP_PORT=8081
AC_TCP_PORT=9600
AC_UDP_PORT=9600
MGMT_PORT=8083
WEB_PORT=8082

# ── Welcome ───────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         AC Admin — Assetto Corsa Server Setup        ║"
echo "  ║         Ubuntu 22.04 / 24.04 LXC Install             ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "  This script will install:"
echo "   • AssettoServer (latest release from GitHub)"
echo "   • AC Admin management panel"
echo "   • Flask API backend (port ${MGMT_PORT})"
echo "   • Web panel server (port ${WEB_PORT})"
echo "   • Systemd services (auto-start on boot)"
echo "   • UFW firewall rules"
echo "   • Syncthing content sync (optional)"
echo ""

# ── Gather config ─────────────────────────────────────────────────────────────
banner "Configuration"

read -rp "  Admin username [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

while true; do
  read -rsp "  Admin password: " ADMIN_PASS; echo ""
  [[ -z "$ADMIN_PASS" ]] && warn "Password cannot be empty" && continue
  read -rsp "  Confirm password: " ADMIN_PASS2; echo ""
  [[ "$ADMIN_PASS" == "$ADMIN_PASS2" ]] && break
  warn "Passwords don't match, try again."
done

read -rp "  Server name [My AC Server]: " SERVER_NAME
SERVER_NAME="${SERVER_NAME:-My AC Server}"

read -rp "  Max clients [20]: " MAX_CLIENTS
MAX_CLIENTS="${MAX_CLIENTS:-20}"

echo ""
read -rp "  Set up Cloudflare Tunnel for remote panel access? [y/N]: " USE_CF
USE_CF="${USE_CF:-n}"
CF_TOKEN=""
CF_HOSTNAME=""
if [[ "$USE_CF" =~ ^[Yy]$ ]]; then
  echo "  Get your token from: https://one.dash.cloudflare.com → Networks → Tunnels"
  read -rp "  Cloudflare tunnel token: " CF_TOKEN
  [[ -z "$CF_TOKEN" ]] && warn "No token provided — skipping Cloudflare setup" && USE_CF="n"
  if [[ "$USE_CF" =~ ^[Yy]$ ]]; then
    read -rp "  Public hostname for the panel (e.g. admin.dead-bull.co.uk): " CF_HOSTNAME
  fi
fi

# ── Proxmox CPU config ────────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}── Proxmox CPU Integration ──────────────────────────────────────${NC}"
echo "  psutil reads host CPU stats inside an LXC, which is inaccurate."
echo "  The Proxmox API provides real per-container CPU usage instead."
echo ""
read -rp "  Configure Proxmox CPU polling? [y/N]: " USE_PROXMOX
USE_PROXMOX="${USE_PROXMOX:-n}"
PVE_HOST=""; PVE_TOKEN=""; PVE_VMID=""

if [[ "$USE_PROXMOX" =~ ^[Yy]$ ]]; then
  read -rp "  Proxmox host IP (e.g. 192.168.1.66): " PVE_HOST
  read -rp "  Proxmox API token (PVEAPIToken=root@pam!name=secret): " PVE_TOKEN
  read -rp "  This LXC's VMID (shown in Proxmox UI sidebar): " PVE_VMID
fi

# ── Syncthing config ──────────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}── Syncthing Content Sync ───────────────────────────────────────${NC}"
echo "  Syncthing keeps your AC content in sync with your PC or NAS."
echo "  The server is set to RECEIVE ONLY — your PC pushes changes."
echo ""
read -rp "  Install Syncthing? [y/N]: " USE_SYNCTHING
USE_SYNCTHING="${USE_SYNCTHING:-n}"
SYNC_FOLDERS=()
SYNC_LABELS=()

if [[ "$USE_SYNCTHING" =~ ^[Yy]$ ]]; then
  echo ""
  echo "  Enter folder paths to sync (receive-only). Press ENTER with no input when done."
  echo "  Common choices:"
  echo "    ${INSTALL_DIR}/content/cars"
  echo "    ${INSTALL_DIR}/content/tracks"
  echo "    ${INSTALL_DIR}/content"
  echo ""
  while true; do
    read -rp "  Folder path (or ENTER to finish): " FPATH
    [ -z "$FPATH" ] && break
    FPATH="${FPATH/#\~/$HOME}"
    read -rp "  Label for this folder (e.g. Cars, Tracks): " FLABEL
    FLABEL="${FLABEL:-$(basename "$FPATH")}"
    SYNC_FOLDERS+=("$FPATH")
    SYNC_LABELS+=("$FLABEL")
    ok "  Added: $FLABEL → $FPATH"
  done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo -e "  ${BOLD}Summary:${NC}"
echo "  ─────────────────────────────────────────"
echo "  Admin user:    $ADMIN_USER"
echo "  Server name:   $SERVER_NAME"
echo "  Max clients:   $MAX_CLIENTS"
echo "  Install dir:   $INSTALL_DIR"
echo "  Web panel:     http://${LOCAL_IP}:${WEB_PORT}"
echo "  AC ports:      ${AC_TCP_PORT} TCP/UDP"
[[ "$USE_CF" =~ ^[Yy]$ ]]       && echo "  Cloudflare:    Yes"          || echo "  Cloudflare:    No"
[[ "$USE_PROXMOX" =~ ^[Yy]$ ]]  && echo "  Proxmox CPU:   ${PVE_HOST} VMID ${PVE_VMID}" || echo "  Proxmox CPU:   No"
[[ "$USE_SYNCTHING" =~ ^[Yy]$ ]] && echo "  Syncthing:     Yes (${#SYNC_FOLDERS[@]} folder(s))" || echo "  Syncthing:     No"
echo "  ─────────────────────────────────────────"
echo ""
read -rp "  Proceed with install? [Y/n]: " CONFIRM
[[ "${CONFIRM:-y}" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── System packages ───────────────────────────────────────────────────────────
banner "System packages"
apt-get update -qq
apt-get install -y -qq curl wget unzip python3 python3-pip ufw jq net-tools 2>/dev/null || true
ok "Base packages installed"

pip3 install -q flask flask-cors psutil pyyaml 2>/dev/null || \
  pip3 install --break-system-packages -q flask flask-cors psutil pyyaml
ok "Python packages installed (flask, flask-cors, psutil, pyyaml)"

# ── Directory structure ───────────────────────────────────────────────────────
banner "Directory structure"
mkdir -p "$INSTALL_DIR/cfg"
mkdir -p "$INSTALL_DIR/content/tracks"
mkdir -p "$INSTALL_DIR/content/cars"
mkdir -p "$INSTALL_DIR/cfg/presets"
ok "Directories created at $INSTALL_DIR"

# ── AssettoServer binary ──────────────────────────────────────────────────────
banner "AssettoServer binary"
info "Fetching latest AssettoServer release from GitHub..."

AS_RELEASE=$(curl -s "$AS_GITHUB") || error "Could not reach GitHub API"
AS_VERSION=$(echo "$AS_RELEASE" | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null) \
  || error "Could not parse AssettoServer release"

AS_URL=$(echo "$AS_RELEASE" | python3 -c "
import json,sys
data=json.load(sys.stdin)
assets=[a for a in data.get('assets',[]) if 'linux' in a['name'].lower() and 'arm' not in a['name'].lower() and 'aarch' not in a['name'].lower() and a['name'].endswith('.tar.gz')]
print(assets[0]['browser_download_url'] if assets else '')
" 2>/dev/null)

[[ -z "$AS_URL" ]] && error "Could not find Linux tar.gz asset in release"

info "Downloading AssettoServer $AS_VERSION..."
wget -q --show-progress -O /tmp/assettoserver.tar.gz "$AS_URL"
tar -xzf /tmp/assettoserver.tar.gz -C "$INSTALL_DIR"
rm /tmp/assettoserver.tar.gz

AS_BIN=$(find "$INSTALL_DIR" -name "AssettoServer" -type f | head -1)
[[ -z "$AS_BIN" ]] && error "AssettoServer binary not found after extraction"
chmod +x "$AS_BIN"
[[ "$AS_BIN" != "$INSTALL_DIR/AssettoServer" ]] && mv "$AS_BIN" "$INSTALL_DIR/AssettoServer"
ok "AssettoServer $AS_VERSION installed"

# ── Download app files ────────────────────────────────────────────────────────
banner "Management panel files"
info "Downloading app files from GitHub..."

for FILE in mgmt_api.py ac-admin.html webserver.py; do
  info "  Downloading ${FILE}..."
  wget -q -O "${INSTALL_DIR}/${FILE}" "${REPO_BASE}/${FILE}" || error "Failed to download ${FILE}"
  [[ ! -s "${INSTALL_DIR}/${FILE}" ]] && error "${FILE} is empty — check REPO_BASE in install.sh"
  ok "  ${FILE}"
done

chmod +x "${INSTALL_DIR}/mgmt_api.py"
chmod +x "${INSTALL_DIR}/webserver.py"

# ── Proxmox CPU patch ─────────────────────────────────────────────────────────
if [[ "$USE_PROXMOX" =~ ^[Yy]$ ]]; then
  banner "Proxmox CPU Integration"

  # Retry loop — give them 3 attempts to get credentials right
  PROXMOX_OK=false
  for ATTEMPT in 1 2 3; do
    info "Testing Proxmox connection (attempt ${ATTEMPT}/3)..."

    STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
      -H "Authorization: ${PVE_TOKEN}" \
      "https://${PVE_HOST}:8006/api2/json/nodes/pve/lxc/${PVE_VMID}/status/current" || echo "000")

    if [ "$STATUS" = "200" ]; then
      ok "Proxmox connection successful (VMID ${PVE_VMID})"
      PROXMOX_OK=true
      break
    else
      warn "Proxmox returned HTTP ${STATUS}"
      if [ "$ATTEMPT" -lt 3 ]; then
        echo ""
        echo "  Common causes:"
        echo "    • Token format wrong — must be: PVEAPIToken=root@pam!tokenid=secret"
        echo "    • VMID wrong — check the number in the Proxmox sidebar"
        echo "    • Proxmox host IP wrong or unreachable"
        echo ""
        read -rp "  Try again with corrected values? [Y/n]: " RETRY
        [[ "${RETRY:-y}" =~ ^[Nn]$ ]] && break
        read -rp "  Proxmox host IP [${PVE_HOST}]: " NEW_HOST
        [[ -n "$NEW_HOST" ]] && PVE_HOST="$NEW_HOST"
        read -rp "  Proxmox API token [${PVE_TOKEN}]: " NEW_TOKEN
        [[ -n "$NEW_TOKEN" ]] && PVE_TOKEN="$NEW_TOKEN"
        read -rp "  LXC VMID [${PVE_VMID}]: " NEW_VMID
        [[ -n "$NEW_VMID" ]] && PVE_VMID="$NEW_VMID"
      else
        echo ""
        warn "Could not connect to Proxmox after 3 attempts."
        warn "CPU will show 0% until fixed. Run configure_proxmox_cpu.sh after install."
      fi
    fi
  done

  if [ "$PROXMOX_OK" = "true" ]; then

  python3 << PYEOF
import re, sys

src = open('${INSTALL_DIR}/mgmt_api.py').read()

new_sampler = """_cpu_value = 0.0
_PROXMOX_HOST  = '${PVE_HOST}'
_PROXMOX_TOKEN = '${PVE_TOKEN}'
_PROXMOX_VMID  = ${PVE_VMID}

def _cpu_sampler():
    global _cpu_value
    while True:
        try:
            import ssl, urllib.request, json as _json
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            url = f'https://{_PROXMOX_HOST}:8006/api2/json/nodes/pve/lxc/{_PROXMOX_VMID}/status/current'
            req = urllib.request.Request(url, headers={'Authorization': _PROXMOX_TOKEN})
            with urllib.request.urlopen(req, timeout=5, context=ctx) as r:
                d = _json.loads(r.read())
                _cpu_value = round(d['data']['cpu'] * 100, 1)
        except Exception:
            pass
        time.sleep(10)"""

src = re.sub(
    r'_cpu_value = 0\.0\ndef _cpu_sampler\(\):.*?(?=_threading\.Thread)',
    new_sampler + '\n',
    src, count=1, flags=re.DOTALL
)

open('${INSTALL_DIR}/mgmt_api.py', 'w').write(src)

import ast
try:
    ast.parse(src)
    print('\033[0;32m[ OK ]\033[0m  Proxmox CPU polling configured')
except SyntaxError as e:
    print(f'\033[1;33m[WARN]\033[0m  Syntax check failed: {e} — check mgmt_api.py manually')
PYEOF
  fi # PROXMOX_OK
fi # USE_PROXMOX

# ── Initial config files ──────────────────────────────────────────────────────
banner "Initial configuration"

PASS_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('${ADMIN_PASS}'.encode()).hexdigest())")

cat > "${INSTALL_DIR}/cfg/users.json" << EOF
{"${ADMIN_USER}": {"password": "${PASS_HASH}", "role": "admin", "created": $(date +%s)}}
EOF
ok "Admin user '${ADMIN_USER}' created"

cat > "${INSTALL_DIR}/cfg/server_cfg.ini" << EOF
[SERVER]
ADMIN_PASSWORD=${ADMIN_PASS}
NAME=${SERVER_NAME}
CARS=ks_ferrari_f40
TRACK=ks_silverstone
CONFIG_TRACK=
; Note: Default track/car above requires Kunos content.
; Set up a Schedule in the panel to override with your own content.
MAX_CLIENTS=${MAX_CLIENTS}
UDP_PORT=${AC_UDP_PORT}
TCP_PORT=${AC_TCP_PORT}
HTTP_PORT=${AC_HTTP_PORT}
REGISTER_TO_LOBBY=0
PICKUP_MODE_ENABLED=1
SLEEP_TIME=1
CLIENT_SEND_INTERVAL_HZ=18
SEND_BUFFER_SIZE=0
RECV_BUFFER_SIZE=0
RACE_OVER_TIME=30
KICK_QUORUM=80
VOTING_QUORUM=80
VOTE_DURATION=20
BLACKLIST_MODE=0
FUEL_RATE=1
DAMAGE_MULTIPLIER=0
TYRE_WEAR_RATE=1
ALLOWED_TYRES_OUT=2
ABS_ALLOWED=1
TC_ALLOWED=1
STABILITY_ALLOWED=0
AUTOCLUTCH_ALLOWED=1
TYRE_BLANKETS_ALLOWED=0
FORCE_VIRTUAL_MIRROR=0
RACE_PIT_WINDOW_START=0
RACE_PIT_WINDOW_END=0
REVERSED_GRID_RACE_POSITIONS=0
TIME_OF_DAY_MULT=1
RESULT_SCREEN_TIME=30
MAX_CONTACTS_PER_KM=0
LOOP_MODE=1
SHOW_IN_LOBBY=0

[WEATHER_0]
GRAPHICS=3_clear
BASE_TEMPERATURE_AMBIENT=18
BASE_TEMPERATURE_ROAD=6
VARIATION_AMBIENT=2
VARIATION_ROAD=1
WIND_BASE_SPEED_MIN=0
WIND_BASE_SPEED_MAX=10
WIND_BASE_DIRECTION=0
WIND_VARIATION_DIRECTION=0
EOF
ok "server_cfg.ini written"

cat > "${INSTALL_DIR}/cfg/entry_list.ini" << 'EOF'
[CAR_0]
MODEL=ks_ferrari_f40
SKIN=
SPECTATOR_MODE=0
DRIVERNAME=
TEAM=
GUID=
BALLAST=0
RESTRICTOR=0
EOF
ok "entry_list.ini written"

cat > "${INSTALL_DIR}/cfg/extra_cfg.yml" << EOF
# AssettoServer extra configuration
EnableRaceControl: true
AdminPassword: ${ADMIN_PASS}
EnableAlternativeCarChecksums: false
IgnoreConfigurationErrors:
  MissingCarChecksums: true
  MissingCarEtcChecksums: true
  MissingCarEtcFolder: true
  MissingDefaultSetup: true
  MissingTrackParams: true
  MissingAiSpline: true
  UnsignedConfigurationFile: true
  BrakePowerModifier: true
  TyreBlanketNotAllowed: true
  UnsafeAdminWhitelist: false
  WrongServerDetails: false
EOF
ok "extra_cfg.yml written"

cat > "${INSTALL_DIR}/cfg/schedule.json" << 'EOF'
{"events": [], "active": false, "loop": false}
EOF
ok "schedule.json written"

cat > "${INSTALL_DIR}/cfg/schedule_state.json" << 'EOF'
{"current_index": 0, "running": false}
EOF
ok "schedule_state.json written"

cat > "${INSTALL_DIR}/cfg/ha_settings.json" << 'EOF'
{"enabled": false, "url": "", "token": "", "interval": 30}
EOF
ok "ha_settings.json written"

cat > "${INSTALL_DIR}/cfg/car_filters.json" << 'EOF'
[]
EOF
ok "car_filters.json written"

cat > "${INSTALL_DIR}/cfg/discord_cfg.json" << 'EOF'
{"enabled": false, "webhook_url": "", "server_name": ""}
EOF
ok "discord_cfg.json written"

touch "${INSTALL_DIR}/cfg/admins.txt"
ok "admins.txt created"

# ── Systemd services ──────────────────────────────────────────────────────────
banner "Systemd services"

cat > /etc/systemd/system/assettoserver.service << EOF
[Unit]
Description=Assetto Corsa Dedicated Server
After=network.target

[Service]
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/AssettoServer
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
ok "assettoserver.service"

cat > /etc/systemd/system/acadmin-api.service << EOF
[Unit]
Description=AC Admin Management API
After=network.target

[Service]
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 -u ${INSTALL_DIR}/mgmt_api.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
ok "acadmin-api.service"

cat > /etc/systemd/system/acadmin-web.service << EOF
[Unit]
Description=AC Admin Web Panel
After=network.target acadmin-api.service

[Service]
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 -u ${INSTALL_DIR}/webserver.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
ok "acadmin-web.service"

systemctl daemon-reload
systemctl enable assettoserver acadmin-api acadmin-web
systemctl start acadmin-api acadmin-web
ok "Services enabled and started"
info "assettoserver will start once you have content installed"

# ── Syncthing ─────────────────────────────────────────────────────────────────
if [[ "$USE_SYNCTHING" =~ ^[Yy]$ ]]; then
  banner "Syncthing"
  info "Installing Syncthing..."

  curl -fsSL https://syncthing.net/release-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/syncthing-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/syncthing-archive-keyring.gpg] \
    https://apt.syncthing.net/ syncthing stable" \
    > /etc/apt/sources.list.d/syncthing.list
  apt-get update -qq
  apt-get install -y -qq syncthing
  ok "Syncthing installed"

  # Create any missing sync folders
  for FPATH in "${SYNC_FOLDERS[@]}"; do
    mkdir -p "$FPATH"
  done

  # Generate config by running briefly
  info "Generating Syncthing config..."
  ST_CONFIG="/root/.local/share/syncthing"
  timeout 5 syncthing --home="$ST_CONFIG" --no-browser 2>/dev/null || true
  sleep 2

  # Open GUI to all interfaces (LAN reachable)
  if [ -f "$ST_CONFIG/config.xml" ]; then
    python3 -c "
import sys
cfg = open('$ST_CONFIG/config.xml').read()
cfg = cfg.replace('<address>127.0.0.1:8384</address>', '<address>0.0.0.0:8384</address>')
open('$ST_CONFIG/config.xml', 'w').write(cfg)
"
    ok "GUI accessible on port 8384"
  else
    warn "Syncthing config not found — GUI may only be accessible on localhost"
    warn "Run: sed -i 's|127.0.0.1:8384|0.0.0.0:8384|' /root/.local/share/syncthing/config.xml"
  fi

  # Inject receive-only folder entries
  if [ ${#SYNC_FOLDERS[@]} -gt 0 ] && [ -f "$ST_CONFIG/config.xml" ]; then
    FOLDER_XML=""
    for i in "${!SYNC_FOLDERS[@]}"; do
      FPATH="${SYNC_FOLDERS[$i]}"
      FLABEL="${SYNC_LABELS[$i]}"
      FID=$(echo "$FLABEL" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
      FOLDER_XML="${FOLDER_XML}
    <folder id=\"${FID}\" label=\"${FLABEL}\" path=\"${FPATH}\" type=\"receiveonly\" rescanIntervalS=\"3600\" fsWatcherEnabled=\"true\" fsWatcherDelayS=\"10\">
      <filesystemType>basic</filesystemType>
      <ignorePerms>false</ignorePerms>
      <autoNormalize>true</autoNormalize>
      <minDiskFree unit=\"%\">1</minDiskFree>
      <versioning></versioning>
      <order>random</order>
      <ignoreDelete>false</ignoreDelete>
      <paused>false</paused>
      <markerName>.stfolder</markerName>
    </folder>"
    done
    # Use python to inject folder XML safely (avoids sed delimiter conflicts with paths)
    python3 << STEOF
import re
cfg = open('$ST_CONFIG/config.xml').read()
folder_xml = """${FOLDER_XML}"""
cfg = cfg.replace('</configuration>', folder_xml + '\n</configuration>', 1)
open('$ST_CONFIG/config.xml', 'w').write(cfg)
print("  Folders written to config")
STEOF
    ok "${#SYNC_FOLDERS[@]} receive-only folder(s) configured"
  fi

  # Systemd service
  cat > /etc/systemd/system/syncthing.service << EOF
[Unit]
Description=Syncthing — Content Sync
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/syncthing --home=${ST_CONFIG} --no-browser --logflags=0
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable syncthing
  systemctl start syncthing
  sleep 3

  # Extract the generated API key and patch it into mgmt_api.py
  ST_API_KEY=$(grep -o 'apikey>[^<]*' "$ST_CONFIG/config.xml" 2>/dev/null | head -1 | cut -d'>' -f2)
  if [ -n "$ST_API_KEY" ] && [ -f "${INSTALL_DIR}/mgmt_api.py" ]; then
    python3 << PYEOF
import re
src = open('${INSTALL_DIR}/mgmt_api.py').read()
src = re.sub(r"SYNCTHING_KEY = '[^']*'", "SYNCTHING_KEY = '${ST_API_KEY}'", src)
open('${INSTALL_DIR}/mgmt_api.py', 'w').write(src)
print("  Syncthing API key patched into mgmt_api.py")
PYEOF
    systemctl restart acadmin-api 2>/dev/null || true
  else
    warn "Could not read Syncthing API key — update SYNCTHING_KEY in mgmt_api.py manually"
  fi

  DEVICE_ID=$(syncthing --home="$ST_CONFIG" --device-id 2>/dev/null || echo "Check GUI")
  ok "Syncthing running"

  echo ""
  echo -e "${BOLD}${CYAN}"
  echo "  ┌─────────────────────────────────────────────────────────────────┐"
  echo "  │  🔄  Syncthing Setup — Action Required                          │"
  echo "  ├─────────────────────────────────────────────────────────────────┤"
  echo -e "  │  Open in your browser:  http://${LOCAL_IP}:8384                │"
  echo "  │                                                                 │"
  echo "  │  Then on your PC / NAS:                                         │"
  echo "  │  1. Open Syncthing                                              │"
  echo "  │  2. Add Remote Device → paste the Device ID below              │"
  echo "  │  3. Share your folders with this server                         │"
  echo "  │  4. In the server GUI, accept the incoming connection           │"
  echo "  │  5. Set folder type to Send Only on the PC side                 │"
  echo "  │                                                                 │"
  echo "  │  Device ID:                                                     │"
  echo "  │  ${DEVICE_ID}  │"
  echo "  └─────────────────────────────────────────────────────────────────┘"
  echo -e "${NC}"
  echo ""
  read -rp "  Press ENTER to continue once you have noted the Device ID..." _

  ufw allow 8384/tcp > /dev/null 2>&1 || true
  ufw allow 22000/tcp > /dev/null 2>&1 || true
  ufw allow 22000/udp > /dev/null 2>&1 || true
fi

# ── Cloudflare Tunnel ─────────────────────────────────────────────────────────
if [[ "$USE_CF" =~ ^[Yy]$ ]] && [[ -n "$CF_TOKEN" ]]; then
  banner "Cloudflare Tunnel"
  info "Installing cloudflared..."
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | \
    gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg 2>/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -qq && apt-get install -y -qq cloudflared
  cloudflared service install "$CF_TOKEN" && ok "Cloudflare Tunnel installed" || \
    warn "Tunnel install failed — check your token"
  warn "Configure a public hostname in Zero Trust dashboard pointing to http://localhost:${WEB_PORT}"
fi

# ── Firewall ──────────────────────────────────────────────────────────────────
banner "Firewall"
ufw --force enable > /dev/null 2>&1 || true
ufw allow ssh               > /dev/null 2>&1
ufw allow "${AC_TCP_PORT}/tcp"   > /dev/null 2>&1
ufw allow "${AC_UDP_PORT}/udp"   > /dev/null 2>&1
ufw allow "${AC_HTTP_PORT}/tcp"  > /dev/null 2>&1
ufw allow "${WEB_PORT}/tcp"      > /dev/null 2>&1
ufw allow "${MGMT_PORT}/tcp"     > /dev/null 2>&1
if [[ "$USE_SYNCTHING" =~ ^[Yy]$ ]]; then
  ufw allow 8384/tcp  > /dev/null 2>&1
  ufw allow 22000/tcp > /dev/null 2>&1
  ufw allow 22000/udp > /dev/null 2>&1
fi
ok "Firewall rules applied"

# ── Verify ────────────────────────────────────────────────────────────────────
banner "Verification"
sleep 3
for SVC in acadmin-api acadmin-web; do
  STATUS=$(systemctl is-active "$SVC" 2>/dev/null || echo "unknown")
  if [[ "$STATUS" == "active" ]]; then
    ok "$SVC is running"
  else
    warn "$SVC is not running — check: journalctl -u $SVC -n 30 --no-pager"
  fi
done

# ── Done ──────────────────────────────────────────────────────────────────────
LOCAL_IP=$(hostname -I | awk '{print $1}')

# Build the direct panel URL
PANEL_URL="http://${LOCAL_IP}:${WEB_PORT}/ac-admin.html"

# Build FQDN URL if Cloudflare was configured
CF_URL=""
if [[ "$USE_CF" =~ ^[Yy]$ ]] && [[ -n "$CF_HOSTNAME" ]]; then
  CF_URL="https://${CF_HOSTNAME}/ac-admin.html"
fi

# Get Syncthing device ID if installed
ST_DEVICE_ID=""
if [[ "$USE_SYNCTHING" =~ ^[Yy]$ ]]; then
  ST_DEVICE_ID=$(syncthing --home=/root/.local/share/syncthing --device-id 2>/dev/null || echo "Check http://${LOCAL_IP}:8384 → Actions → Show ID")
fi

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║                   Install Complete! 🏁                           ║"
echo "  ╠══════════════════════════════════════════════════════════════════╣"
echo "  ║  ACCESS THE PANEL                                                ║"
echo -e "  ║  Local:   ${PANEL_URL}          ║"
if [[ -n "$CF_URL" ]]; then
echo -e "  ║  Public:  ${CF_URL}            ║"
fi
echo "  ╠══════════════════════════════════════════════════════════════════╣"
echo "  ║  SERVICES                                                        ║"
echo -e "  ║  AC Game Server:  ${LOCAL_IP}:${AC_TCP_PORT} TCP+UDP                  ║"
echo -e "  ║  Web Panel API:   http://${LOCAL_IP}:${MGMT_PORT} (internal)          ║"
if [[ "$USE_SYNCTHING" =~ ^[Yy]$ ]]; then
echo -e "  ║  Syncthing GUI:   http://${LOCAL_IP}:8384                        ║"
fi
echo "  ╠══════════════════════════════════════════════════════════════════╣"
echo "  ║  LOGIN                                                           ║"
echo -e "  ║  Username: ${ADMIN_USER}                                              ║"
echo "  ║  Password: (the password you entered during setup)               ║"
echo "  ╠══════════════════════════════════════════════════════════════════╣"
if [[ "$USE_SYNCTHING" =~ ^[Yy]$ ]] && [[ -n "$ST_DEVICE_ID" ]]; then
echo "  ║  SYNCTHING DEVICE ID (add this to Syncthing on your PC)         ║"
echo "  ║                                                                  ║"
echo -e "  ║  ${ST_DEVICE_ID:0:63} ║"
echo "  ╠══════════════════════════════════════════════════════════════════╣"
fi
echo "  ║  NEXT STEPS                                                      ║"
echo "  ║  1. Open the panel URL above and log in                          ║"
echo "  ║  2. Add car & track content (via Syncthing or manual upload)     ║"
echo "  ║  3. Go to Schedule → add events using your installed content     ║"
echo "  ║  4. Start the schedule — AssettoServer will launch automatically ║"
echo -e "  ║  5. Port-forward ${AC_TCP_PORT} TCP+UDP on your router for players      ║"
if [[ "$USE_CF" =~ ^[Yy]$ ]]; then
echo "  ║  5. Configure your Cloudflare hostname in Zero Trust dashboard   ║"
fi
if [[ "$USE_SYNCTHING" =~ ^[Yy]$ ]]; then
echo "  ║  5. Add this server as a device in Syncthing on your PC         ║"
fi
echo "  ╠══════════════════════════════════════════════════════════════════╣"
echo "  ║  USEFUL COMMANDS                                                 ║"
echo "  ║  journalctl -u acadmin-api -f        (API logs)                  ║"
echo "  ║  journalctl -u assettoserver -f      (AC server logs)            ║"
echo "  ║  systemctl restart acadmin-api       (restart after updates)     ║"
if [[ "$USE_SYNCTHING" =~ ^[Yy]$ ]]; then
echo "  ║  systemctl status syncthing          (sync status)               ║"
fi
echo "  ╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
