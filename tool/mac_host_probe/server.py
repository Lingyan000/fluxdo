"""Synthetic local HTTPS fixture; never uses a community account or credentials."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import json
import ssl

app_id = "01a1b02d-04ed-7342-baa5-769b244b7b9a"
origin = "https://localhost:8765"
entry = origin + "/apps/" + app_id + "?embed_mode=true&room=42#invite"
hash_value = "a" * 64
assets = {key: "/plugins/discourse-mini-app/runtime/" + stem + "-" + hash_value + "." + ext for key, stem, ext in [
    ("loader", "loader", "js"), ("frameHostStyle", "frame-host", "css"), ("errorStyle", "error", "css")
]}
assets.update({key: "/mini-app-api/workers/" + stem + "-" + hash_value + ".js" for key, stem in [
    ("packageWorker", "package-worker"), ("preflightWorker", "package-preflight-worker")
]})
boot = {"configuration": {"appId": app_id, "anonymous": False, "channel": "production"}, "entry": entry,
        "prefix": "", "expectedUserId": 2, "failureMessage": "Host failed"}
source = Path("lib/modules/mini_apps/mini_app_lightweight_host.dart").read_text(encoding="utf-8")
script = source.split("static const script = r'''", 1)[1].split("''';", 1)[0]
html = '''<!doctype html><html><head><meta charset="utf-8"><meta name="csrf-token" content="">
<meta http-equiv="Content-Security-Policy" content="object-src 'none'; base-uri 'none'"></head><body>
<main class="mini-app-page"><header class="mini-app-page__header"><button class="mini-app-page__audio-trigger"></button></header>
<section class="mini-app-loader is-loading"><div class="mini-app-loader__loading"><strong data-role="stage">Preparing</strong>
<progress></progress><span data-role="detail"></span><button data-action="retry" hidden>Retry</button></div></section></main>
<script type="application/json" id="fluxdo-mini-app-release"></script><script type="application/json" id="fluxdo-mini-app-boot-failure"></script>
<script>const boot = BOOT; SCRIPT</script></body></html>'''.replace("BOOT", json.dumps(boot)).replace("SCRIPT", script)
Path("build/mac-probe/host.html").write_text(html, encoding="utf-8")

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        cookie_ok = "probe_session=synthetic" in self.headers.get("Cookie", "")
        print(json.dumps({"path": self.path, "cookiePresent": cookie_ok}), flush=True)
        status, mime = 200, "application/json"
        if self.path.startswith("/apps/"):
            body, mime = html.encode(), "text/html; charset=utf-8"
        elif self.path == "/mini-app-api/runtime-assets.json":
            body = json.dumps({"runtimeAssets": assets}).encode()
        elif self.path in ("/session/current.json", "/session/csrf"):
            status = 200 if cookie_ok else 403
            body = json.dumps({"current_user": {"id": 2, "username": "fixture"}} if self.path.endswith("current.json") else {"csrf": "synthetic"}).encode()
        elif self.path == assets["loader"]:
            mime = "application/javascript"
            body = b'''export function createUserDataProvider(options) {return {destroy(){}};}
export function mountLoader(root, options) {window.fixtureMounted=true;root.classList.remove('is-loading');
return {destroy(){},setAudioMuted:async value=>options.onAudioStateChange(value)};}'''
        elif self.path.endswith(".css"):
            body, mime = b"", "text/css"
        else:
            body, status = b"{}", 404
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

server = ThreadingHTTPServer(("127.0.0.1", 8765), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("build/mac-probe/cert.pem", "build/mac-probe/key.pem")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
