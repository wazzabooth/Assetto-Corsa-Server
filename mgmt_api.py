from flask import Flask, request, jsonify, Response, send_file
from flask_cors import CORS
import configparser, os, subprocess, json, psutil, urllib.request, yaml
import hashlib, secrets, time, re


# Background CPU sampler - updates every 5s, stores result for instant reads
import threading as _threading
_cpu_value = 0.0
def _cpu_sampler():
    global _cpu_value
    _cpu_value  # prime it
    while True:
        time.sleep(5)
        _cpu_value = _cpu_value
_threading.Thread(target=_cpu_sampler, daemon=True).start()

app = Flask(__name__)
CORS(app)

CFG          = '/opt/assettoserver/cfg/server_cfg.ini'
EXTRA_CFG    = '/opt/assettoserver/cfg/extra_cfg.yml'
CONTENT      = '/opt/assettoserver/content'
USERS_FILE   = '/opt/assettoserver/cfg/users.json'
PRESETS_DIR  = '/opt/assettoserver/cfg/presets'
HISTORY_FILE = '/opt/assettoserver/cfg/connection_history.json'

SESSIONS = {}
STATE_FILE  = '/opt/assettoserver/cfg/server_state.json'
TRACK_LOG   = '/opt/assettoserver/cfg/track_history.json'

def save_state(track, layout=''):
    try:
        state = {'track': track, 'layout': layout, 'updated': time.strftime('%Y-%m-%d %H:%M:%S')}
        with open(STATE_FILE, 'w') as f:
            json.dump(state, f)
        # Append to track history so lapboard can tag laps by track
        history = []
        if os.path.exists(TRACK_LOG):
            with open(TRACK_LOG) as f:
                history = json.load(f)
        history.append({'track': track, 'layout': layout, 'ts': time.strftime('%Y-%m-%d %H:%M:%S'), 'epoch': int(time.time())})
        # Fire Discord track change notification (skip if same track)
        try:
            prev = history[-2] if len(history) >= 2 else {}
            if prev.get('track') != track or prev.get('layout') != layout:
                threading.Thread(target=discord_track_change, args=(track, layout), daemon=True).start()
        except Exception as _e:
            print(f'discord_track_change hook error: {_e}')
        with open(TRACK_LOG, 'w') as f:
            json.dump(history, f)
    except Exception:
        pass

def load_state():
    try:
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE) as f:
                return json.load(f)
    except Exception:
        pass
    return {'track': 'unknown', 'layout': ''}

def track_at_time(epoch):
    """Return the track that was active at a given unix timestamp."""
    try:
        # Fall back to current server config if no history file
        if not os.path.exists(TRACK_LOG):
            cfg = configparser.RawConfigParser()
            cfg.optionxform = str
            cfg.read(CFG)
            if 'SERVER' in cfg:
                t = cfg['SERVER'].get('TRACK', '')
                l = cfg['SERVER'].get('CONFIG_TRACK', '')
                if t:
                    return f"{t}/{l}" if l else t
            return 'unknown'
        with open(TRACK_LOG) as f:
            history = json.load(f)
        active = None
        for entry in history:
            if entry.get('epoch', 0) <= epoch:
                active = entry
        if active:
            t = active['track']
            l = active.get('layout', '')
            return f"{t}/{l}" if l else t
        if history:
            t = history[0]['track']
            l = history[0].get('layout', '')
            return f"{t}/{l}" if l else t
        # Last resort: read current config
        cfg = configparser.RawConfigParser()
        cfg.optionxform = str
        cfg.read(CFG)
        if 'SERVER' in cfg:
            t = cfg['SERVER'].get('TRACK', '')
            l = cfg['SERVER'].get('CONFIG_TRACK', '')
            if t:
                return f"{t}/{l}" if l else t
    except Exception:
        pass
    return 'unknown'

# ── Users ──────────────────────────────────────────────────────────────────────

def load_users():
    if not os.path.exists(USERS_FILE):
        default = {'admin': {'password': hash_pw('changeme123'), 'role': 'admin', 'created': int(time.time())}}
        save_users(default)
        return default
    with open(USERS_FILE) as f:
        return json.load(f)

def save_users(users):
    with open(USERS_FILE, 'w') as f:
        json.dump(users, f, indent=2)

def hash_pw(p):
    return hashlib.sha256(p.encode()).hexdigest()

def get_session():
    token = request.headers.get('X-Session-Token')
    if not token or token not in SESSIONS:
        return None
    sess = SESSIONS[token]
    if sess['expires'] < time.time():
        del SESSIONS[token]
        return None
    sess['expires'] = time.time() + 86400
    return sess


# ── Discord ───────────────────────────────────────────────────────────────────
def load_discord_cfg():
    if os.path.exists(DISCORD_CFG):
        try: return json.load(open(DISCORD_CFG))
        except Exception: pass
    return {'webhook_url':'','enabled':False,'announce_session':True,
            'announce_track':True,'announce_results':True,'server_name':''}

def save_discord_cfg(cfg):
    os.makedirs(os.path.dirname(DISCORD_CFG), exist_ok=True)
    json.dump(cfg, open(DISCORD_CFG,'w'), indent=2)

def discord_send(embed, content=None):
    cfg = load_discord_cfg()
    if not cfg.get('enabled') or not cfg.get('webhook_url'): return False
    payload = {'embeds':[embed]}
    if content: payload['content'] = content
    try:
        import ssl
        ctx  = ssl.create_default_context()
        data = json.dumps(payload).encode()
        req  = urllib.request.Request(cfg['webhook_url'], data=data,
               headers={'Content-Type':'application/json','User-Agent':'AcAdmin/1.0'}, method='POST')
        resp = urllib.request.urlopen(req, timeout=10, context=ctx)
        return resp.status in (200, 204)
    except urllib.error.HTTPError as e:
        print(f'[Discord] HTTP {e.code}: {e.read().decode()}')
        return False
    except Exception as e:
        print(f'[Discord] {e}')
        return False

def discord_track_change(track, layout, event_name=''):
    cfg = load_discord_cfg()
    if not cfg.get('announce_track'): return
    import datetime
    server = cfg.get('server_name') or 'AC Server'
    title  = event_name or f'{track}' + (f' – {layout}' if layout and layout != 'default' else '')
    discord_send({'title':'🏁  New Event Starting','description':f'**{title}**',
        'color':0xF5A623,'footer':{'text':server},
        'timestamp':datetime.datetime.utcnow().isoformat()+'Z',
        'fields':[{'name':'Track','value':track.replace('_',' ').title(),'inline':True},
                  {'name':'Layout','value':layout or 'Default','inline':True}]})

SESSION_TYPE_NAMES = {1:'Practice',2:'Qualifying',3:'Race',4:'Hotlap',5:'Time Attack'}
SESSION_COLORS     = {1:0x3498DB,2:0xF39C12,3:0xE74C3C}

def discord_session_start(session_type_id):
    cfg = load_discord_cfg()
    if not cfg.get('announce_session'): return
    import datetime
    server = cfg.get('server_name') or 'AC Server'
    name   = SESSION_TYPE_NAMES.get(session_type_id, f'Session {session_type_id}')
    color  = SESSION_COLORS.get(session_type_id, 0x95A5A6)
    emojis = {1:'🔵',2:'🟡',3:'🔴'}
    discord_send({'title':f'{emojis.get(session_type_id,"⚪")}  {name} Started',
        'color':color,'footer':{'text':server},
        'timestamp':datetime.datetime.utcnow().isoformat()+'Z'})

def discord_race_results(results):
    cfg = load_discord_cfg()
    if not cfg.get('announce_results') or not results: return
    import datetime
    server = cfg.get('server_name') or 'AC Server'
    medals = ['🥇','🥈','🥉']
    lines  = [f"{medals[i] if i<3 else f'**{i+1}.**'} **{r.get('driver','—')}**  `{r.get('lap_time','')}` _{r.get('car','').replace('ks_','').replace('_',' ').title()}_"
              for i,r in enumerate(results[:5])]
    discord_send({'title':'\U0001f3c6  Race Results','description':'\n'.join(lines),
        'color':0xF5A623,'footer':{'text':server},
        'timestamp':datetime.datetime.utcnow().isoformat()+'Z'})

def require_auth(role=None):
    sess = get_session()
    if not sess:
        return jsonify({'error': 'unauthorized'}), 401
    if role and sess['role'] != role:
        return jsonify({'error': 'forbidden'}), 403
    return None

# ── Auth ───────────────────────────────────────────────────────────────────────

@app.route('/auth/login', methods=['POST'])
def login():
    data = request.json or {}
    username = data.get('username', '').strip()
    password = data.get('password', '')
    users = load_users()
    user = users.get(username)
    if not user or user['password'] != hash_pw(password):
        return jsonify({'error': 'Invalid username or password'}), 401
    token = secrets.token_hex(32)
    SESSIONS[token] = {'username': username, 'role': user['role'], 'expires': time.time() + 86400}
    return jsonify({'token': token, 'username': username, 'role': user['role']})

@app.route('/auth/logout', methods=['POST'])
def logout():
    token = request.headers.get('X-Session-Token')
    if token and token in SESSIONS:
        del SESSIONS[token]
    return jsonify({'ok': True})

@app.route('/auth/me')
def me():
    sess = get_session()
    if not sess:
        return jsonify({'error': 'unauthorized'}), 401
    return jsonify({'username': sess['username'], 'role': sess['role']})

