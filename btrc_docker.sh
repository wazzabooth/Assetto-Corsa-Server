#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  BTRC Dashboard — Full auto install + run
#  Tested on Ubuntu 22.04 / 24.04 and Debian 11 / 12
#
#  Run:  bash btrc_docker.sh
#
#  Installs: curl, Docker (official), then builds and starts the
#  dashboard container. Nothing else needed.
# ═══════════════════════════════════════════════════════════════════

set -e

# ── Colours ──────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; AMBER='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
info() { echo -e "  ${CYAN}→${NC}  $*"; }
warn() { echo -e "  ${AMBER}!${NC}  $*"; }
die()  { echo -e "\n  ${RED}✗  ERROR: $*${NC}\n"; exit 1; }
hdr()  { echo -e "\n  ${BOLD}$*${NC}"; echo "  ──────────────────────────────────────────"; }

hdr "🏁  BTRC Dashboard — Auto Setup"
echo ""


# ── Detect OS ────────────────────────────────────────────
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="$ID"             # ubuntu / debian / linuxmint etc
  OS_ID_LIKE="${ID_LIKE:-}"
else
  die "Cannot detect OS. This script supports Ubuntu and Debian."
fi

# Accept ubuntu, debian, and derivatives (linuxmint, pop, etc.)
case "$OS_ID $OS_ID_LIKE" in
  *ubuntu*|*debian*) ;;
  *) die "Unsupported OS: $OS_ID. This script supports Ubuntu and Debian only." ;;
esac

ok "OS detected: $PRETTY_NAME"

# ── Helper: check if a command exists ────────────────────
has() { command -v "$1" &>/dev/null; }

# ════════════════════════════════════════════════════════
#  1. SYSTEM PACKAGES  (curl, ca-certificates, gnupg)
# ════════════════════════════════════════════════════════
hdr "1/3  System packages"

NEED_PKGS=()
has curl             || NEED_PKGS+=(curl)
has gpg              || NEED_PKGS+=(gnupg)
dpkg -s ca-certificates &>/dev/null 2>&1 || NEED_PKGS+=(ca-certificates)

