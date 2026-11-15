"""仅临时云端模拟器的官方 WebView 调试入口；不供产品调用。"""
import base64
from contextlib import contextmanager
from pathlib import Path
import tempfile
from urllib.parse import urlparse


@contextmanager
def scoped_quic_control(adb, env, url):
    if env.get('FLUXDO_NATIVE_PROBE_FORCE_QUIC') != '1':
        yield False
        return
    target = urlparse(url)
    spki = env.get('FLUXDO_NATIVE_PROBE_SPKI', '')
    if (env.get('GITHUB_ACTIONS') != 'true' or target.scheme != 'https' or
            target.hostname != 'localhost' or target.path not in ('/fluxdo-h3', '/fluxdo-probe') or
            target.username or target.password or not target.port or
            len(base64.b64decode(spki, validate=True)) != 32):
        raise ValueError('QUIC control requires an ephemeral runner and exact probe origin/SPKI')
    if (not adb('get-serialno').strip().startswith('emulator-') or
            adb('shell', 'getprop', 'ro.build.type').strip() not in ('userdebug', 'eng')):
        raise RuntimeError('QUIC command line is restricted to a debuggable emulator')
    remote = '/data/local/tmp/webview-command-line'
    existed = adb('shell', f'if [ -e {remote} ]; then printf present; fi') == 'present'
    original = adb('shell', 'cat', remote) if existed else None
    with tempfile.TemporaryDirectory(prefix='fluxdo-quic-control-') as folder:
        local = Path(folder) / 'webview-command-line'
        def write(contents):
            local.write_text(contents)
            adb('push', str(local), remote)
            adb('shell', 'chmod', '644', remote)
        try:
            write('_ --webview-verbose-logging '
                  '--host-resolver-rules="MAP localhost 127.0.0.1" '
                  f'--origin-to-force-quic-on=localhost:{target.port} '
                  f'--ignore-certificate-errors-spki-list={spki}\n')
            yield True
        finally:
            if original is None:
                adb('shell', 'rm', '-f', remote)
            else:
                write(original)