# ── User management ────────────────────────────────────────────────────────────

@app.route('/mgmt/users', methods=['GET'])
def list_users():
    err = require_auth('admin')
    if err: return err
    users = load_users()
    return jsonify([{'username': k, 'role': v['role'], 'created': v.get('created')} for k, v in users.items()])

@app.route('/mgmt/users', methods=['POST'])
def create_user():
    err = require_auth('admin')
    if err: return err
    data = request.json or {}
    username = data.get('username', '').strip()
    password = data.get('password', '')
    role = data.get('role', 'readonly')
    if not username or not password:
        return jsonify({'error': 'Username and password required'}), 400
    if role not in ('admin', 'readonly'):
        return jsonify({'error': 'Invalid role'}), 400
    users = load_users()
    if username in users:
        return jsonify({'error': 'User already exists'}), 409
    users[username] = {'password': hash_pw(password), 'role': role, 'created': int(time.time())}
    save_users(users)
    return jsonify({'ok': True})

@app.route('/mgmt/users/<username>', methods=['PUT'])
def update_user(username):
    err = require_auth('admin')
    if err: return err
    data = request.json or {}
    users = load_users()
    if username not in users:
        return jsonify({'error': 'User not found'}), 404
    if users[username]['role'] == 'admin':
        admins = [u for u, v in users.items() if v['role'] == 'admin']
        if len(admins) == 1 and data.get('role') == 'readonly':
            return jsonify({'error': 'Cannot demote the last admin'}), 400
    if 'password' in data and data['password']:
        users[username]['password'] = hash_pw(data['password'])
    if 'role' in data:
        users[username]['role'] = data['role']
    save_users(users)
    return jsonify({'ok': True})

@app.route('/mgmt/users/<username>', methods=['DELETE'])
def delete_user(username):
    err = require_auth('admin')
    if err: return err
    sess = get_session()
    if sess['username'] == username:
        return jsonify({'error': 'Cannot delete your own account'}), 400
    users = load_users()
    if username not in users:
        return jsonify({'error': 'User not found'}), 404
    admins = [u for u, v in users.items() if v['role'] == 'admin']
    if users[username]['role'] == 'admin' and len(admins) == 1:
        return jsonify({'error': 'Cannot delete the last admin'}), 400
    del users[username]
    save_users(users)
    return jsonify({'ok': True})


@app.route('/mgmt/track-preview/<path:track>')
def track_preview(track):
    layout = request.args.get('layout', '')
    base   = os.path.join(CONTENT, 'tracks', track)

    # If the track directory doesn't exist and no layout supplied,
    # try treating the last hyphen-segment as the layout name
    if not os.path.isdir(base) and not layout:
        parts = track.rsplit('-', 1)
        if len(parts) == 2:
            candidate_track, candidate_layout = parts
            candidate_base = os.path.join(CONTENT, 'tracks', candidate_track)
            if os.path.isdir(candidate_base):
                track  = candidate_track
                layout = candidate_layout
                base   = candidate_base

    candidates = []
    if layout:
        candidates.append(os.path.join(base, 'ui', layout, 'preview.png'))
    candidates.append(os.path.join(base, 'ui', 'preview.png'))
    for p in candidates:
        if os.path.exists(p):
            return send_file(p, mimetype='image/png')
    return ('', 404)


@app.route('/mgmt/track-outline/<path:track>')
def track_outline(track):
    layout = request.args.get('layout', '')
    base   = os.path.join(CONTENT, 'tracks', track)

    if not os.path.isdir(base) and not layout:
        parts = track.rsplit('-', 1)
        if len(parts) == 2:
            candidate_track, candidate_layout = parts
            candidate_base = os.path.join(CONTENT, 'tracks', candidate_track)
            if os.path.isdir(candidate_base):
                track  = candidate_track
                layout = candidate_layout
                base   = candidate_base

    candidates = []
    if layout:
        candidates.append(os.path.join(base, 'ui', layout, 'outline.png'))
    candidates.append(os.path.join(base, 'ui', 'outline.png'))
    for p in candidates:
        if os.path.exists(p):
            return send_file(p, mimetype='image/png')
    return ('', 404)


@app.route('/mgmt/tracks')
def list_tracks():
    err = require_auth()
    if err: return err
    tracks = []
    tracks_dir = os.path.join(CONTENT, 'tracks')
    if os.path.exists(tracks_dir):
        for t in sorted(os.listdir(tracks_dir)):
            t_dir = os.path.join(tracks_dir, t)
            if os.path.isdir(t_dir):
                layouts = []
                ui_dir = os.path.join(t_dir, 'ui')
                if os.path.exists(ui_dir):
                    for item in os.listdir(ui_dir):
                        if os.path.isdir(os.path.join(ui_dir, item)):
                            layouts.append(item)
                # Track requires a layout if it has no root data/surfaces.ini
                has_root_data = os.path.exists(os.path.join(t_dir, 'data', 'surfaces.ini'))
                requires_layout = not has_root_data and len(layouts) > 0
                tracks.append({'id': t, 'layouts': layouts, 'requires_layout': requires_layout})
    return jsonify(tracks)

@app.route('/mgmt/cars')
def list_cars():
    err = require_auth()
    if err: return err
    cars = []
    cars_dir = os.path.join(CONTENT, 'cars')
    if os.path.exists(cars_dir):
        for c in sorted(os.listdir(cars_dir)):
            if not os.path.isdir(os.path.join(cars_dir, c)) or c.startswith('.'): continue
            has_badge = os.path.exists(os.path.join(cars_dir, c, 'ui', 'badge.png'))
            tags = []
            car_class = ''
            ui_path = os.path.join(cars_dir, c, 'ui', 'ui_car.json')
            try:
                raw = open(ui_path, encoding='utf-8', errors='ignore').read()
                clean = ''.join(ch if ord(ch) >= 32 else ' ' for ch in raw)
                d = json.loads(clean)
                tags = [str(t).strip().lower() for t in (d.get('tags') or []) if t]
                car_class = (d.get('class') or '').strip().lower()
            except: pass
            cars.append({'id': c, 'has_badge': has_badge, 'tags': tags, 'class': car_class})
    return jsonify(cars)

# ── Config ─────────────────────────────────────────────────────────────────────

@app.route('/mgmt/config', methods=['GET'])
def get_config():
    err = require_auth()
    if err: return err
    cfg = configparser.RawConfigParser()
    cfg.optionxform = str
    cfg.read(CFG)
    s = dict(cfg['SERVER']) if 'SERVER' in cfg else {}
    # Include session sections
    for sec in ['PRACTICE', 'QUALIFY', 'RACE']:
        if sec in cfg:
            s[f'_SESSION_{sec}'] = dict(cfg[sec])
    return jsonify(s)

@app.route('/mgmt/config', methods=['POST'])
def set_config():
    err = require_auth('admin')
    if err: return err
    data = request.json or {}
    cfg = configparser.RawConfigParser()
    cfg.optionxform = str
    cfg.read(CFG)
    if 'SERVER' not in cfg:
        cfg['SERVER'] = {}
    allowed = ['NAME','TRACK','CONFIG_TRACK','CARS','MAX_CLIENTS','ADMIN_PASSWORD',
               'PASSWORD','PICKUP_MODE_ENABLED','LOOP_MODE','SHOW_IN_LOBBY',
               'REGISTER_TO_LOBBY','UDP_PORT','TCP_PORT','HTTP_PORT']
    for key, val in data.items():
        if key.upper() in allowed:
            cfg['SERVER'][key.upper()] = str(val)

    # Write session sections
    sessions = data.get('_sessions', {})
    for sec_name, fields in sessions.items():
        sec_name = sec_name.upper()
        if sec_name not in ('PRACTICE', 'QUALIFY', 'RACE'):
            continue
        if sec_name not in cfg:
            cfg[sec_name] = {}
        for k, v in fields.items():
            cfg[sec_name][k.upper()] = str(v)

    with open(CFG, 'w') as f:
        cfg.write(f)
    # Save current track to state file for lap board tracking
    save_state(data.get('TRACK', data.get('track', '')), data.get('CONFIG_TRACK', data.get('config_track', '')))
    return jsonify({'ok': True})

@app.route('/mgmt/entry_list', methods=['POST'])
def set_entry_list():
    err = require_auth('admin')
    if err: return err
    data = request.json or {}
    cars = data.get('cars', [])
    ai_entries = data.get('ai_entries')  # {count, car, player_cars, skill}
    if not cars: return jsonify({'error': 'no cars'}), 400
    lines = []
    idx = 0
    # Player slots
    for car in cars:
        lines += [f'[CAR_{idx}]', f'MODEL={car}', 'SKIN=', 'SPECTATOR_MODE=0',
                  'DRIVER_NAME=', 'TEAM=', 'GUID=', 'BALLAST=0', 'RESTRICTOR=0', '']
        idx += 1
    # AI grid slots — blank GUID = AI driver in vanilla AC server
    if ai_entries:
        count = int(ai_entries.get('count', 5))
        ai_car = ai_entries.get('car')  # None = rotate through player cars
        player_cars = ai_entries.get('player_cars', cars)
        for i in range(count):
            model = ai_car if ai_car else player_cars[i % len(player_cars)]
            lines += [f'[CAR_{idx}]', f'MODEL={model}', 'SKIN=', 'SPECTATOR_MODE=0',
                      f'DRIVER_NAME=AI {i+1}', 'TEAM=AI', 'GUID=', 'BALLAST=0', 'RESTRICTOR=0', '']
            idx += 1
    with open('/opt/assettoserver/cfg/entry_list.ini', 'w') as f:
        f.write('\n'.join(lines))
    return jsonify({'ok': True, 'player_slots': len(cars), 'ai_slots': ai_entries.get('count', 0) if ai_entries else 0})

