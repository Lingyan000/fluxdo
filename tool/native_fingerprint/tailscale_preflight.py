"""单节点可信证书预检；不是跨节点路由、真实 WebView 或 H3 校准通过证明。"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor


def public_config(value):
    if set(value) != {'client_id', 'audience'}:
        raise ValueError('Only public client_id and audience are accepted')
    for field, text in value.items():
        if (not isinstance(text, str) or not re.fullmatch(r'[A-Za-z0-9_.:/-]{1,256}', text)
                or text.startswith('tskey-')):
            raise ValueError(f'Missing or invalid public {field}; do not supply an auth key or secret')
    return value


def node_identity(status):
    if status.get('BackendState') != 'Running':
        raise ValueError('Tailscale is not running')
    own = status['Self']
    domain = own['DNSName'].rstrip('.')
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.[a-z0-9-]+\.ts\.net', domain):
        raise ValueError('Expected this node fully qualified ts.net name')
    address = next((ip for ip in own['TailscaleIPs']
                    if ipaddress.ip_address(ip).version == 4 and
                    ipaddress.ip_address(ip) in ipaddress.ip_network('100.64.0.0/10')), None)
    if address is None:
        raise ValueError('Missing local tailnet IPv4 address')
    return domain, address


def socket_checks(cert, key, domain, address, *, cafile=None):
    server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server.load_cert_chain(cert, key)
    client = ssl.create_default_context(cafile=cafile)
    payload = os.urandom(1200)
    with socket.socket() as listener, ThreadPoolExecutor(max_workers=1) as executor:
        listener.settimeout(5)
        listener.bind((address, 0))
        listener.listen(1)

        def echo():
            connection, _ = listener.accept()
            connection.settimeout(5)
            with server.wrap_socket(connection, server_side=True) as tls:
                data = tls.recv(1)
                tls.sendall(data)

        pending = executor.submit(echo)
        with socket.create_connection(listener.getsockname(), timeout=5) as raw:
            with client.wrap_socket(raw, server_hostname=domain) as tls:
                tls.sendall(b'F')
                if tls.recv(1) != b'F':
                    raise ValueError('TLS echo mismatch')
        pending.result(timeout=6)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
        receiver.settimeout(5)
        sender.settimeout(5)
        receiver.bind((address, 0))
        sender.sendto(payload, receiver.getsockname())
        received, source = receiver.recvfrom(1201)
        receiver.sendto(received, source)
        reply, _ = sender.recvfrom(1201)
        if received != payload or reply != payload:
            raise ValueError('UDP echo mismatch')
    return {'system_trust_and_hostname_verified': True, 'local_tailnet_udp_1200_byte_echo': True}


def issue_certificate(folder, domain):
    """证书副本限定在调用者的临时目录；Windows 使用现有管理员服务。"""
    cert, key = folder/'cert.pem', folder/'key.pem'
    prefix = [] if os.name == 'nt' else ['sudo']
    subprocess.run([*prefix, 'tailscale', 'cert', '--cert-file', str(cert), '--key-file', str(key), domain],
                   check=True, timeout=120, stdout=subprocess.DEVNULL)
    if os.name != 'nt':
        subprocess.run(['sudo', 'chown', f'{os.getuid()}:{os.getgid()}', str(cert), str(key)], check=True)
    key.chmod(0o600)
    return cert, key


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.config:
        values = public_config(json.loads(Path(__file__).with_name('tailscale-oidc.json').read_text()))
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            for key, value in values.items():
                output.write(f'{key}={value}\n')
        return
    if args.output is None:
        parser.error('--output is required')
    report = {'passed': False, 'scope': 'one ephemeral Linux node',
              'not_verified': ['cross-node UDP routing', 'native WebView certificate acceptance',
                               'QUIC/H3/QPACK calibration', 'public direct network']}
    try:
        status = json.loads(subprocess.check_output(['tailscale', 'status', '--json'], timeout=20))
        domain, address = node_identity(status)
        report['hostname'] = domain
        # 证书和私钥只在临时目录中存在；不写入输出目录，也不缓存或上传。
        with tempfile.TemporaryDirectory(prefix='fluxdo-cert-') as folder:
            cert, key = issue_certificate(Path(folder), domain)
            report['checks'] = socket_checks(cert, key, domain, address)
            report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report))
    raise SystemExit(0 if report['passed'] else 1)


if __name__ == '__main__':
    main()
