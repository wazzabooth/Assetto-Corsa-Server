import http.server, urllib.request, urllib.error, os
PORT   = 8082
MGMT   = 'http://127.0.0.1:8083'
AC_API = 'http://127.0.0.1:8081'
DIR    = '/opt/assettoserver'
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p = self.path.split('?')[0]
        if p in ('/', ''): p = '/ac-admin.html'
        if p.startswith('/auth/') or p.startswith('/mgmt/'):
            self.proxy(MGMT)
        elif p.startswith('/api/'):
            self.proxy(AC_API)
        else:
            fp = os.path.join(DIR, p.lstrip('/'))
            if os.path.isfile(fp):
                self.serve_file(fp)
            else:
                self.send_response(404); self.end_headers()
    def do_POST(self):
        if self.path.startswith('/auth/') or self.path.startswith('/mgmt/'):
            self.proxy(MGMT)
        elif self.path.startswith('/api/'):
            self.proxy(AC_API)
        else:
            self.send_response(404); self.end_headers()
    def do_PUT(self):
        if self.path.startswith('/mgmt/'): self.proxy(MGMT)
        else: self.send_response(404); self.end_headers()
    def do_DELETE(self):
        if self.path.startswith('/mgmt/'): self.proxy(MGMT)
        else: self.send_response(404); self.end_headers()
    def proxy(self, backend):
        length = int(self.headers.get('Content-Length', 0))
        body   = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ('host', 'transfer-encoding')}
        try:
            req = urllib.request.Request(backend + self.path, data=body,
                                         headers=headers, method=self.command)
            with urllib.request.urlopen(req, timeout=10) as r:
                self.send_response(r.status)
                for k, v in r.headers.items():
                    if k.lower() not in ('transfer-encoding',): self.send_header(k, v)
                self.end_headers(); self.wfile.write(r.read())
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            for k, v in e.headers.items():
                if k.lower() not in ('transfer-encoding',): self.send_header(k, v)
            self.end_headers(); self.wfile.write(e.read())
        except Exception as e:
            self.send_response(502)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers(); self.wfile.write(str(e).encode())
    def serve_file(self, fp):
        ext  = os.path.splitext(fp)[1]
        mime = {'.html':'text/html','.js':'application/javascript',
                '.css':'text/css','.png':'image/png','.jpg':'image/jpeg'}.get(ext,'application/octet-stream')
        with open(fp, 'rb') as f: data = f.read()
        self.send_response(200)
        self.send_header('Content-Type', mime+'; charset=utf-8')
        self.send_header('Content-Length', len(data))
        self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
http.server.HTTPServer(('', PORT), Handler).serve_forever()