@app.route('/mgmt/restart', methods=['POST'])
def restart_server():
    err = require_auth('admin')
    if err: return err
    pending = request.json or {}
    allowed = ['NAME','TRACK','CONFIG_TRACK','CARS','MAX_CLIENTS','ADMIN_PASSWORD',
               'PASSWORD','PICKUP_MODE_ENABLED','LOOP_MODE','SHOW_IN_LOBBY',
               'REGISTER_TO_LOBBY','UDP_PORT','TCP_PORT','HTTP_PORT']
    print(f'restart_server: pending={pending}', flush=True)
    def do_restart():
        import datetime
        log = open('/tmp/restart_debug.log', 'a')
        log.write(f'{datetime.datetime.now()} do_restart starting pending={pending}\n')
        log.flush()
        # STOP first (blocking) — AS writes its in-memory config on shutdown
        subprocess.run(['systemctl', 'stop', 'assettoserver'])
        # NOW write our config (AS is fully dead, won't overwrite us)
        if pending:
            try:
                cfg2 = configparser.RawConfigParser()
                cfg2.optionxform = str
                cfg2.read(CFG)
                if 'SERVER' not in cfg2:
                    cfg2['SERVER'] = {}
                for key, val in pending.items():
                    if key.upper() in allowed:
                        cfg2['SERVER'][key.upper()] = str(val)
                with open(CFG, 'w') as f:
                    cfg2.write(f)
                print(f'restart: wrote config after stop: {pending}')
                log.write(f'wrote config: {pending}\n')
                log.flush()
            except Exception as e:
                print(f'restart: config write error: {e}')
        # START fresh — reads our config
        subprocess.Popen(['systemctl', 'start', 'assettoserver'])
    import threading
    threading.Thread(target=do_restart, daemon=True).start()
    return jsonify({'ok': True})

# ── Stats ──────────────────────────────────────────────────────────────────────

@app.route('/mgmt/session_info')
def get_session_info():
    err = require_auth()
    if err: return err
    cfg = configparser.RawConfigParser()
    cfg.optionxform = str
    cfg.read(CFG)
    sessions = []
    for sname in ['PRACTICE', 'QUALIFY', 'RACE']:
        if cfg.has_section(sname):
            s = dict(cfg[sname])
            sessions.append({
                'name': sname,
                'time': int(s.get('TIME', s.get('time', 0))),
                'laps': int(s.get('LAPS', s.get('laps', 0))),
                'is_open': s.get('IS_OPEN', s.get('is_open', '1'))
            })
    return jsonify({'sessions': sessions})

@app.route('/mgmt/stats')
def get_stats():
    err = require_auth()
    if err: return err
    cpu = _cpu_value
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage('/opt/assettoserver')
    uptime_secs = None
    try:
        result = subprocess.run(
            ['systemctl', 'show', 'assettoserver', '--property=ActiveEnterTimestamp'],
            capture_output=True, text=True)
        ts_str = result.stdout.strip().replace('ActiveEnterTimestamp=', '').strip()
        if ts_str and ts_str not in ('n/a', ''):
            from datetime import datetime, timezone
            for fmt in ('%a %Y-%m-%d %H:%M:%S %Z', '%a %Y-%m-%d %H:%M:%S UTC'):
                try:
                    dt = datetime.strptime(ts_str, fmt).replace(tzinfo=timezone.utc)
                    uptime_secs = int(time.time()) - int(dt.timestamp())
                    break
                except ValueError:
                    continue
    except Exception:
        pass
    return jsonify({
        'cpu': cpu, 'mem_used': mem.used, 'mem_total': mem.total,
        'mem_percent': mem.percent, 'disk_used': disk.used,
        'disk_total': disk.total, 'disk_percent': disk.percent,
        'uptime': uptime_secs
    })

# ── Weather ────────────────────────────────────────────────────────────────────

def sun_angle_to_time(angle):
    """Convert AC sun angle to HH:MM string. 0 = noon."""
    hours = 12.0 + float(angle) / 16.0
    h = int(hours) % 24
    m = int((hours - int(hours)) * 60)
    return f'{h:02d}:{m:02d}'

def time_to_sun_angle(time_str):
    """Convert HH:MM to AC sun angle."""
    parts = time_str.split(':')
    hours = int(parts[0]) + int(parts[1]) / 60.0
    return round((hours - 12.0) * 16.0)

def read_cfg_raw():
    """Read server_cfg.ini preserving all sections."""
    cfg = configparser.RawConfigParser()
    cfg.optionxform = str
    cfg.read(CFG)
    return cfg

def write_cfg_raw(cfg):
    with open(CFG, 'w') as f:
        cfg.write(f)

@app.route('/mgmt/weather', methods=['GET'])
def get_weather():
    err = require_auth()
    if err: return err
    try:
        cfg = read_cfg_raw()

        # Read server-level weather fields
        srv = dict(cfg['SERVER']) if 'SERVER' in cfg else {}
        sun_angle = int(srv.get('SUN_ANGLE', 0))
        wind_base = int(srv.get('WIND_BASE_KMH', 0))
        wind_var  = int(srv.get('WIND_VARIATION_KMH', 0))

        # Read WEATHER_N slots
        slots = []
        i = 0
        while True:
            sec = f'WEATHER_{i}'
            if sec not in cfg:
                break
            w = dict(cfg[sec])
            slots.append({
                'graphics':          w.get('GRAPHICS', '3_clear'),
                'ambient':           int(w.get('BASE_TEMPERATURE_AMBIENT', 22)),
                'road':              int(w.get('BASE_TEMPERATURE_ROAD', 32)),
                'ambient_variation': int(w.get('VARIATION_AMBIENT', 0)),
                'road_variation':    int(w.get('VARIATION_ROAD', 0)),
                'duration':          int(w.get('DURATION', 30)),
            })
            i += 1
        if not slots:
            slots = [{'graphics':'3_clear','ambient':22,'road':32,'ambient_variation':0,'road_variation':0,'duration':30}]

        # Read extra_cfg.yml
        with open(EXTRA_CFG) as f:
            extra = yaml.safe_load(f) or {}

        return jsonify({
            'sun_angle':       sun_angle,
            'time_of_day':     sun_angle_to_time(sun_angle),
            'wind_base':       wind_base,
            'wind_variation':  wind_var,
            'enable_weatherfx': extra.get('EnableWeatherFx', False),
            'lock_date':       extra.get('LockServerDate', True),
            'slots':           slots,
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/mgmt/weather', methods=['POST'])
def set_weather():
    err = require_auth('admin')
    if err: return err
    data = request.json or {}
    try:
        cfg = read_cfg_raw()

        # Update [SERVER] section
        if 'SERVER' not in cfg:
            cfg['SERVER'] = {}

        # Sun angle from time string or direct value
        if 'time_of_day' in data:
            cfg['SERVER']['SUN_ANGLE'] = str(time_to_sun_angle(data['time_of_day']))
        elif 'sun_angle' in data:
            cfg['SERVER']['SUN_ANGLE'] = str(int(data['sun_angle']))

        if 'wind_base' in data:
            cfg['SERVER']['WIND_BASE_KMH'] = str(int(data['wind_base']))
        if 'wind_variation' in data:
            cfg['SERVER']['WIND_VARIATION_KMH'] = str(int(data['wind_variation']))

        # Remove existing WEATHER_N sections
        existing = [s for s in cfg.sections() if re.match(r'^WEATHER_\d+$', s)]
        for s in existing:
            cfg.remove_section(s)

        # Write new weather slots
        slots = data.get('slots', [])
        for i, slot in enumerate(slots):
            sec = f'WEATHER_{i}'
            cfg.add_section(sec)
            cfg[sec]['GRAPHICS']                  = str(slot.get('graphics', '3_clear'))
            cfg[sec]['BASE_TEMPERATURE_AMBIENT']  = str(int(slot.get('ambient', 22)))
            cfg[sec]['BASE_TEMPERATURE_ROAD']     = str(int(slot.get('road', 32)))
            cfg[sec]['VARIATION_AMBIENT']         = str(int(slot.get('ambient_variation', 0)))
            cfg[sec]['VARIATION_ROAD']            = str(int(slot.get('road_variation', 0)))
            cfg[sec]['DURATION']                  = str(int(slot.get('duration', 30)))

        write_cfg_raw(cfg)

        # Update extra_cfg.yml
        with open(EXTRA_CFG) as f:
            extra = yaml.safe_load(f) or {}

        if 'enable_weatherfx' in data:
            extra['EnableWeatherFx'] = bool(data['enable_weatherfx'])
        if 'lock_date' in data:
            extra['LockServerDate'] = bool(data['lock_date'])

        with open(EXTRA_CFG, 'w') as f:
            yaml.dump(extra, f, default_flow_style=False, allow_unicode=True)

        return jsonify({'ok': True})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ── History ────────────────────────────────────────────────────────────────────

def sync_history_from_journal():
    try:
        result = subprocess.run(
            ['journalctl', '-u', 'assettoserver', '--no-pager', '-n', '2000', '--output=short-iso'],
            capture_output=True, text=True)
        events = []
        for line in result.stdout.splitlines():
            if 'AssettoServer[' not in line:
                continue
            ts_match = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})', line)
            ts = ts_match.group(1).replace('T', ' ') if ts_match else ''
            ac_part = line.split('AssettoServer[', 1)[1]
            if ']: ' in ac_part:
                ac_part = ac_part.split(']: ', 1)[1]
            ac_part = re.sub(r'^\[\d{2}:\d{2}:\d{2} \w+\] ', '', ac_part)
            if 'has connected' in ac_part:
                m = re.search(r'^(.+?) \([\w\d]+, \d+', ac_part)
                name = m.group(1).strip() if m else ac_part.split(' has')[0].strip()
                car_m = re.search(r'\d+ \((.+?)\)', ac_part)
                car = car_m.group(1).split('-')[0] if car_m else ''
                events.append({'type': 'connect', 'player': name, 'car': car, 'ts': ts})
            elif 'has disconnected' in ac_part:
                name = ac_part.split(' has disconnected')[0].strip()
                events.append({'type': 'disconnect', 'player': name, 'ts': ts})
            elif 'was kicked' in ac_part:
                name = ac_part.split(' was kicked')[0].strip()
                reason_m = re.search(r'Reason: (.+)', ac_part)
                reason = reason_m.group(1) if reason_m else ''
                events.append({'type': 'kicked', 'player': name, 'reason': reason, 'ts': ts})
        return events
    except Exception:
        return []

