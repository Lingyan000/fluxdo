"""Synthetic local HTTPS fixture; never uses a community account or credentials."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import json
import ssl
import hashlib

app_id = "01a1b02d-04ed-7342-baa5-769b244b7b9a"
origin = "https://community.miniapp-probe.test:8765"
entry = origin + "/apps/" + app_id + "?embed_mode=true&room=42#invite"
hash_value = "a" * 64
assets = {key: "/plugins/discourse-mini-app/runtime/" + stem + "-" + hash_value + "." + ext for key, stem, ext in [
    ("loader", "loader", "js"), ("frameHostStyle", "frame-host", "css"), ("errorStyle", "error", "css")
]}
assets.update({key: "/mini-app-api/workers/" + stem + "-" + hash_value + ".js" for key, stem in [
    ("packageWorker", "package-worker"), ("preflightWorker", "package-preflight-worker")
]})
configuration = {"appId": app_id, "anonymous": False, "channel": "production", "name": "Fixture",
    "frameHostUrl": "/mini-app-api/frame-host", "translations": {"errors": {"ACCESS_DENIED": "EXPECTED_FIXTURE_DENIAL"}}}
for action in ["launch", "check", "runtime", "usage"]:
    configuration[action + "Url"] = "/mini-app-api/production/" + app_id + "/" + action
configuration["httpAuthorizationUrl"] = "/mini-app-api/production/" + app_id + "/http-authorization"
configuration["webSocketAuthorizationUrl"] = "/mini-app-api/production/" + app_id + "/websocket-authorization"
sdk_path = Path('build/mac-probe/official-sdk.js')
sdk = sdk_path.read_bytes() if sdk_path.exists() else b"export const fixture=true;"
configuration.update({"sdkUrl": origin + "/sdk.js", "sdkSha256": hashlib.sha256(sdk).hexdigest(), "sdkByteLength": len(sdk)})
manifest = {"id": app_id, "name": "Fixture", "format": 1, "version": "1.0.0", "entry": "index.html", "script": "app.js", "style": "app.css", "permissions": []}
files = {"manifest.json": json.dumps(manifest), "index.html": '<p id="fixture">Synthetic app</p>', "app.css": 'body{background:#ddeeff}', "app.js": 'miniApp.ready().then(()=>miniApp.rendered());', "strings.json": '{}'}
release = {"id": 1, "app_id": app_id, "name": "Fixture", "description": "Synthetic", "version": "1.0.0", "release_notes": "", "channel": "production", "manifest": manifest, "permissions": [], "package_url": origin + '/package.bin', "package_size": 128, "package_password": "synthetic", "public_key": {}, "zip_sha256": 'b' * 64}
boot = {"configuration": configuration, "entry": entry,
        "prefix": "", "expectedUserId": 2, "failureMessage": "Host failed"}
source = Path("lib/modules/mini_apps/mini_app_lightweight_host.dart").read_text(encoding="utf-8")
script = source.split("static const script = r'''", 1)[1].split("''';", 1)[0]
html = '''<!doctype html><html><head><meta charset="utf-8"><meta name="csrf-token" content="">
<meta http-equiv="Content-Security-Policy" content="object-src 'none'; base-uri 'none'"></head><body>
<main class="mini-app-page"><header class="mini-app-page__header"><button class="mini-app-page__audio-trigger"></button></header>
<section class="mini-app-loader is-loading"><div class="mini-app-loader__viewport"><div class="mini-app-loader__loading"><strong data-role="stage">Preparing</strong>
<progress></progress><span data-role="detail"></span><button data-action="retry" hidden>Retry</button></div>
<div class="mini-app-loader__frame" inert></div></div><div class="mini-app-loader__media"></div></section></main>
<script type="application/json" id="fluxdo-mini-app-release"></script><script type="application/json" id="fluxdo-mini-app-boot-failure"></script>
<script>const boot = BOOT; SCRIPT</script></body></html>'''.replace("BOOT", json.dumps(boot)).replace("SCRIPT", script)
html = html.replace('</body>', '<script src="/sandbox-probe.js"></script></body>')
Path("build/mac-probe/host.html").write_text(html, encoding="utf-8")
Path("build/mac-probe/configuration.json").write_text(json.dumps(configuration), encoding="utf-8")

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        cookie_ok = "probe_session=synthetic" in self.headers.get("Cookie", "")
        print(json.dumps({"path": self.path, "cookiePresent": cookie_ok}), flush=True)
        status, mime = 200, "application/json"
        headers = {}
        if self.path.startswith("/apps/"):
            body, mime = html.encode(), "text/html; charset=utf-8"
        elif self.path == '/sandbox-probe.js':
            body, mime = Path('tool/mac_host_probe/sandbox-probe.js').read_bytes(), 'application/javascript'
        elif self.path.startswith('/probe-frame?policy='):
            policy = self.path.split('=')[-1]
            if policy in ('csp', 'both'):
                headers['Content-Security-Policy'] = "default-src 'none'; style-src 'self'; frame-src 'self'; frame-ancestors 'self'"
            if policy in ('xfo', 'both'):
                headers['X-Frame-Options'] = 'SAMEORIGIN'
            body, mime = b'<!doctype html><html><head><meta name="discourse-mini-app-host" content="1"></head><body></body></html>', 'text/html'
        elif self.path == '/probe-runtime':
            headers['Content-Security-Policy'] = "sandbox allow-scripts; script-src 'unsafe-inline'; default-src 'none'"
            body, mime = b'''<!doctype html><script>{const channel = new MessageChannel();channel.port1.onmessage=e=>{document.open();document.write(e.data.html);document.close();};parent.postMessage({type:'fixture-ready'},'*',[channel.port2]);}</script>''', 'text/html'
        elif self.path == "/mini-app-api/runtime-assets.json":
            body = json.dumps({"runtimeAssets": assets, **{k: v for k, v in configuration.items() if k.startswith("sdk")}}).encode()
        elif self.path in ("/session/current.json", "/session/csrf"):
            status = 200 if cookie_ok else 403
            body = json.dumps({"current_user": {"id": 2, "username": "fixture"}} if self.path.endswith("current.json") else {"csrf": "synthetic"}).encode()
        elif self.path == assets["loader"]:
            mime = "application/javascript"
            body = Path("build/mac-probe/official-loader.js").read_bytes() if Path("build/mac-probe/use-official").exists() else b'''export function createUserDataProvider(options) {return {destroy(){}};}
export function mountLoader(root, options) {window.fixtureMounted=true;root.classList.remove('is-loading');
return {destroy(){},setAudioMuted:async value=>options.onAudioStateChange(value)};}'''
        elif self.path == "/sdk.js":
            body, mime = sdk, "application/javascript"
        elif self.path == assets['packageWorker']:
            # Only replaces cryptographic package processing in this isolated fixture.
            body, mime = ('onmessage=()=>postMessage({type:"complete",files:' + json.dumps(files) + '});').encode(), 'application/javascript'
        elif self.path == '/package.bin':
            body, mime = bytes(128), 'application/octet-stream'
        elif self.path == configuration['frameHostUrl']:
            headers['Content-Security-Policy'] = "default-src 'none'; style-src 'self'; frame-src 'self'; frame-ancestors 'self'"
            body, mime = b'<!doctype html><html><head><meta name="discourse-mini-app-host" content="1"></head><body></body></html>', 'text/html'
        elif self.path.startswith(configuration['runtimeUrl']):
            headers['Content-Security-Policy'] = "sandbox allow-scripts; script-src 'unsafe-inline'; default-src 'none'"
            body, mime = b'''<!doctype html><script>{const instance=location.hash.slice(1);const channel=new MessageChannel();channel.port1.onmessage=e=>{if(e.data.type==='mount-package'&&e.data.instance===instance){document.open();document.write(e.data.html);document.close();}};parent.postMessage({type:'runtime-ready',instance},'*',[channel.port2]);}</script>''', 'text/html'
        elif self.path == configuration["launchUrl"]:
            body = json.dumps({"release": release, "runtime_token": "synthetic", "runtime_context": 'c' * 64}).encode()
        elif self.path.endswith(".css"):
            body, mime = b"", "text/css"
        else:
            body, status = b"{}", 404
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        print(json.dumps({"path": self.path, "method": "POST"}), flush=True)
        body = b'{"error":"ACCESS_DENIED"}'
        self.send_response(403)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

server = ThreadingHTTPServer(("127.0.0.1", 8765), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("build/mac-probe/cert.pem", "build/mac-probe/key.pem")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
