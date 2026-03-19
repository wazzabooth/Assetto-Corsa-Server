#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  AC Admin — Update Script
#  Updates app files to latest version from GitHub
#  Leaves all config, content, lap times and settings untouched
#
#  Usage:
#    bash <(wget -qO- https://raw.githubusercontent.com/wazzabooth/Assetto-Corsa-Server/main/update.sh)
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERR ]${NC}  $*"; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/assettoserver"
REPO_BASE="https://raw.githubusercontent.com/wazzabooth/Assetto-Corsa-Server/main"

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run as root: sudo bash update.sh"

# ── Check install dir exists ──────────────────────────────────────────────────
[[ ! -d "$INSTALL_DIR" ]] && error "AC Admin not found at $INSTALL_DIR — run install.sh first"

# ── Welcome ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         AC Admin — Update Script                     ║"
echo "  ║         Config, content and lap times untouched      ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "  Updating from: $REPO_BASE"
echo "  Install dir:   $INSTALL_DIR"
echo ""
read -rp "  Proceed with update? [Y/n]: " CONFIRM
[[ "${CONFIRM:-y}" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ── Backup current files ──────────────────────────────────────────────────────
BACKUP_DIR="${INSTALL_DIR}/backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
for FILE in mgmt_api.py ac-admin.html webserver.py; do
  [[ -f "${INSTALL_DIR}/${FILE}" ]] && cp "${INSTALL_DIR}/${FILE}" "${BACKUP_DIR}/${FILE}"
done
ok "Current files backed up to $BACKUP_DIR"

# ── Stop services ─────────────────────────────────────────────────────────────
info "Stopping services..."
systemctl stop acadmin-api acadmin-web 2>/dev/null || true
ok "Services stopped"

# ── Download latest files ─────────────────────────────────────────────────────
info "Downloading latest files..."
for FILE in mgmt_api.py ac-admin.html webserver.py; do
  info "  Downloading ${FILE}..."
  wget -q -O "${INSTALL_DIR}/${FILE}" "${REPO_BASE}/${FILE}" || {
    warn "Failed to download ${FILE} — restoring backup"
    cp "${BACKUP_DIR}/${FILE}" "${INSTALL_DIR}/${FILE}"
    systemctl start acadmin-api acadmin-web 2>/dev/null || true
    error "Update failed — rolled back to previous version"
  }
  [[ ! -s "${INSTALL_DIR}/${FILE}" ]] && {
    warn "${FILE} is empty — restoring backup"
    cp "${BACKUP_DIR}/${FILE}" "${INSTALL_DIR}/${FILE}"
    systemctl start acadmin-api acadmin-web 2>/dev/null || true
    error "Update failed — rolled back to previous version"
  }
  ok "  ${FILE}"
done

chmod +x "${INSTALL_DIR}/mgmt_api.py"
chmod +x "${INSTALL_DIR}/webserver.py"

# ── Restart services ──────────────────────────────────────────────────────────
info "Restarting services..."
systemctl start acadmin-api acadmin-web
sleep 3

for SVC in acadmin-api acadmin-web; do
  STATUS=$(systemctl is-active "$SVC" 2>/dev/null || echo "unknown")
  if [[ "$STATUS" == "active" ]]; then
    ok "$SVC is running"
  else
    warn "$SVC failed to start — check: journalctl -u $SVC -n 30 --no-pager"
  fi
done

# ── Done ──────────────────────────────────────────────────────────────────────
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║                    Update Complete! 🏁                       ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo -e "  ║  Web Panel:  http://${LOCAL_IP}:8082                          ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  Previous version backed up to:                              ║"
echo "  ║  ${BACKUP_DIR}"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║  To rollback:                                                ║"
echo "  ║  cp ${BACKUP_DIR}/* ${INSTALL_DIR}/     ║"
echo "  ║  systemctl restart acadmin-api acadmin-web                   ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