@app.route('/mgmt/history')
def get_history():
    err = require_auth()
    if err: return err
    events = sync_history_from_journal()
    return jsonify(list(reversed(events)))

# ── Lap board ──────────────────────────────────────────────────────────────────

@app.route('/mgmt/lapboard')
def get_lapboard():
    err = require_auth()
    if err: return err
    try:
        result = subprocess.run(
            ['journalctl', '-u', 'assettoserver', '--no-pager', '-n', '5000', '--output=short-iso'],
            capture_output=True, text=True)
        all_laps = []
        best = {}
        player_car = {}  # track current car per player
        for line in result.stdout.splitlines():
            if 'AssettoServer[' not in line:
                continue
            ts_match = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})', line)
            ts = ts_match.group(1).replace('T', ' ') if ts_match else ''
            # Parse epoch from timestamp for track lookup
            lap_epoch = 0
            if ts_match:
                try:
                    from datetime import datetime
                    lap_epoch = int(datetime.strptime(ts_match.group(1), '%Y-%m-%dT%H:%M:%S').timestamp())
                except Exception:
                    pass
            ac_part = line.split('AssettoServer[', 1)[1]
            if ']: ' in ac_part:
                ac_part = ac_part.split(']: ', 1)[1]
            ac_part = re.sub(r'^\[\d{2}:\d{2}:\d{2} \w+\] ', '', ac_part)
            # Track connections to record which car each player is driving
            if 'has connected' in ac_part:
                cm = re.search(r'^(.+?) \([\w\d]+, \d+', ac_part)
                cname = cm.group(1).strip() if cm else ac_part.split(' has')[0].strip()
                car_m = re.search(r'\d+ \((.+?)\)', ac_part)
                car = car_m.group(1).split('-')[0].strip() if car_m else ''
                if cname and car:
                    player_car[cname] = car
            # Format: "Lap completed by NAME, N cuts, laptime MILLISECONDS"
            m = re.search(r'Lap completed by (.+?), (\d+) cuts, laptime (\d+)', ac_part)
            if m:
                name = m.group(1).strip()
                cuts = int(m.group(2))
                lap_ms = int(m.group(3))
                mins = lap_ms // 60000
                secs = (lap_ms % 60000) // 1000
                ms = lap_ms % 1000
                time_str = f'{mins}:{secs:02d}.{ms:03d}'
                track = track_at_time(lap_epoch)
                car = player_car.get(name, '')
                entry = {'player': name, 'time': time_str, 'ms': lap_ms, 'cuts': cuts, 'ts': ts, 'track': track, 'car': car}
                all_laps.append(entry)
                # Best per player per track
                key = f"{name}|{track}"
                if key not in best or lap_ms < best[key]['ms']:
                    best[key] = entry
        sorted_best = sorted(best.values(), key=lambda x: x['ms'])
        all_tracks_seen = sorted(set(l['track'] for l in all_laps if l['track'] != 'unknown'))
        return jsonify({'best': sorted_best, 'recent': list(reversed(all_laps[:100])), 'tracks': all_tracks_seen})
    except Exception as e:
        return jsonify({'error': str(e), 'best': [], 'recent': []}), 500

# ── Presets ────────────────────────────────────────────────────────────────────

def safe_name(n):
    return re.sub(r'[^\w\s\-]', '', n).strip()[:50]

@app.route('/mgmt/presets', methods=['GET'])
def list_presets():
    err = require_auth()
    if err: return err
    os.makedirs(PRESETS_DIR, exist_ok=True)
    presets = []
    for f in sorted(os.listdir(PRESETS_DIR)):
        if f.endswith('.json'):
            try:
                with open(os.path.join(PRESETS_DIR, f)) as fp:
                    d = json.load(fp)
                presets.append({'name': f[:-5], 'track': d.get('TRACK',''), 'layout': d.get('CONFIG_TRACK',''),
                                'cars': d.get('CARS',''), 'saved': d.get('_saved','')})
            except Exception:
                pass
    return jsonify(presets)

@app.route('/mgmt/presets', methods=['POST'])
def save_preset():
    err = require_auth('admin')
    if err: return err
    data = request.json or {}
    name = safe_name(data.get('name', ''))
    if not name:
        return jsonify({'error': 'Name required'}), 400
    os.makedirs(PRESETS_DIR, exist_ok=True)
    data['_saved'] = time.strftime('%Y-%m-%d %H:%M')
    with open(os.path.join(PRESETS_DIR, f'{name}.json'), 'w') as f:
        json.dump(data, f, indent=2)
    return jsonify({'ok': True})

@app.route('/mgmt/presets/<n>', methods=['GET'])
def load_preset(n):
    err = require_auth()
    if err: return err
    name = safe_name(n)
    path = os.path.join(PRESETS_DIR, f'{name}.json')
    if not os.path.exists(path):
        return jsonify({'error': 'Not found'}), 404
    with open(path) as f:
        return jsonify(json.load(f))

@app.route('/mgmt/presets/<n>', methods=['DELETE'])
def delete_preset(n):
    err = require_auth('admin')
    if err: return err
    name = safe_name(n)
    path = os.path.join(PRESETS_DIR, f'{name}.json')
    if not os.path.exists(path):
        return jsonify({'error': 'Not found'}), 404
    os.remove(path)
    return jsonify({'ok': True})

# ── AI ─────────────────────────────────────────────────────────────────────────

@app.route('/mgmt/ai', methods=['GET'])
def get_ai():
    err = require_auth()
    if err: return err
    try:
        with open(EXTRA_CFG) as f:
            cfg = yaml.safe_load(f) or {}
        ai = cfg.get('AI') or {}
        return jsonify({'enabled': ai.get('Enabled', False), 'count': ai.get('MaxCount', 10),
                        'skill': ai.get('DefaultSkillLevel', 70), 'aggression': ai.get('DefaultAggression', 0)})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/mgmt/ai', methods=['POST'])
def set_ai():
    err = require_auth('admin')
    if err: return err
    data = request.json or {}
    try:
        with open(EXTRA_CFG) as f:
            cfg = yaml.safe_load(f) or {}
        if 'AI' not in cfg or cfg['AI'] is None:
            cfg['AI'] = {}
        cfg['AI']['Enabled'] = bool(data.get('enabled', False))
        cfg['AI']['MaxCount'] = int(data.get('count', 10))
        cfg['AI']['DefaultSkillLevel'] = int(data.get('skill', 70))
        cfg['AI']['DefaultAggression'] = int(data.get('aggression', 0))
        with open(EXTRA_CFG, 'w') as f:
            yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
        return jsonify({'ok': True})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ── Driver Stats ───────────────────────────────────────────────────────────────

def get_track_length_m(track_id, layout=''):
    """Read track length in metres from ui_track.json."""
    try:
        # Try layout-specific ui first
        if layout:
            p = os.path.join(CONTENT, 'tracks', track_id, 'ui', layout, 'ui_track.json')
            if not os.path.exists(p):
                p = os.path.join(CONTENT, 'tracks', track_id, 'ui', 'ui_track.json')
        else:
            p = os.path.join(CONTENT, 'tracks', track_id, 'ui', 'ui_track.json')
        if os.path.exists(p):
            with open(p) as f:
                data = json.load(f)
            length = data.get('length', '')
            # Can be "3142 m" or "3.142 km" or just a number
            if isinstance(length, (int, float)):
                return float(length)
            length = str(length).strip().lower()
            if 'km' in length:
                return float(re.sub(r'[^\d.]', '', length)) * 1000
            else:
                return float(re.sub(r'[^\d.]', '', length))
    except Exception:
        pass
    return None

SYNCTHING_API = 'http://127.0.0.1:8384'
SYNCTHING_KEY = 'u69UD4whyZusxG6Sh5kXTUpYjCxm6kif'

