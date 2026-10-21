#!/usr/bin/env python3
"""Loopback-only fixture server with an explicit graceful stop endpoint."""
from pathlib import Path
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import sys
import threading
import time

base = Path(sys.argv[1]).resolve()
allowed = Path.home() / 'Library/Caches/Vibekey/OwnedProbes'
if not base.is_relative_to(allowed) or not base.name.startswith('update-acceptance-'):
    raise SystemExit('Owned fixture directory required.')
config = json.loads((base / 'fixture.json').read_text())

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs): super().__init__(*args, directory=config['serverDirectory'], **kwargs)
    def log_message(self, *_): pass
    def do_GET(self):
        with (base / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'path': self.path.split('?')[0], 'at': time.time()}) + '\n')
        super().do_GET()
    def do_POST(self):
        if self.path != '/__stop': self.send_error(404); return
        self.send_response(200); self.end_headers()
        threading.Thread(target=self.server.shutdown, daemon=True).start()

server = ThreadingHTTPServer(('127.0.0.1', config['port']), Handler)
print(json.dumps({'status': 'LISTENING_LOOPBACK', 'port': config['port']}), flush=True)
server.serve_forever(); server.server_close()
