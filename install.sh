#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  AC Admin — Assetto Corsa Dedicated Server + Custom Management Panel
#  Install Script for Ubuntu 22.04 / 24.04 LXC (Proxmox)
#
#  Usage (one-liner):
#    bash <(wget -qO- https://raw.githubusercontent.com/YOURUSER/YOURREPO/main/install.sh)
#
#  Or download and run:
#    wget https://raw.githubusercontent.com/YOURUSER/YOURREPO/main/install.sh
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
if [[ "$USE_CF" =~ ^[Yy]$ ]]; then
  echo "  Get your token from: https://one.dash.cloudflare.com → Networks → Tunnels"
  read -rp "  Cloudflare tunnel token: " CF_TOKEN
  [[ -z "$CF_TOKEN" ]] && warn "No token provided — skipping Cloudflare setup" && USE_CF="n"
fi

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
if [[ "$USE_CF" =~ ^[Yy]$ ]]; then
  echo "  Cloudflare:    Yes"
else
  echo "  Cloudflare:    No"
fi
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
assets=[a for a in data.get('assets',[]) if 'linux' in a['name'].lower() and a['name'].endswith('.tar.gz')]
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

# ── Initial config files ──────────────────────────────────────────────────────
banner "Initial configuration"

PASS_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('${ADMIN_PASS}'.encode()).hexdigest())")

cat > "${INSTALL_DIR}/cfg/users.json" << EOF
{"${ADMIN_USER}": {"password": "${PASS_HASH}", "role": "admin", "created": $(date +%s)}}
EOF
ok "Admin user '${ADMIN_USER}' created"

cat > "${INSTALL_DIR}/cfg/server_cfg.ini" << EOF
[SERVER]
NAME=${SERVER_NAME}
CARS=ks_ferrari_f40
TRACK=ks_silverstone
CONFIG_TRACK=
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

cat > "${INSTALL_DIR}/cfg/extra_cfg.yml" << 'EOF'
# AssettoServer extra configuration
EnableRaceControl: true
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
ufw allow ssh              > /dev/null 2>&1
ufw allow "${AC_TCP_PORT}/tcp"  > /dev/null 2>&1
ufw allow "${AC_UDP_PORT}/udp"  > /dev/null 2>&1
ufw allow "${AC_HTTP_PORT}/tcp" > /dev/null 2>&1
ufw allow "${WEB_PORT}/tcp"     > /dev/null 2>&1
ufw allow "${MGMT_PORT}/tcp"    > /dev/null 2>&1
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
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║                    Install Complete! 🏁                      ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo -e "  ║  Web Panel:  http://${LOCAL_IP}:${WEB_PORT}                          ║"
echo -e "  ║  API:        http://${LOCAL_IP}:${MGMT_PORT}                         ║"
echo -e "  ║  AC Ports:   ${AC_TCP_PORT} TCP + ${AC_UDP_PORT} UDP (forward on router)   ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  Login:      ${ADMIN_USER} / (your chosen password)               ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  Next steps:                                                 ║"
echo "  ║  1. Open the web panel and log in                            ║"
echo "  ║  2. Upload car & track content via the panel                 ║"
echo "  ║  3. Configure and start the AC server                        ║"
echo -e "  ║  4. Port-forward ${AC_TCP_PORT} TCP+UDP on your router               ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  Useful commands:                                            ║"
echo "  ║  journalctl -u acadmin-api -f      (API logs)                ║"
echo "  ║  journalctl -u assettoserver -f    (AC server logs)          ║"
echo "  ║  systemctl restart acadmin-api     (restart after updates)   ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