@app.route('/mgmt/syncthing')
def syncthing_status():
    err = require_auth()
    if err: return err
    try:
        import urllib.request as ur
        headers = {'X-API-Key': SYNCTHING_KEY}

        def st_get(path):
            req = ur.Request(f'{SYNCTHING_API}{path}', headers=headers)
            with ur.urlopen(req, timeout=5) as r:
                return json.loads(r.read())

        # Get all folder statuses
        config = st_get('/rest/config/folders')
        folder_ids = [f['id'] for f in config if f['id'] != 'default']

        folders = []
        overall_ok = True
        for fid in folder_ids:
            try:
                status = st_get(f'/rest/db/status?folder={fid}')
                label = next((f['label'] for f in config if f['id'] == fid), fid)
                state = status.get('state', 'unknown')
                need_bytes = status.get('needBytes', 0)
                need_files = status.get('needFiles', 0)
                global_bytes = status.get('globalBytes', 0)
                local_bytes = status.get('localBytes', 0)
                in_sync = state == 'idle' and need_bytes == 0
                if not in_sync:
                    overall_ok = False
                pct = round((local_bytes / global_bytes * 100) if global_bytes > 0 else 100, 1)
                folders.append({
                    'id': fid,
                    'label': label,
                    'state': state,
                    'in_sync': in_sync,
                    'need_files': need_files,
                    'need_bytes': need_bytes,
                    'pct': pct,
                })
            except Exception as e:
                folders.append({'id': fid, 'label': fid, 'state': 'error', 'in_sync': False, 'error': str(e)})
                overall_ok = False

        return jsonify({'ok': True, 'overall_ok': overall_ok, 'folders': folders})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)})



@app.route('/mgmt/logs')
def get_logs():
    err = require_auth()
    if err: return err
    n = request.args.get('n', '500')
    try:
        n = max(1, min(int(n), 5000))
    except Exception:
        n = 500
    try:
        result = subprocess.run(
            ['journalctl', '-u', 'assettoserver', '--no-pager', f'-n{n}', '--output=short-iso'],
            capture_output=True, text=True)
        lines = result.stdout.splitlines()
        parsed = []
        for line in lines:
            level = 'DBG'
            if '[INF]' in line: level = 'INF'
            elif '[WRN]' in line: level = 'WRN'
            elif '[ERR]' in line: level = 'ERR'
            elif '[FTL]' in line: level = 'FTL'
            elif 'systemd[' in line: level = 'SYS'
            parsed.append({'line': line, 'level': level})
        return jsonify({'lines': parsed, 'total': len(parsed)})
    except Exception as e:
        return jsonify({'error': str(e)}), 500



@app.route('/mgmt/check_track')
def check_track():
    err = require_auth()
    if err: return err
    track = request.args.get('track', '')
    layout = request.args.get('layout', '')
    if not track:
        return jsonify({'ok': False, 'error': 'No track specified'})

    track_dir = os.path.join(CONTENT, 'tracks', track)
    if not os.path.exists(track_dir):
        return jsonify({'ok': False, 'hard': True, 'error': f'Track folder not found: {track}. Upload the track to the server first.'})

    # Check surfaces.ini — search recursively in track folder
    has_surfaces = False
    for root, dirs, files in os.walk(track_dir):
        if 'surfaces.ini' in files:
            has_surfaces = True
            break

    # Check track_params.ini — ks_ tracks are handled internally by AssettoServer
    track_params_file = os.path.join(os.path.dirname(CFG), 'track_params.ini')
    has_params = track.lower().startswith('ks_')
    if not has_params and os.path.exists(track_params_file):
        tp = configparser.RawConfigParser()
        tp.optionxform = str.lower
        tp.read(track_params_file)
        has_params = tp.has_section(track.lower())

    warnings = []
    if not has_surfaces:
        warnings.append('Missing surfaces.ini — server will crash. Copy this file from the track on your PC.')

    if warnings:
        return jsonify({'ok': False, 'hard': True, 'error': ' | '.join(warnings), 'missing_surfaces': not has_surfaces})

    return jsonify({'ok': True})


@app.route('/mgmt/track_params', methods=['GET', 'POST'])
def manage_track_params():
    err = require_auth()
    if err: return err
    track_params_file = os.path.join(os.path.dirname(CFG), 'track_params.ini')
    if request.method == 'GET':
        tp = configparser.RawConfigParser()
        tp.optionxform = str.lower
        if os.path.exists(track_params_file):
            tp.read(track_params_file)
        result = {s: dict(tp[s]) for s in tp.sections()}
        return jsonify(result)
    else:
        data = request.json
        track = data.get('track', '').lower().strip()
        if not track:
            return jsonify({'error': 'Track name required'}), 400
        tp = configparser.RawConfigParser()
        tp.optionxform = str.lower
        if os.path.exists(track_params_file):
            tp.read(track_params_file)
        if not tp.has_section(track):
            tp.add_section(track)
        tp.set(track, 'Latitude', str(data.get('lat', 51.5)))
        tp.set(track, 'Longitude', str(data.get('lon', -0.1)))
        tp.set(track, 'Altitude', str(data.get('alt', 20)))
        with open(track_params_file, 'w') as f:
            tp.write(f)
        return jsonify({'ok': True})


@app.route('/mgmt/driver_stats')
def get_driver_stats():
    err = require_auth()
    if err: return err
    try:
        result = subprocess.run(
            ['journalctl', '-u', 'assettoserver', '--no-pager', '-n', '10000', '--output=short-iso'],
            capture_output=True, text=True)

        # Cache track lengths
        track_length_cache = {}

        def track_length(track_str):
            if track_str in track_length_cache:
                return track_length_cache[track_str]
            if '/' in track_str:
                tid, layout = track_str.split('/', 1)
            else:
                tid, layout = track_str, ''
            m = get_track_length_m(tid, layout)
            track_length_cache[track_str] = m
            return m

        player_car = {}   # player -> current car
        # stats[player][car] = {laps, metres, times:[]}
        stats = {}

        for line in result.stdout.splitlines():
            if 'AssettoServer[' not in line:
                continue
            ts_match = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})', line)
            ts = ts_match.group(1).replace('T', ' ') if ts_match else ''
            lap_epoch = 0
            if ts_match:
                try:
                    from datetime import datetime
                    lap_epoch = int(datetime.strptime(ts_match.group(1), '%Y-%m-%dT%H:%M:%S').timestamp())
                except Exception:
                    pass
            ac_part = line.split('AssettoServer[', 1)[1]
            if ']: ' in ac_part:
                ac_part = ac_part.split(']: ', 1)[1]
            ac_part = re.sub(r'^\[\d{2}:\d{2}:\d{2} \w+\] ', '', ac_part)

            # Track connections
            if 'has connected' in ac_part:
                cm = re.search(r'^(.+?) \([\w\d]+, \d+', ac_part)
                cname = cm.group(1).strip() if cm else ac_part.split(' has')[0].strip()
                car_m = re.search(r'\d+ \((.+?)\)', ac_part)
                car = car_m.group(1).split('-')[0].strip() if car_m else ''
                if cname and car:
                    player_car[cname] = car

            # Laps
            m = re.search(r'Lap completed by (.+?), (\d+) cuts, laptime (\d+)', ac_part)
            if m:
                name = m.group(1).strip()
                cuts = int(m.group(2))
                lap_ms = int(m.group(3))
                car = player_car.get(name, 'unknown')
                track = track_at_time(lap_epoch)
                length_m = track_length(track)

                if name not in stats:
                    stats[name] = {}
                key = car
                if key not in stats[name]:
                    stats[name][key] = {'laps': 0, 'metres': 0.0, 'best_ms': None, 'cuts': 0, 'tracks': set()}
                stats[name][key]['laps'] += 1
                stats[name][key]['cuts'] += cuts
                stats[name][key]['tracks'].add(track)
                if length_m:
                    stats[name][key]['metres'] += length_m
                if stats[name][key]['best_ms'] is None or lap_ms < stats[name][key]['best_ms']:
                    stats[name][key]['best_ms'] = lap_ms

        # Serialise — convert sets and format numbers
        def fmt_ms(ms):
            if ms is None: return None
            mins = ms // 60000
            secs = (ms % 60000) // 1000
            msec = ms % 1000
            return f'{mins}:{secs:02d}.{msec:03d}'

        result_stats = []
        for player, cars in sorted(stats.items()):
            total_laps = sum(v['laps'] for v in cars.values())
            total_km   = sum(v['metres'] for v in cars.values()) / 1000
            car_list = []
            for car, v in sorted(cars.items(), key=lambda x: -x[1]['laps']):
                km = v['metres'] / 1000
                miles = km * 0.621371
                car_list.append({
                    'car':    car,
                    'laps':   v['laps'],
                    'km':     round(km, 2),
                    'miles':  round(miles, 2),
                    'cuts':   v['cuts'],
                    'best':   fmt_ms(v['best_ms']),
                    'tracks': sorted(v['tracks']),
                })
            result_stats.append({
                'player':     player,
                'total_laps': total_laps,
                'total_km':   round(total_km, 2),
                'total_miles':round(total_km * 0.621371, 2),
                'cars':       car_list,
            })

        # Sort by total laps desc
        result_stats.sort(key=lambda x: -x['total_laps'])
        return jsonify(result_stats)

    except Exception as e:
        return jsonify({'error': str(e)}), 500


SCHEDULE_FILE = '/opt/assettoserver/cfg/schedule.json'
SCHEDULE_STATE_FILE = '/opt/assettoserver/cfg/schedule_state.json'
DISCORD_CFG  = '/opt/assettoserver/cfg/discord_cfg.json'
AC_HTTP = 'http://127.0.0.1:8081'