if [ ${#NEED_PKGS[@]} -gt 0 ]; then
  info "Installing: ${NEED_PKGS[*]}"
  SUDO=""; [ "$EUID" -ne 0 ] && SUDO="sudo"
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq "${NEED_PKGS[@]}"
  ok "System packages installed"
else
  ok "System packages already present"
fi

# ════════════════════════════════════════════════════════
#  2. DOCKER
# ════════════════════════════════════════════════════════
hdr "2/3  Docker"

install_docker() {
  SUDO=""; [ "$EUID" -ne 0 ] && SUDO="sudo"
  info "Adding Docker's official GPG key and repo..."

  # Clean up any old/unofficial docker packages
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    $SUDO apt-get remove -y -qq "$pkg" 2>/dev/null || true
  done

  $SUDO install -m 0755 -d /etc/apt/keyrings

  # Pick the right repo URL for ubuntu vs debian
  if [[ "$OS_ID" == "ubuntu" || "$OS_ID_LIKE" == *"ubuntu"* ]]; then
    DOCKER_REPO="https://download.docker.com/linux/ubuntu"
    # linuxmint and similar derivatives report their own VERSION_CODENAME;
    # we need the underlying ubuntu codename
    CODENAME=$(. /etc/upstream-release/lsb-release 2>/dev/null && echo "$DISTRIB_CODENAME" || echo "$UBUNTU_CODENAME" || lsb_release -cs 2>/dev/null || echo "$VERSION_CODENAME")
  else
    DOCKER_REPO="https://download.docker.com/linux/debian"
    CODENAME=$(lsb_release -cs 2>/dev/null || echo "$VERSION_CODENAME")
  fi

  info "Fetching Docker GPG key..."
  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
    | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg

  info "Adding Docker apt repository (${CODENAME})..."
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
${DOCKER_REPO} ${CODENAME} stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

  info "Installing Docker Engine..."
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  # Add current user to docker group so we don't need sudo for docker commands
  if ! groups "$USER" | grep -q '\bdocker\b'; then
    info "Adding $USER to docker group..."
    $SUDO usermod -aG docker "$USER"
    # Apply group without requiring logout by using newgrp via sg
    DOCKER_GROUP_ADDED=true
  fi

  if command -v systemctl &>/dev/null; then
    $SUDO systemctl enable docker --quiet
    $SUDO systemctl start docker
  fi

  ok "Docker installed: $(docker --version 2>/dev/null || sg docker -c 'docker --version')"
}

if has docker; then
  # Docker exists — check it's actually working
  if docker info &>/dev/null 2>&1; then
    ok "Docker already installed and running: $(docker --version | cut -d' ' -f3 | tr -d ',')"
  elif sg docker -c 'docker info' &>/dev/null 2>&1; then
    ok "Docker already installed: $(docker --version | cut -d' ' -f3 | tr -d ',')"
    DOCKER_GROUP_ADDED=true   # user is in group but needs new shell
  else
    warn "Docker found but not responding — attempting fix..."
    $SUDO systemctl start docker
    sleep 2
    docker info &>/dev/null || die "Docker won't start. Try: systemctl status docker"
    ok "Docker started"
  fi
else
  install_docker
fi

# Wrapper so docker works even if group was just added this session
run_docker() {
  if [ "$EUID" -eq 0 ]; then
    docker "$@"
  elif docker "$@" 2>/dev/null; then
    return 0
  else
    sg docker -c "docker $*"
  fi
}

# Quick sanity check
run_docker info > /dev/null || die "Cannot connect to Docker daemon."

# ════════════════════════════════════════════════════════
#  3. BUILD & START THE DASHBOARD
# ════════════════════════════════════════════════════════
hdr "3/3  Dashboard"

DIR="$HOME/btrc-dashboard"
PAGES="$DIR/pages"
IMG_DIR="$PAGES/img"

info "Creating files in $DIR"
mkdir -p "$PAGES" "$IMG_DIR"

# ── Dockerfile ───────────────────────────────────────────
cat > "$DIR/Dockerfile" << 'EOF'
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir flask flask-cors
COPY server.py .
COPY pages/ ./pages/
EXPOSE 5000
CMD ["python3", "server.py"]
EOF

# ── server.py ────────────────────────────────────────────
cat > "$DIR/server.py" << 'EOF'
#!/usr/bin/env python3
from flask import Flask, request, jsonify, send_from_directory
from flask_cors import CORS
from datetime import datetime
import os

app = Flask(__name__)
CORS(app)

state = {"panel": "btrc", "last_changed": datetime.now().isoformat()}

def update(panel):
    state["panel"] = panel
    state["last_changed"] = datetime.now().isoformat()
    print(f"  → Panel: {panel}", flush=True)

@app.route("/webhook", methods=["POST"])
def webhook():
    panel = None
    if request.is_json and request.json:
        panel = request.json.get("panel")
    if not panel:
        panel = request.form.get("panel") or request.args.get("panel")
    if not panel:
        return jsonify({"error": 'Send {"panel": "panel_id"}'}), 400
    update(panel)
    return jsonify({"ok": True, "panel": panel})

@app.route("/current-panel")
def current_panel():
    return jsonify(state)

@app.route("/next", methods=["POST"])
def next_panel():
    update("__next__"); return jsonify({"ok": True})

@app.route("/prev", methods=["POST"])
def prev_panel():
    update("__prev__"); return jsonify({"ok": True})

@app.route("/status")
def status():
    return jsonify({"ok": True, **state})

@app.route("/pages/<path:filename>")
def serve_page(filename):
    return send_from_directory(
        os.path.join(os.path.dirname(__file__), "pages"), filename)

@app.route("/")
def index():
    return send_from_directory(
        os.path.join(os.path.dirname(__file__), "pages"), "dashboard.html")

if __name__ == "__main__":
    print("\n  🏠 BTRC Dashboard — http://0.0.0.0:5000\n", flush=True)
    app.run(host="0.0.0.0", port=5000, debug=False)
EOF

# ── pages/dashboard.html ─────────────────────────────────
cat > "$PAGES/dashboard.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>Home Dashboard</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@300;400;500&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
  <style>
    *,*::before,*::after{box-sizing:border-box;margin:0;padding:0;}
    :root{--bg:#0d0f14;--surface:#151820;--border:#1e2330;--accent:#e8a045;--text:#c8cdd8;--text-dim:#5a6070;--nav-h:68px;--font:'DM Sans',sans-serif;--mono:'DM Mono',monospace;}
    html,body{height:100%;width:100%;overflow:hidden;background:var(--bg);color:var(--text);font-family:var(--font);user-select:none;}
    #app{display:flex;flex-direction:column;height:100vh;width:100vw;}
    #panel-area{flex:1;position:relative;overflow:hidden;}
    .panel{position:absolute;inset:0;opacity:0;pointer-events:none;transition:opacity .4s ease;}
    .panel.active{opacity:1;pointer-events:all;}
    .panel iframe{width:100%;height:100%;border:none;background:var(--bg);}
    #splash{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:8px;opacity:0;pointer-events:none;transition:opacity .4s ease;}
    #splash.visible{opacity:1;}
    #clock{font-family:var(--mono);font-size:clamp(72px,12vw,140px);font-weight:400;letter-spacing:-2px;line-height:1;}
    #date-str{font-size:18px;font-weight:300;color:var(--text-dim);letter-spacing:3px;text-transform:uppercase;}
    #nav{height:var(--nav-h);background:var(--surface);border-top:1px solid var(--border);display:flex;align-items:stretch;flex-shrink:0;}
    .nav-btn{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;cursor:pointer;border:none;background:transparent;color:var(--text-dim);font-family:var(--font);font-size:11px;font-weight:500;letter-spacing:.5px;text-transform:uppercase;transition:background .2s,color .2s;border-top:2px solid transparent;padding:0 8px;}
    .nav-btn:hover{background:var(--border);color:var(--text);}
    .nav-btn.active{color:var(--accent);border-top-color:var(--accent);background:rgba(232,160,69,.06);}
    .nav-icon{font-size:20px;line-height:1;}
    #status-bar{position:fixed;top:10px;right:14px;display:flex;align-items:center;gap:8px;z-index:999;pointer-events:none;}
    #conn-dot{width:6px;height:6px;border-radius:50%;background:var(--text-dim);transition:background .5s;}
    #conn-dot.ok{background:#4caf82;}#conn-dot.error{background:#e05a4e;}
    #mini-clock{font-family:var(--mono);font-size:13px;color:var(--text-dim);}
    #toast{position:fixed;bottom:calc(var(--nav-h)+16px);left:50%;transform:translateX(-50%) translateY(10px);background:var(--surface);border:1px solid var(--border);border-left:3px solid var(--accent);padding:10px 20px;border-radius:10px;font-size:13px;opacity:0;transition:opacity .3s,transform .3s;pointer-events:none;white-space:nowrap;}
    #toast.show{opacity:1;transform:translateX(-50%) translateY(0);}
  </style>
</head>
<body>
<script>
const PANELS=[
  {id:"btrc",      label:"BTRC",     icon:"🚛",url:"/pages/btrc.html"},
  {id:"btrc_race", label:"Race Day", icon:"🏁",url:"/pages/btrc_race.html"},
];
const SERVER="";
const POLL=3000;
</script>
<div id="app">
  <div id="panel-area">
    <div id="splash"><div id="clock">00:00</div><div id="date-str">Loading...</div></div>
  </div>
  <nav id="nav"></nav>
</div>
<div id="status-bar"><div id="conn-dot"></div><div id="mini-clock"></div></div>
<div id="toast"></div>
<script>
const $=id=>document.getElementById(id);
let curId=null,curIdx=0,lastChanged=null,toastT=null,touchX=0;
function build(){
  PANELS.forEach((p,i)=>{
    const div=document.createElement("div");div.className="panel";div.id=`panel-${p.id}`;
    const f=document.createElement("iframe");f.src=p.url;f.title=p.label;f.setAttribute("allow","fullscreen");
    div.appendChild(f);$("panel-area").appendChild(div);
    const btn=document.createElement("button");btn.className="nav-btn";btn.dataset.panelId=p.id;
    btn.innerHTML=`<span class="nav-icon">${p.icon}</span><span>${p.label}</span>`;
    btn.onclick=()=>show(p.id,i);$("nav").appendChild(btn);
  });
}
function show(id,idx){
  if(id===curId)return;
  if(id==="__next__"){idx=(curIdx+1)%PANELS.length;id=PANELS[idx].id;}
  if(id==="__prev__"){idx=(curIdx-1+PANELS.length)%PANELS.length;id=PANELS[idx].id;}
  if(idx===undefined)idx=PANELS.findIndex(p=>p.id===id);
  if(idx===-1){showToast(`⚠️ Unknown panel: ${id}`);return;}
  curId=id;curIdx=idx;
  document.querySelectorAll(".panel").forEach(e=>e.classList.remove("active"));
  document.querySelectorAll(".nav-btn").forEach(e=>e.classList.remove("active"));
  $("splash").classList.remove("visible");
  const pe=$(`panel-${id}`);if(pe)pe.classList.add("active");
  const nb=document.querySelector(`[data-panel-id="${id}"]`);if(nb)nb.classList.add("active");
}
async function poll(){
  try{
    const d=await(await fetch(`${SERVER}/current-panel`,{cache:"no-store"})).json();
    $("conn-dot").className="ok";
    if(d.last_changed!==lastChanged){lastChanged=d.last_changed;show(d.panel);}
  }catch{$("conn-dot").className="error";}
}
function clock(){
  const n=new Date();
  const hm=`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`;
  $("clock").textContent=$("mini-clock").textContent=hm;
  $("date-str").textContent=n.toLocaleDateString("en-GB",{weekday:"long",day:"numeric",month:"long"}).toUpperCase();
}
function showToast(msg,d=3000){$("toast").textContent=msg;$("toast").classList.add("show");clearTimeout(toastT);toastT=setTimeout(()=>$("toast").classList.remove("show"),d);}
document.addEventListener("touchstart",e=>{touchX=e.touches[0].clientX;});
document.addEventListener("touchend",e=>{const dx=e.changedTouches[0].clientX-touchX;if(Math.abs(dx)>80)show(dx<0?"__next__":"__prev__");});
document.addEventListener("keydown",e=>{if(e.key==="ArrowRight")show("__next__");if(e.key==="ArrowLeft")show("__prev__");});
build();clock();$("splash").classList.add("visible");
setInterval(clock,1000);setInterval(poll,POLL);poll();
</script>
</body>
</html>
EOF

# ── pages/btrc.html ──────────────────────────────────────
cat > "$PAGES/btrc.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>BTRC</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Barlow+Condensed:wght@400;600;700;800&family=Barlow:wght@300;400;500&display=swap" rel="stylesheet">
  <style>
    *,*::before,*::after{box-sizing:border-box;margin:0;padding:0;}
    :root{--bg:#0a0b0d;--surface:#111317;--card:#161820;--border:#1e2128;--gold:#f0b429;--gold-dim:#7a5a14;--text:#dde2ee;--text-dim:#525a6e;--text-mid:#8892a4;--H:'Barlow Condensed',sans-serif;--B:'Barlow',sans-serif;--r:8px;}
    html,body{height:100%;background:var(--bg);color:var(--text);font-family:var(--B);overflow:hidden;}
    #page{height:100vh;overflow-y:auto;scrollbar-width:thin;scrollbar-color:var(--border) transparent;}
    #hero{position:relative;height:240px;overflow:hidden;display:flex;align-items:flex-end;background:linear-gradient(135deg,#0f1a2e,#1a0f0a,#0a0f0d);}
    #hero-img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;filter:brightness(.45) saturate(1.2);}
    #hero-overlay{position:absolute;inset:0;background:linear-gradient(to top,var(--bg),transparent 60%);}
    #hero-content{position:relative;z-index:2;padding:0 24px 20px;display:flex;align-items:flex-end;justify-content:space-between;width:100%;}
    #hero-title{font-family:var(--H);font-size:52px;font-weight:800;line-height:.9;text-transform:uppercase;}
    #hero-title span{display:block;font-size:18px;font-weight:400;letter-spacing:4px;color:var(--gold);margin-bottom:4px;}
    #season-badge{font-family:var(--H);font-size:64px;font-weight:800;color:var(--gold);line-height:1;}
    #main{padding:20px 24px 24px;display:grid;grid-template-columns:1fr 1fr;gap:20px;}
    .st{font-family:var(--H);font-size:13px;font-weight:700;letter-spacing:3px;text-transform:uppercase;color:var(--gold);margin-bottom:12px;display:flex;align-items:center;gap:8px;}
    .st::after{content:'';flex:1;height:1px;background:var(--border);}
    #next-race{grid-column:1/-1;background:linear-gradient(135deg,#1a1508,#1f1b0a);border:1px solid var(--gold-dim);border-radius:var(--r);padding:18px 22px;display:flex;align-items:center;gap:24px;position:relative;overflow:hidden;}
    #next-race::before{content:'';position:absolute;left:0;top:0;bottom:0;width:4px;background:var(--gold);}
    #nr-label{font-family:var(--H);font-size:11px;font-weight:700;letter-spacing:3px;color:var(--gold);text-transform:uppercase;}
    #nr-circuit{font-family:var(--H);font-size:32px;font-weight:800;text-transform:uppercase;line-height:1;}
    #nr-date{font-size:14px;color:var(--text-mid);margin-top:2px;}
    #cd{margin-left:auto;text-align:right;}
    #cd-val{font-family:var(--H);font-size:42px;font-weight:800;color:var(--gold);line-height:1;}
    #cd-lbl{font-size:11px;letter-spacing:2px;color:var(--text-dim);text-transform:uppercase;}
    #cal{grid-column:1;}
    .rr{display:flex;align-items:center;gap:14px;padding:10px 14px;border-radius:6px;margin-bottom:4px;border:1px solid transparent;}
    .rr.next{background:var(--card);border-color:var(--gold-dim);}
    .rr.past .rc{color:var(--text-dim);}
    .rn{font-family:var(--H);font-size:11px;font-weight:700;color:var(--text-dim);width:28px;}
    .rr.next .rn{color:var(--gold);}
    .rdot{width:8px;height:8px;border-radius:50%;background:var(--border);}
    .rr.past .rdot{background:var(--text-dim);}
    .rr.next .rdot{background:var(--gold);box-shadow:0 0 8px var(--gold);animation:pulse 2s ease-in-out infinite;}
    .ri{flex:1;min-width:0;}
    .rc{font-family:var(--H);font-size:17px;font-weight:700;text-transform:uppercase;}
    .rm{font-size:12px;color:var(--text-dim);margin-top:1px;}
    .rrnd{font-family:var(--H);font-size:13px;font-weight:600;color:var(--text-dim);}
    .rr.next .rrnd{color:var(--gold);}
    #std{grid-column:2;}
    .dl{font-family:var(--H);font-size:11px;font-weight:700;letter-spacing:2px;text-transform:uppercase;color:var(--text-dim);margin-bottom:8px;margin-top:14px;}
    .dl:first-of-type{margin-top:0;}
    .dr{display:flex;align-items:center;gap:12px;padding:8px 12px;border-radius:6px;margin-bottom:3px;background:var(--card);border:1px solid var(--border);}
    .dp{font-family:var(--H);font-size:20px;font-weight:800;width:28px;text-align:center;}
    .p1{color:#f0b429;}.p2{color:#a8b8c8;}.p3{color:#cd7f32;}.po{color:var(--text-dim);font-size:14px;}
    .dn{flex:1;font-family:var(--H);font-size:17px;font-weight:700;text-transform:uppercase;}
    .dt{font-size:11px;color:var(--text-dim);display:block;font-family:var(--B);font-weight:400;text-transform:none;}
    .cb{font-size:10px;background:rgba(240,180,41,.15);color:var(--gold);border:1px solid var(--gold-dim);padding:2px 6px;border-radius:3px;font-family:var(--H);letter-spacing:1px;text-transform:uppercase;font-weight:700;}
    #imgs{grid-column:1/-1;display:grid;grid-template-columns:repeat(3,1fr);gap:10px;}
    .si{border-radius:var(--r);overflow:hidden;aspect-ratio:16/9;background:linear-gradient(135deg,#111820,#1a1210);position:relative;}
    .si::before{content:'🚛';position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-size:40px;opacity:.15;}
    .si img{width:100%;height:100%;object-fit:cover;position:relative;z-index:1;}
    .sc{position:absolute;bottom:0;left:0;right:0;background:linear-gradient(to top,rgba(0,0,0,.8),transparent);padding:20px 12px 10px;font-family:var(--H);font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:1px;}
    #foot{grid-column:1/-1;display:flex;justify-content:space-between;padding:4px 0;border-top:1px solid var(--border);font-size:11px;color:var(--text-dim);letter-spacing:1px;}
    @keyframes pulse{0%,100%{opacity:1;transform:scale(1);}50%{opacity:.5;transform:scale(1.4);}}
    @keyframes fu{from{opacity:0;transform:translateY(16px);}to{opacity:1;transform:translateY(0);}}
    #main>*{animation:fu .5s ease both;}
    #main>*:nth-child(1){animation-delay:.05s;}#main>*:nth-child(2){animation-delay:.10s;}
    #main>*:nth-child(3){animation-delay:.15s;}#main>*:nth-child(4){animation-delay:.20s;}
    #main>*:nth-child(5){animation-delay:.25s;}
  </style>
</head>
<body>
<div id="page">
  <div id="hero">
    <img id="hero-img" src="img/hero.jpg" alt="" onerror="this.style.display='none'">
    <div id="hero-overlay"></div>
    <div id="hero-content">
      <div id="hero-title"><span>British Truck Racing</span>Championship</div>
      <div id="season-badge">2026</div>
    </div>
  </div>
  <div id="main">
    <div id="next-race">
      <div><div id="nr-label">🏁 Next Race</div></div>
      <div><div id="nr-circuit">—</div><div id="nr-date">—</div></div>
      <div id="cd"><div id="cd-val">—</div><div id="cd-lbl">Days to go</div></div>
    </div>
    <div id="cal"><div class="st">2026 Calendar</div><div id="cal-list"></div></div>
    <div id="std"><div class="st">2025 Final Standings</div><div id="std-list"></div></div>
    <div id="imgs">
      <div class="si"><img src="img/strip1.jpg" alt="" onerror="this.style.display='none'"><div class="sc">Race Action</div></div>
      <div class="si"><img src="img/strip2.jpg" alt="" onerror="this.style.display='none'"><div class="sc">Wheel to Wheel</div></div>
      <div class="si"><img src="img/strip3.jpg" alt="" onerror="this.style.display='none'"><div class="sc">On Track</div></div>
    </div>
    <div id="foot"><span>btrc.co · trucksportuk.com · 2026 season</span><span id="ut">—</span></div>
  </div>
</div>
<script>
const CAL=[
  {date:"2026-04-04",end:"2026-04-05",circuit:"Brands Hatch",rounds:"R1–5",flag:"🏴󠁧󠁢󠁥󠁮󠁧󠁿",layout:"Indy"},
  {date:"2026-05-16",end:"2026-05-17",circuit:"Thruxton",rounds:"R6–10",flag:"🏴󠁧󠁢󠁥󠁮󠁧󠁿",layout:"Circuit"},
  {date:"2026-06-20",end:"2026-06-21",circuit:"Pembrey",rounds:"R11–15",flag:"🏴󠁧󠁢󠁷󠁬󠁳󠁿",layout:"Circuit"},
  {date:"2026-07-11",end:"2026-07-12",circuit:"Snetterton",rounds:"R16–20",flag:"🏴󠁧󠁢󠁥󠁮󠁧󠁿",layout:"300"},
  {date:"2026-08-08",end:"2026-08-09",circuit:"Donington Park",rounds:"R21–25",flag:"🏴󠁧󠁢󠁥󠁮󠁧󠁿",layout:"National"},
  {date:"2026-09-26",end:"2026-09-27",circuit:"Le Mans",rounds:"R26–29",flag:"🇫🇷",layout:"Circuit de la Sarthe"},
  {date:"2026-10-31",end:"2026-11-01",circuit:"Brands Hatch",rounds:"R30–34",flag:"🏴󠁧󠁢󠁥󠁮󠁧󠁿",layout:"Indy · Finale 🎆"},
];
const STD={
  div1:[{pos:1,name:"Ryan Smith",team:"Worldwide Truck Racing",champ:true},{pos:2,name:"Stuart Oliver",team:"Stuart Oliver Racing"},{pos:3,name:"David Jenkins",team:"Jenkins Motorsport"},{pos:4,name:"John Bowler",team:"Bowler Motorsport"},{pos:5,name:"Michael Oliver",team:"Oliver Racing"},{pos:6,name:"Steven Powell",team:"Powell Racing"}],
  div2:[{pos:1,name:"Jake Evans",team:"Evans Racing",champ:true},{pos:2,name:"Callum Eason",team:"Eason Motorsport"},{pos:3,name:"Sami Ojanen",team:"Ojanen Racing"},{pos:4,name:"Bradley Harvey",team:"Harvey Racing"},{pos:5,name:"Simon Cole",team:"Cole Motorsport"}]
};
function pd(s){const d=new Date(s);d.setHours(0,0,0,0);return d;}
function fd(s,e){const a=pd(s),b=pd(e),m=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];return a.getMonth()===b.getMonth()?`${a.getDate()}–${b.getDate()} ${m[a.getMonth()]} ${a.getFullYear()}`:`${a.getDate()} ${m[a.getMonth()]} – ${b.getDate()} ${m[b.getMonth()]} ${b.getFullYear()}`;}
(function(){
  const t=pd(new Date().toISOString().slice(0,10)),list=document.getElementById("cal-list");
  let ns=false;
  CAL.forEach((r,i)=>{
    const s=pd(r.date),e=pd(r.end);
    let st="future";if(e<t)st="past";if(!ns&&s>=t){st="next";ns=true;}
    const row=document.createElement("div");row.className=`rr ${st}`;
    row.innerHTML=`<div class="rn">R${i+1}</div><div class="rdot"></div><div class="ri"><div class="rc">${r.flag} ${r.circuit}</div><div class="rm">${fd(r.date,r.end)} · ${r.layout}</div></div><div class="rrnd">${r.rounds}</div>`;
    list.appendChild(row);
    if(st==="next"){
      document.getElementById("nr-circuit").textContent=r.circuit;
      document.getElementById("nr-date").textContent=fd(r.date,r.end)+" · "+r.layout;
      const days=Math.round((s-t)/(864e5));
      document.getElementById("cd-val").textContent=days<=0?"NOW":days;
      document.getElementById("cd-lbl").textContent=days<=0?"Race weekend!":days===1?"Day to go":"Days to go";
    }
  });
  const sl=document.getElementById("std-list");
  ["div1","div2"].forEach((d,i)=>{
    const lbl=document.createElement("div");lbl.className="dl";lbl.textContent=i===0?"Division 1":"Division 2";sl.appendChild(lbl);
    STD[d].forEach(dr=>{
      const pc=dr.pos===1?"p1":dr.pos===2?"p2":dr.pos===3?"p3":"po";
      const row=document.createElement("div");row.className="dr";
      row.innerHTML=`<div class="dp ${pc}">${dr.pos}</div><div class="dn">${dr.name}<span class="dt">${dr.team}</span></div>${dr.champ?'<div class="cb">Champion</div>':'<div style="font-family:var(--H);font-size:16px;color:var(--text-mid)">P'+dr.pos+'</div>'}`;
      sl.appendChild(row);
    });
  });
  document.getElementById("ut").textContent="Updated "+new Date().toLocaleTimeString("en-GB",{hour:"2-digit",minute:"2-digit"});
})();
</script>
</body>
</html>
EOF

# ── pages/btrc_race.html ─────────────────────────────────
cat > "$PAGES/btrc_race.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>BTRC Race Day</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Barlow+Condensed:wght@400;700;800&family=Share+Tech+Mono&family=Barlow:wght@400;500&display=swap" rel="stylesheet">
  <style>
    *,*::before,*::after{box-sizing:border-box;margin:0;padding:0;}
    :root{--bg:#080a0c;--surface:#0e1014;--card:#13161b;--border:#1c2028;--red:#e63232;--red-dim:#6b1515;--amber:#f0a500;--green:#22c97a;--text:#d8dde8;--text-dim:#4a5260;--text-mid:#7a8494;--M:'Share Tech Mono',monospace;--H:'Barlow Condensed',sans-serif;--B:'Barlow',sans-serif;}
    html,body{height:100%;width:100%;background:var(--bg);color:var(--text);font-family:var(--B);overflow:hidden;}
    body::after{content:'';position:fixed;inset:0;background:repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(0,0,0,.07) 2px,rgba(0,0,0,.07) 4px);pointer-events:none;z-index:9999;}
    #app{display:flex;flex-direction:column;height:100vh;}
    #hdr{height:56px;background:var(--surface);border-bottom:1px solid var(--border);display:flex;align-items:center;padding:0 18px;flex-shrink:0;position:relative;}
    #hdr::before{content:'';position:absolute;left:0;top:0;bottom:0;width:4px;background:var(--red);box-shadow:0 0 12px var(--red);}
    #logo{font-family:var(--H);font-size:26px;font-weight:800;text-transform:uppercase;margin-left:14px;}
    #logo span{color:var(--red);}
    #badge{display:flex;align-items:center;gap:6px;margin-left:16px;background:rgba(230,50,50,.12);border:1px solid var(--red-dim);padding:3px 10px 3px 8px;border-radius:3px;}
    #ldot{width:7px;height:7px;background:var(--red);border-radius:50%;box-shadow:0 0 6px var(--red);animation:blink 1.2s ease-in-out infinite;}
    @keyframes blink{0%,100%{opacity:1;}50%{opacity:.2;}}
    #badge-txt{font-family:var(--H);font-size:12px;font-weight:700;letter-spacing:2px;color:var(--red);text-transform:uppercase;}
    #sess{margin-left:20px;font-family:var(--H);font-size:15px;font-weight:600;color:var(--text-mid);text-transform:uppercase;letter-spacing:1px;}
    #sess strong{color:var(--text);}
    #hdr-r{margin-left:auto;}
    #rclock{font-family:var(--M);font-size:22px;color:var(--amber);}
    #split{flex:1;display:grid;grid-template-columns:1fr 1fr;min-height:0;}
    .pw{display:flex;flex-direction:column;min-height:0;border-right:1px solid var(--border);}
    .pw:last-child{border-right:none;}
    .pl{height:34px;background:var(--card);border-bottom:1px solid var(--border);display:flex;align-items:center;padding:0 14px;gap:8px;flex-shrink:0;}
    .pl-txt{font-family:var(--H);font-size:12px;font-weight:700;letter-spacing:2.5px;text-transform:uppercase;color:var(--text-dim);}
    .pl-sub{margin-left:auto;font-family:var(--M);font-size:11px;color:var(--text-dim);}
    .pc{flex:1;position:relative;min-height:0;}
    .pc iframe{width:100%;height:100%;border:none;display:block;}
    .ph{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;background:var(--surface);}
    .ph-icon{font-size:48px;opacity:.3;}
    .ph-title{font-family:var(--H);font-size:20px;font-weight:700;text-transform:uppercase;letter-spacing:2px;color:var(--text-dim);}
    .ph-sub{font-size:13px;color:var(--text-dim);text-align:center;line-height:1.6;max-width:300px;}
    .ph-code{font-family:var(--M);font-size:12px;background:var(--card);border:1px solid var(--border);padding:8px 14px;border-radius:4px;color:var(--amber);}
    #sbar{height:28px;background:var(--surface);border-top:1px solid var(--border);display:flex;align-items:center;padding:0 14px;gap:24px;flex-shrink:0;}
    .si{display:flex;align-items:center;gap:6px;font-family:var(--M);font-size:11px;color:var(--text-dim);}
    .sd{width:5px;height:5px;border-radius:50%;background:var(--text-dim);}
    .sd.ok{background:var(--green);}.sd.warn{background:var(--amber);}
    #tick{margin-left:auto;font-family:var(--M);font-size:11px;color:var(--text-dim);}
  </style>
</head>
<body>
<div id="app">
  <div id="hdr">
    <div id="logo">BTRC <span>Race Day</span></div>
    <div id="badge"><div id="ldot"></div><div id="badge-txt">Live</div></div>
    <div id="sess"><strong id="sname">Race Weekend</strong> &nbsp;·&nbsp; <span id="cname">—</span></div>
    <div id="hdr-r"><div id="rclock">00:00:00</div></div>
  </div>
  <div id="split">
    <div class="pw">
      <div class="pl"><span>⏱</span><span class="pl-txt">Live Timing</span><span class="pl-sub" id="tsl-lbl">tsl-timing.com</span></div>
      <div class="pc">
        <div class="ph" id="tph">
          <div class="ph-icon">⏱</div><div class="ph-title">No Active Event</div>
          <div class="ph-sub">Set <strong>TSL_EVENT_ID</strong> at the top of this file on race weekends.<br>BARC post the timing link at barc.net/events each race week.</div>
          <div class="ph-code">TSL_EVENT_ID = "<span id="show-tsl">not set</span>"</div>
        </div>
        <iframe id="tframe" title="Live Timing" allow="fullscreen" style="display:none"></iframe>
      </div>
    </div>
    <div class="pw">
      <div class="pl"><span>📺</span><span class="pl-txt">Live Stream</span><span class="pl-sub" id="yt-lbl">youtube / btrc</span></div>
      <div class="pc">
        <div class="ph" id="yph">
          <div class="ph-icon">📺</div><div class="ph-title">No Active Stream</div>
          <div class="ph-sub">Set <strong>YOUTUBE_VIDEO_ID</strong> at the top of this file.<br>Grab the ID from the BTRC YouTube live URL on race day.</div>
          <div class="ph-code">YOUTUBE_VIDEO_ID = "<span id="show-yt">not set</span>"</div>
        </div>
        <iframe id="yframe" title="Live Stream" allow="accelerometer;autoplay;clipboard-write;encrypted-media;gyroscope;picture-in-picture;fullscreen" allowfullscreen style="display:none"></iframe>
      </div>
    </div>
  </div>
  <div id="sbar">
    <div class="si"><div class="sd warn" id="d-t"></div><span id="l-t">Timing: no event set</span></div>
    <div class="si"><div class="sd warn" id="d-s"></div><span id="l-s">Stream: no video set</span></div>
    <div class="si"><div class="sd" id="d-srv"></div><span id="l-srv">Server: checking...</span></div>
    <div id="tick">—</div>
  </div>
</div>
<script>
// ── UPDATE THESE ON RACE WEEKENDS ──────────────────────────
const TSL_EVENT_ID     = "";   // e.g. "254003"
const YOUTUBE_VIDEO_ID = "";   // e.g. "wGrJfWc2yB4"
const SESSION_NAME     = "Race Day";
// ──────────────────────────────────────────────────────────

const RW=[
  {date:"2026-04-04",end:"2026-04-05",circuit:"Brands Hatch"},
  {date:"2026-05-16",end:"2026-05-17",circuit:"Thruxton"},
  {date:"2026-06-20",end:"2026-06-21",circuit:"Pembrey"},
  {date:"2026-07-11",end:"2026-07-12",circuit:"Snetterton 300"},
  {date:"2026-08-08",end:"2026-08-09",circuit:"Donington Park"},
  {date:"2026-09-26",end:"2026-09-27",circuit:"Le Mans"},
  {date:"2026-10-31",end:"2026-11-01",circuit:"Brands Hatch"},
];
const $=id=>document.getElementById(id);
function init(){
  $("show-tsl").textContent=TSL_EVENT_ID||"not set";
  $("show-yt").textContent=YOUTUBE_VIDEO_ID||"not set";
  if(TSL_EVENT_ID){
    $("tframe").src=`https://www.tsl-timing.com/event/${TSL_EVENT_ID}`;
    $("tframe").style.display="block";$("tph").style.display="none";
    $("tsl-lbl").textContent=`event/${TSL_EVENT_ID}`;
    $("d-t").className="sd ok";$("l-t").textContent=`Timing: event ${TSL_EVENT_ID}`;
  }
  if(YOUTUBE_VIDEO_ID){
    $("yframe").src=`https://www.youtube.com/embed/${YOUTUBE_VIDEO_ID}?autoplay=1&rel=0&modestbranding=1`;
    $("yframe").style.display="block";$("yph").style.display="none";
    $("yt-lbl").textContent=`youtu.be/${YOUTUBE_VIDEO_ID}`;
    $("d-s").className="sd ok";$("l-s").textContent=`Stream: ${YOUTUBE_VIDEO_ID}`;
  }
  const t=new Date();t.setHours(0,0,0,0);
  let circuit="Off Season";
  for(const w of RW){
    const s=new Date(w.date);s.setHours(0,0,0,0);const e=new Date(w.end);e.setHours(23,59,59,0);
    if(t>=s&&t<=e){circuit=w.circuit;break;}
  }
  $("cname").textContent=circuit;$("sname").textContent=SESSION_NAME;
}
function tick(){
  const n=new Date();
  const t=`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}:${String(n.getSeconds()).padStart(2,"0")}`;
  $("rclock").textContent=t;$("tick").textContent=`Updated ${t}`;
}
async function pingServer(){
  try{await fetch("/status",{cache:"no-store"});$("d-srv").className="sd ok";$("l-srv").textContent="Server: ok";}
  catch{$("d-srv").className="sd";$("l-srv").textContent="Server: offline";}
}
init();tick();setInterval(tick,1000);setInterval(pingServer,10000);pingServer();
</script>
</body>
</html>
EOF

# ── Build & run ──────────────────────────────────────────
info "Building Docker image (btrc-dashboard)..."
run_docker build -t btrc-dashboard "$DIR" -q

info "Stopping any existing container..."
run_docker rm -f btrc-dashboard 2>/dev/null || true

info "Starting container..."
run_docker run -d \
  --name btrc-dashboard \
  --restart unless-stopped \
  -p 5000:5000 \
  -v "$PAGES:/app/pages" \
  btrc-dashboard > /dev/null

# ── Final output ─────────────────────────────────────────
echo ""
hdr "✅  All done"
echo ""
ok "Container running: btrc-dashboard"
echo ""
echo -e "  ${BOLD}Open in browser:${NC}"
echo "    http://localhost:5000"
echo ""
echo -e "  ${BOLD}Individual pages:${NC}"
echo "    http://localhost:5000/pages/btrc.html"
echo "    http://localhost:5000/pages/btrc_race.html"
echo ""
echo -e "  ${BOLD}Test webhook (switch panel):${NC}"
echo "    curl -X POST http://localhost:5000/webhook \\"
echo "         -H 'Content-Type: application/json' \\"
echo "         -d '{\"panel\":\"btrc_race\"}'"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "    docker logs -f btrc-dashboard    # live logs"
echo "    docker stop btrc-dashboard       # stop"
echo "    docker start btrc-dashboard      # start again"
echo "    docker rm -f btrc-dashboard      # remove"
echo ""
echo -e "  ${BOLD}Add new pages:${NC}"
echo "    Drop .html files into: $PAGES"
echo "    They appear immediately at /pages/filename.html — no restart needed"
echo ""

if [ "${DOCKER_GROUP_ADDED:-false}" = "true" ]; then
  echo -e "  ${AMBER}NOTE:${NC} You were added to the 'docker' group this session."
  echo "  Log out and back in so future docker commands work without sudo."
  echo ""
fi
