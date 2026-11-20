"""用 Python/OpenSSL 的独立 TLS 1.3 服务端限制组和证书密钥类型，驱动生产 Core。"""
import argparse
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import threading

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--sample-dir', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True)
repo = Path(__file__).resolve().parents[3]
results = []
for group, key_type in [('X448', 'rsa:2048'), ('ffdhe2048', 'rsa:2048'),
                        ('X25519', 'rsa-pss'), ('X25519', 'ed448')]:
    folder = args.output / (group + '-' + key_type.replace(':', '-'))
    folder.mkdir()
    cert, key = folder / 'cert.pem', folder / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', key_type, '-noenc', '-days', '1',
                    '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
                    '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    key.chmod(0o600)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.set_ecdh_curve(group)
    context.set_alpn_protocols(['http/1.1'])
    context.load_cert_chain(cert, key)
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    listener.settimeout(10)
    record = {'only_allowed_group': group, 'certificate_key_type': key_type, 'openssl': ssl.OPENSSL_VERSION}

    def serve():
        try:
            raw, _ = listener.accept()
            with context.wrap_socket(raw, server_side=True) as conn:
                conn.settimeout(10)
                request = b''
                while b'\r\n\r\n' not in request:
                    data = conn.recv(4096)
                    if not data:
                        raise EOFError('request ended early')
                    request += data
                record.update(tls_version=conn.version(), cipher=conn.cipher(), alpn=conn.selected_alpn_protocol())
                conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok')
        except Exception as error:
            record['server_error'] = str(error)
        finally:
            listener.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    process = subprocess.run([str(repo / 'core/net_core/target/debug/examples/linux_tls_negotiation'),
                              str(listener.getsockname()[1]), str(args.sample_dir.resolve())],
                             env=dict(os.environ, SSL_CERT_FILE=str(cert.resolve())),
                             capture_output=True, text=True, timeout=20)
    thread.join(timeout=12)
    (folder / 'client.stdout').write_text(process.stdout)
    (folder / 'client.stderr').write_text(process.stderr)
    record['exit_code'] = process.returncode
    record['passed'] = process.returncode == 0 and record.get('tls_version') == 'TLSv1.3' and 'server_error' not in record
    results.append(record)
    (args.output / 'matrix.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(record), flush=True)
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