def load_schedule():
    if os.path.exists(SCHEDULE_FILE):
        with open(SCHEDULE_FILE) as f:
            return json.load(f)
    return {'events': [], 'active': False}

def save_schedule(s):
    with open(SCHEDULE_FILE, 'w') as f:
        json.dump(s, f, indent=2)

def load_sched_state():
    if os.path.exists(SCHEDULE_STATE_FILE):
        with open(SCHEDULE_STATE_FILE) as f:
            return json.load(f)
    return {'current_index': 0, 'session_count': 0, 'last_session_type': None, 'running': False}

def save_sched_state(s):
    with open(SCHEDULE_STATE_FILE, 'w') as f:
        json.dump(s, f, indent=2)

def apply_event(event):
    """Apply a schedule event to server_cfg.ini + entry_list.ini and restart."""
    try:
        cfg = configparser.RawConfigParser()
        cfg.optionxform = str
        cfg.read(CFG)
        if 'SERVER' not in cfg:
            cfg.add_section('SERVER')
        s = cfg['SERVER']
        s['TRACK'] = event.get('track', s.get('TRACK', ''))
        s['CONFIG_TRACK'] = event.get('layout', '')
        cars = event.get('cars', [])
        s['CARS'] = ';'.join(cars)
        s['PASSWORD'] = event.get('password', '')
        s['TYRE_WEAR_RATE']    = str(int(event.get('tyre_wear', 1)))
        s['FUEL_RATE']         = str(int(event.get('fuel_rate', 1)))
        s['DAMAGE_MULTIPLIER'] = str(int(event.get('damage', 0)))
        # Sessions — only write enabled ones, remove disabled sections
        sessions = event.get('sessions', {})
        for sname in ['PRACTICE', 'QUALIFY', 'RACE']:
            sdata = sessions.get(sname, {})
            enabled = sdata.get('enabled', True)
            if enabled and sdata:
                if not cfg.has_section(sname):
                    cfg.add_section(sname)
                for k, v in sdata.items():
                    if k.upper() != 'ENABLED':
                        cfg[sname][k.upper()] = str(v)
            else:
                if cfg.has_section(sname):
                    cfg.remove_section(sname)
        with open(CFG, 'w') as f:
            cfg.write(f)
        # Regenerate entry_list.ini from event cars
        if cars:
            lines = []
            for idx, car in enumerate(cars):
                lines += [f'[CAR_{idx}]', f'MODEL={car}', 'SKIN=', 'SPECTATOR_MODE=0',
                          'DRIVER_NAME=', 'TEAM=', 'GUID=', 'BALLAST=0', 'RESTRICTOR=0', '']
            with open('/opt/assettoserver/cfg/entry_list.ini', 'w') as f:
                f.write('\n'.join(lines))
        # AI traffic + Weather via extra_cfg.yml
        if os.path.exists(EXTRA_CFG):
            with open(EXTRA_CFG) as f:
                extra = yaml.safe_load(f) or {}
            if 'AI' not in extra:
                extra['AI'] = {}
            extra['AI']['Enabled'] = bool(event.get('ai_traffic', False))
            # Weather
            weather = event.get('weather')
            if weather and weather.get('enabled'):
                extra['EnableWeatherFx'] = bool(weather.get('enable_weatherfx', False))
            with open(EXTRA_CFG, 'w') as f:
                yaml.dump(extra, f, default_flow_style=False, allow_unicode=True)

        # Write weather to server_cfg.ini
        weather = event.get('weather')
        # Always apply time of day + wind (even if custom weather slots disabled)
        tod = (weather or {}).get('time_of_day', '14:00')
        parts = tod.split(':')
        hours = int(parts[0]) + int(parts[1])/60.0
        sun_angle = round((hours - 12.0) * 16.0)
        cfg['SERVER']['SUN_ANGLE'] = str(sun_angle)
        cfg['SERVER']['WIND_BASE_KMH'] = str(int((weather or {}).get('wind_base', 0)))
        cfg['SERVER']['WIND_VARIATION_KMH'] = '0'
        with open(CFG, 'w') as f:
            cfg.write(f)
        if weather and weather.get('enabled'):
            # Remove existing WEATHER_N sections
            existing_w = [s for s in cfg.sections() if re.match(r'^WEATHER_\d+$', s)]
            for s in existing_w:
                cfg.remove_section(s)
            # Write slots[] — fall back to legacy single-slot format if no slots
            slots = weather.get('slots') or []
            if not slots:
                slots = [{
                    'graphics':  weather.get('graphics', '15'),
                    'ambient':   weather.get('ambient', 22),
                    'road':      weather.get('road', 32),
                    'weatherfx': weather.get('enable_weatherfx', False),
                    'duration':  30
                }]
            for i, slot in enumerate(slots):
                sec = f'WEATHER_{i}'
                cfg.add_section(sec)
                # Convert numeric WeatherFX type ID to correct GRAPHICS format
                gfx = slot.get('graphics', '15')
                if gfx.lstrip('-').isdigit():
                    gfx = f'sol_03_scattered_clouds_type={gfx}_time=0_mult=0'
                cfg[sec]['GRAPHICS'] = gfx
                cfg[sec]['BASE_TEMPERATURE_AMBIENT']  = str(int(slot.get('ambient', 22)))
                cfg[sec]['BASE_TEMPERATURE_ROAD']     = str(int(slot.get('road', 32)))
                cfg[sec]['VARIATION_AMBIENT']         = '0'
                cfg[sec]['VARIATION_ROAD']            = '0'
                cfg[sec]['DURATION']                  = str(int(slot.get('duration', 30)))
            # Remove legacy weather keys from SERVER and EVENT sections
            for sec in ('SERVER', 'EVENT'):
                if cfg.has_section(sec):
                    legacy = [k for k in cfg[sec] if re.match(r'^weather_\d+$', k, re.IGNORECASE)]
                    for k in legacy:
                        cfg.remove_option(sec, k)
            with open(CFG, 'w') as f:
                cfg.write(f)
            # Enable WeatherFx so AssettoServer honours WEATHER_N sections
            if os.path.exists(EXTRA_CFG):
                with open(EXTRA_CFG) as f:
                    extra2 = yaml.safe_load(f) or {}
                extra2['EnableWeatherFx'] = True
                with open(EXTRA_CFG, 'w') as f:
                    yaml.dump(extra2, f, default_flow_style=False, allow_unicode=True)
        # Log track change
        save_state(event.get('track', ''), event.get('layout', ''))
        # Restart server
        subprocess.run(['systemctl', 'restart', 'assettoserver'])
        return True
    except Exception as e:
        print(f'apply_event error: {e}')
        return False

def count_enabled_sessions(event):
    """Count how many session types are enabled for this event."""
    sessions = event.get('sessions', {})
    count = 0
    for sname in ['PRACTICE', 'QUALIFY', 'RACE']:
        if sessions.get(sname, {}).get('enabled', False):
            count += 1
    return max(count, 1)

# ── Schedule background monitor ───────────────────────────────────────────────
import threading

_monitor_thread = None
_monitor_lock = threading.Lock()

def schedule_monitor():
    """Background thread that polls AC session state and auto-advances schedule."""
    print("schedule_monitor: thread started", flush=True)
    import urllib.request as ur
    last_session_name = None
    session_changes = 0
    # Empty-lobby timeout: track when current laps-session had 0 players
    empty_since = None        # time.time() when we first saw 0 players in a laps session
    EMPTY_TIMEOUT = 600       # 10 minutes

    def advance_event(state, sched, events, idx):
        """Advance to next event or stop schedule (loop if enabled)."""
        next_idx = idx + 1
        if next_idx < len(events):
            state['current_index'] = next_idx
            save_sched_state(state)
            apply_event(events[next_idx])
            print(f'schedule_monitor: advanced to event {next_idx}')
        elif sched.get('loop', False):
            state['current_index'] = 0
            save_sched_state(state)
            apply_event(events[0])
            print('schedule_monitor: schedule looping back to event 0')
        else:
            state['running'] = False
            sched['active'] = False
            save_sched_state(state)
            save_schedule(sched)
            print('schedule_monitor: schedule complete')

    while True:
        time.sleep(30)
        try:
            sched = load_schedule()
            if not sched.get('active', False):
                empty_since = None
                continue
            state = load_sched_state()
            if not state.get('running', False):
                empty_since = None
                continue
            events = sched.get('events', [])
            idx = state.get('current_index', 0)
            if idx >= len(events):
                continue

            # Poll AC current session
            session_name = ''
            session_type = -1
            try:
                req = ur.Request(f'{AC_HTTP}/api/currentSession', headers={})
                with ur.urlopen(req, timeout=5) as r:
                    data = json.loads(r.read())
                session_name = data.get('name', '')
                session_type = data.get('type', -1)
            except Exception:
                pass
            # Fallback: use /api/details if currentSession unavailable
            if session_type == -1:
                try:
                    req = ur.Request(f'{AC_HTTP}/api/details', headers={})
                    with ur.urlopen(req, timeout=5) as r:
                        det = json.loads(r.read())
                    sess_idx = det.get('session', 0)
                    sess_types = det.get('sessiontypes', [])
                    session_type = sess_types[sess_idx] if sess_idx < len(sess_types) else (sess_types[-1] if sess_types else -1)
                    # Map AS session types to standard: 1=practice,2=qualify,3=race
                    session_name = {1:'Practice',2:'Qualifying',3:'Race'}.get(session_type,'Unknown')
                    timeleft = det.get('timeleft', 0)
                    # If timeleft is very negative, session has ended - force a session change detection
                    if timeleft < -30:
                        session_name = session_name + '_ended'
                except Exception:
                    continue

            # Check player count (use details since /api/slots is unavailable)
            try:
                connected = sum(1 for c in data.get('players', {}).get('Cars', []) if c.get('IsConnected', False))
            except Exception:
                connected = -1  # unknown

            # Empty-lobby timeout for laps-based sessions
            # Check if current event session for this type uses LAPS (TIME==0)
            ev = events[idx]
            sess_key = {1: 'PRACTICE', 2: 'QUALIFY', 3: 'RACE'}.get(session_type, '')
            sess_cfg = ev.get('sessions', {}).get(sess_key, {})
            is_laps_based = (int(sess_cfg.get('LAPS', 0)) > 0)  # LAPS takes priority over TIME in AC

            is_time_zero = (int(sess_cfg.get("TIME", 1)) == 0 and not is_laps_based)
            if (is_laps_based or is_time_zero) and connected <= 0:
                if empty_since is None:
                    empty_since = time.time()
                    print(f'schedule_monitor: laps session "{session_name}" empty, starting {EMPTY_TIMEOUT}s timeout')
                elif time.time() - empty_since >= EMPTY_TIMEOUT:
                    print(f'schedule_monitor: laps session "{session_name}" empty for {EMPTY_TIMEOUT}s, force-advancing')
                    empty_since = None
                    session_changes = 0
                    last_session_name = None
                    advance_event(state, sched, events, idx)
                    continue
            else:
                # Reset timer if players joined or session is time-based
                if empty_since is not None and connected > 0:
                    print(f'schedule_monitor: player joined laps session, cancelling timeout')
                empty_since = None

            # Detect session change (natural progression)
            if last_session_name is None:
                last_session_name = session_name
                continue

            if session_name != last_session_name:
                session_changes += 1
                last_session_name = session_name
                empty_since = None  # reset on any session change
                expected = count_enabled_sessions(events[idx])
                if session_changes >= expected:
                    session_changes = 0
                    last_session_name = None
                    advance_event(state, sched, events, idx)
        except Exception as e:
            import traceback; print(f'schedule_monitor error: {e}\n' + traceback.format_exc(), flush=True)

def ensure_monitor():
    global _monitor_thread
    with _monitor_lock:
        if _monitor_thread is None or not _monitor_thread.is_alive():
            _monitor_thread = threading.Thread(target=schedule_monitor, daemon=True)
            _monitor_thread.start()

ensure_monitor()

# ── Schedule endpoints ─────────────────────────────────────────────────────────

@app.route('/mgmt/resources')
def get_resources():
    err = require_auth()
    if err: return err
    try:
        import psutil
        return jsonify({
            'ts': int(time.time()),
            'cpu': _cpu_value,
            'mem_percent': psutil.virtual_memory().percent,
            'mem_used': psutil.virtual_memory().used,
            'mem_total': psutil.virtual_memory().total,
            'disk_percent': psutil.disk_usage('/').percent,
            'disk_used': psutil.disk_usage('/').used,
            'disk_total': psutil.disk_usage('/').total,
            'net_sent': psutil.net_io_counters().bytes_sent,
            'net_recv': psutil.net_io_counters().bytes_recv,
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/mgmt/discord', methods=['GET','POST'])
def discord_config():
    err = require_auth('admin')
    if err: return err
    if request.method == 'POST':
        data = request.json or {}
        cfg  = load_discord_cfg()
        for k in ('webhook_url','enabled','announce_session','announce_track','announce_results','server_name'):
            if k in data: cfg[k] = data[k]
        save_discord_cfg(cfg)
        return jsonify({'ok':True})
    return jsonify(load_discord_cfg())

@app.route('/mgmt/discord/test', methods=['POST'])
def discord_test():
    err = require_auth('admin')
    if err: return err
    import datetime
    cfg = load_discord_cfg()
    ok  = discord_send({'title':'✅  Test Message','description':'Discord integration is working!',
          'color':0x2ECC71,'footer':{'text':cfg.get('server_name') or 'AC Server'},
          'timestamp':datetime.datetime.utcnow().isoformat()+'Z'})
    return jsonify({'ok':True}) if ok else (jsonify({'error':'Failed — check webhook URL and Enabled flag'}),400)

@app.route('/mgmt/discord/announce', methods=['POST'])
def discord_announce():
    err = require_auth('admin')
    if err: return err
    import datetime
    data = request.json or {}
    msg  = data.get('message','').strip()
    if not msg: return jsonify({'error':'message required'}),400
    cfg  = load_discord_cfg()
    ok   = discord_send({'title':'📢  Server Announcement','description':msg,
           'color':0x9B59B6,'footer':{'text':cfg.get('server_name') or 'AC Server'},
           'timestamp':datetime.datetime.utcnow().isoformat()+'Z'})
    return jsonify({'ok':True}) if ok else (jsonify({'error':'Failed to send'}),400)

@app.route('/mgmt/schedule', methods=['GET'])
def get_schedule():
    err = require_auth()
    if err: return err
    sched = load_schedule()
    state = load_sched_state()
    return jsonify({'schedule': sched, 'state': state})



@app.route('/mgmt/schedule', methods=['POST'])
def save_schedule_route():
    err = require_auth()
    if err: return err
    data = request.json
    sched = load_schedule()
    sched['events'] = data.get('events', [])
    sched['loop'] = data.get('loop', False)
    save_schedule(sched)
    return jsonify({'ok': True})

@app.route('/mgmt/schedule/start', methods=['POST'])
def start_schedule():
    err = require_auth()
    if err: return err
    sched = load_schedule()
    if not sched.get('events'):
        return jsonify({'error': 'No events in schedule'}), 400
    sched['active'] = True
    save_schedule(sched)
    state = {'current_index': 0, 'running': True}
    save_sched_state(state)
    ensure_monitor()
    apply_event(sched['events'][0])
    return jsonify({'ok': True})

@app.route('/mgmt/schedule/stop', methods=['POST'])
def stop_schedule():
    err = require_auth()
    if err: return err
    sched = load_schedule()
    sched['active'] = False
    save_schedule(sched)
    state = load_sched_state()
    state['running'] = False
    save_sched_state(state)
    return jsonify({'ok': True})

@app.route('/mgmt/schedule/next', methods=['POST'])
def next_event():
    err = require_auth()
    if err: return err
    sched = load_schedule()
    state = load_sched_state()
    events = sched.get('events', [])
    idx = state.get('current_index', 0) + 1
    if idx >= len(events):
        return jsonify({'error': 'No more events'}), 400
    state['current_index'] = idx
    save_sched_state(state)
    apply_event(events[idx])
    return jsonify({'ok': True, 'event': events[idx]})

@app.route('/mgmt/schedule/goto/<int:idx>', methods=['POST'])
def goto_event(idx):
    err = require_auth()
    if err: return err
    sched = load_schedule()
    events = sched.get('events', [])
    if idx < 0 or idx >= len(events):
        return jsonify({'error': 'Invalid index'}), 400
    state = load_sched_state()
    state['current_index'] = idx
    state['running'] = True
    sched['active'] = True
    save_sched_state(state)
    save_schedule(sched)
    apply_event(events[idx])
    return jsonify({'ok': True})


# ── Home Assistant endpoint ────────────────────────────────────────────────────
@app.route('/ha/status')
def ha_status():
    """No-auth endpoint for Home Assistant integration."""
    import urllib.request as ur
    out = {}
    # Server online/offline + basic info
    try:
        with ur.urlopen(f'{AC_HTTP}/api/details', timeout=3) as r:
            d = json.loads(r.read())
        out['online'] = True
        out['server_name'] = d.get('name', '')
        out['max_clients'] = d.get('clients', 0)
        cars = d.get('players', {}).get('Cars', [])
        connected = [c for c in cars if c.get('IsConnected')]
        out['players_connected'] = len(connected)
        out['players'] = [
            {'name': c.get('DriverName') or c.get('Driver', {}).get('Name', ''),
             'car': c.get('Model', '')}
            for c in connected
        ]
    except Exception:
        out['online'] = False
        out['server_name'] = ''
        out['max_clients'] = 0
        out['players_connected'] = 0
        out['players'] = []
    # Current session
    try:
        with ur.urlopen(f'{AC_HTTP}/api/currentSession', timeout=3) as r:
            s = json.loads(r.read())
        out['session_name'] = s.get('name', '')
        out['session_type'] = {0:'Practice',1:'Qualifying',2:'Race',3:'Hotlap',4:'Time Attack'}.get(s.get('type',-1),'Unknown')
        out['session_time_left'] = s.get('timeLeft', 0)
    except Exception:
        out['session_name'] = ''
        out['session_type'] = 'Unknown'
        out['session_time_left'] = 0
    # Track / state file
    try:
        st = load_state()
        out['track'] = st.get('track', '')
        out['layout'] = st.get('layout', '')
    except Exception:
        out['track'] = ''
        out['layout'] = ''
    out['uptime_seconds'] = 0
    # Schedule state
    try:
        sched = load_schedule()
        state = load_sched_state()
        events = sched.get('events', [])
        idx = state.get('current_index', 0)
        out['schedule_active'] = sched.get('active', False)
        out['schedule_running'] = state.get('running', False)
        out['schedule_event_index'] = idx
        out['schedule_event_name'] = events[idx].get('name', '') if idx < len(events) else ''
        out['schedule_event_count'] = len(events)
    except Exception:
        out['schedule_active'] = False
        out['schedule_running'] = False
        out['schedule_event_index'] = 0
        out['schedule_event_name'] = ''
        out['schedule_event_count'] = 0
    # System resources
    try:
        import psutil
        out['cpu_percent'] = _cpu_value
        vm = psutil.virtual_memory()
        out['ram_used_gb'] = round(vm.used / 1024**3, 2)
        out['ram_total_gb'] = round(vm.total / 1024**3, 2)
        out['ram_percent'] = vm.percent
        du = psutil.disk_usage('/')
        out['disk_used_gb'] = round(du.used / 1024**3, 1)
        out['disk_total_gb'] = round(du.total / 1024**3, 1)
        out['disk_percent'] = du.percent
    except Exception:
        pass
    out['timestamp'] = int(time.time())
    return jsonify(out)

# ── Car info endpoints ─────────────────────────────────────────────────────────
@app.route('/mgmt/car-info/<car_id>')
def car_info(car_id):
    ui_path = os.path.join(CONTENT, 'cars', car_id, 'ui', 'ui_car.json')
    try:
        raw = open(ui_path, encoding='utf-8', errors='ignore').read()
        # Replace ALL control characters (including newlines inside strings) with space
        clean = ''.join(c if ord(c) >= 32 else ' ' for c in raw)
        data = json.loads(clean)
        skins_dir = os.path.join(CONTENT, 'cars', car_id, 'skins')
        preview = None
        if os.path.exists(skins_dir):
            for skin in sorted(os.listdir(skins_dir)):
                p = os.path.join(skins_dir, skin, 'preview.jpg')
                if os.path.exists(p):
                    preview = f'/mgmt/car-preview/{car_id}/{skin}'
                    break
        data['_preview'] = preview
        data['_badge'] = f'/mgmt/car-badge/{car_id}' if os.path.exists(
            os.path.join(CONTENT, 'cars', car_id, 'ui', 'badge.png')) else None
        return jsonify(data)
    except FileNotFoundError:
        return jsonify({'name': car_id, 'specs': {}, '_preview': None, '_badge': None})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/mgmt/car-badge/<car_id>')
def car_badge(car_id):
    path = os.path.join(CONTENT, 'cars', car_id, 'ui', 'badge.png')
    return send_file(path) if os.path.exists(path) else ('', 404)

@app.route('/mgmt/car-preview/<car_id>/<skin>')
def car_preview(car_id, skin):
    path = os.path.join(CONTENT, 'cars', car_id, 'skins', skin, 'preview.jpg')
    return send_file(path) if os.path.exists(path) else ('', 404)

@app.route('/mgmt/car-names')
def car_names():
    names = {}
    cars_dir = os.path.join(CONTENT, 'cars')
    if os.path.exists(cars_dir):
        for car_id in sorted(os.listdir(cars_dir)):
            if car_id.startswith('.'): continue
            ui_path = os.path.join(cars_dir, car_id, 'ui', 'ui_car.json')
            try:
                raw = open(ui_path, encoding='utf-8', errors='ignore').read()
                clean = ''.join(c if ord(c) >= 32 else ' ' for c in raw)
                names[car_id] = json.loads(clean).get('name', car_id)
            except:
                names[car_id] = car_id
    return jsonify(names)

@app.route('/mgmt/track-names')
def track_names():
    names = {}
    tracks_dir = os.path.join(CONTENT, 'tracks')
    if os.path.exists(tracks_dir):
        for track_id in sorted(os.listdir(tracks_dir)):
            if track_id.startswith('.'): continue
            ui_dir = os.path.join(tracks_dir, track_id, 'ui')
            ui_path = os.path.join(ui_dir, 'ui_track.json')
            found = False
            if os.path.exists(ui_path):
                try:
                    raw = open(ui_path, encoding='utf-8', errors='ignore').read()
                    clean = ''.join(c if ord(c) >= 32 else ' ' for c in raw)
                    names[track_id] = json.loads(clean).get('name', track_id)
                    found = True
                except: pass
            if not found and os.path.exists(ui_dir):
                for layout in sorted(os.listdir(ui_dir)):
                    lpath = os.path.join(ui_dir, layout, 'ui_track.json')
                    if os.path.exists(lpath):
                        try:
                            raw = open(lpath, encoding='utf-8', errors='ignore').read()
                            clean = ''.join(c if ord(c) >= 32 else ' ' for c in raw)
                            lname = json.loads(clean).get('name', track_id)
                            if not found:
                                names[track_id] = lname
                                found = True
                            # Also store track_id-layout key for AC's combined format
                            names[f'{track_id}-{layout}'] = lname
                        except: pass
            if not found:
                names[track_id] = track_id
    return jsonify(names)

# ── Car filter config ──────────────────────────────────────────────────────────
CAR_FILTER_CFG = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cfg', 'car_filters.json')

@app.route('/mgmt/car-tags')
def car_tags():
    tag_set = set()
    class_set = set()
    cars_dir = os.path.join(CONTENT, 'cars')
    if os.path.exists(cars_dir):
        for c in sorted(os.listdir(cars_dir)):
            if c.startswith('.'): continue
            ui_path = os.path.join(cars_dir, c, 'ui', 'ui_car.json')
            try:
                raw = open(ui_path, encoding='utf-8', errors='ignore').read()
                clean = ''.join(ch if ord(ch) >= 32 else ' ' for ch in raw)
                d = json.loads(clean)
                for t in (d.get('tags') or []):
                    if t: tag_set.add(str(t).strip().lower())
                cls = (d.get('class') or '').strip().lower()
                if cls: class_set.add(cls)
            except: pass
    return jsonify({'tags': sorted(tag_set), 'classes': sorted(class_set)})

@app.route('/mgmt/filter-config', methods=['GET'])
def get_filter_config():
    try:
        with open(CAR_FILTER_CFG) as f: return jsonify(json.load(f))
    except:
        return jsonify({'filters': [
            {'label':'All','value':''},
            {'label':'GT3','value':'gt3'},
            {'label':'Drift','value':'drift'},
            {'label':'Race','value':'race'},
            {'label':'Street','value':'street'},
        ]})

@app.route('/mgmt/filter-config', methods=['POST'])
def save_filter_config():
    err = require_auth('admin')
    if err: return err
    with open(CAR_FILTER_CFG, 'w') as f: json.dump(request.json or {}, f, indent=2)
    return jsonify({'ok': True})

def _resolve_track_name(track_id):
    """Resolve a track ID to a friendly name using ui_track.json files."""
    if not track_id:
        return track_id
    tracks_dir = os.path.join(CONTENT, 'tracks')
    # Handle track-layout format e.g. ks_silverstone-international
    base_id = track_id.split('-')[0]
    layout = track_id[len(base_id)+1:] if '-' in track_id else ''
    ui_dir = os.path.join(tracks_dir, base_id, 'ui')
    # Try layout-specific first
    paths = []
    if layout:
        paths.append(os.path.join(ui_dir, layout, 'ui_track.json'))
    paths.append(os.path.join(ui_dir, 'ui_track.json'))
    for p in paths:
        if os.path.exists(p):
            try:
                raw = open(p, encoding='utf-8', errors='ignore').read()
                clean = ''.join(c if ord(c) >= 32 else ' ' for c in raw)
                return json.loads(clean).get('name', track_id)
            except:
                pass
    # Try any layout
    if os.path.exists(ui_dir):
        for layout_dir in sorted(os.listdir(ui_dir)):
            p = os.path.join(ui_dir, layout_dir, 'ui_track.json')
            if os.path.exists(p):
                try:
                    raw = open(p, encoding='utf-8', errors='ignore').read()
                    clean = ''.join(c if ord(c) >= 32 else ' ' for c in raw)
                    return json.loads(clean).get('name', track_id)
                except:
                    pass
    return track_id


@app.route('/public/stats')
def public_stats():
    """Unauthenticated stats endpoint for Homepage widget."""
    import urllib.request as ur
    try:
        with ur.urlopen(f'{AC_HTTP}/api/details', timeout=5) as r:
            d = json.loads(r.read())
        connected = sum(1 for c in d.get('players',{}).get('Cars',[]) if c.get('IsConnected'))
        slots = len(d.get('players',{}).get('Cars',[]))
        sess_map = {1:'Practice', 2:'Qualifying', 3:'Race'}
        sess_types = d.get('sessiontypes', [])
        sess_idx = d.get('session', 0)
        sess_type = sess_types[sess_idx] if sess_idx < len(sess_types) else (sess_types[-1] if sess_types else 0)
        session = sess_map.get(sess_type, 'Unknown')
        sched = load_schedule()
        state = load_sched_state()
        events = sched.get('events', [])
        current_event = events[state.get('current_index', 0)].get('name', '') if events else ''
        # Resolve friendly track/event names
        track_raw = d.get('track', '')
        track_friendly = _resolve_track_name(track_raw)
        event_raw = current_event
        event_friendly = _resolve_track_name(event_raw) if event_raw else ''

        return jsonify({
            'server': d.get('name', ''),
            'track': track_friendly,
            'session': session,
            'players': f"{connected}/{slots}",
            'event': event_friendly,
            'schedule_active': sched.get('active', False),
            'loop': sched.get('loop', False)
        })
    except Exception as e:
        import traceback
        return jsonify({'error': str(e), 'trace': traceback.format_exc()}), 500

app.run(host='0.0.0.0', port=8083)
