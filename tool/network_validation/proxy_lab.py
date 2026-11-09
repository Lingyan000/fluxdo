#!/usr/bin/env python3
"""隔离 Mihomo/Chromium TLS 与 Fake-IP 实验；不修改系统代理、DNS 或信任根。"""
import argparse
import asyncio
import base64
import hashlib
import json
import pathlib
import socket
import struct
import subprocess
import tempfile


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


async def main(args):
    root = pathlib.Path(tempfile.mkdtemp(prefix='fluxdo-proxy-lab-'))
    proxy_port, dns_port, shim_port, origin_port = [free_port() for _ in range(4)]
    host = 'recovery.test'
    conf = root / 'cert.conf'
    conf.write_text(f'[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN={host}\n[ext]\nsubjectAltName=DNS:{host}\nbasicConstraints=critical,CA:TRUE\n')
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', str(conf), '-keyout', str(root / 'key.pem'), '-out', str(root / 'cert.pem')], check=True, capture_output=True)
    pub = subprocess.run(['openssl', 'x509', '-in', str(root / 'cert.pem'), '-pubkey', '-noout'], check=True, capture_output=True).stdout
    der = subprocess.run(['openssl', 'pkey', '-pubin', '-outform', 'DER'], input=pub, check=True, capture_output=True).stdout
    spki = base64.b64encode(hashlib.sha256(der).digest()).decode()
    import ssl
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(root / 'cert.pem', root / 'key.pem')
    tls.set_alpn_protocols(['http/1.1'])
    records, results = [], []
    tls.set_servername_callback(lambda _s, name, _c: records.append({'sni': name}))

    async def origin(reader, writer):
        try:
            await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 5)
            body = b'<html><body>FLUXDO_PROXY_LAB_OK</body></html>'
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
            await writer.drain()
        except (OSError, asyncio.IncompleteReadError, asyncio.TimeoutError):
            # Chrome 的预连接不一定发出 HTTP 请求。
            pass
        finally:
            writer.close()

    origin_server = await asyncio.start_server(origin, '127.0.0.1', origin_port, ssl=tls)
    config = root / 'config.yaml'
    config.write_text(f'''mixed-port: {proxy_port}
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: debug
ipv6: false
profile:
  store-fake-ip: false
hosts:
  '{host}': 127.0.0.1
dns:
  enable: true
  listen: 127.0.0.1:{dns_port}
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-hosts: false
  use-system-hosts: false
  nameserver: [223.5.5.5]
  fake-ip-filter: []
sniffer:
  enable: true
  parse-pure-ip: true
  force-dns-mapping: true
  override-destination: true
  sniff:
    TLS:
      ports: [{origin_port}]
rules:
  - MATCH,DIRECT
''')
    mihomo = None
    log = open(root / 'mihomo.log', 'w')

    async def restart():
        nonlocal mihomo
        if mihomo:
            mihomo.terminate()
            await mihomo.wait()
        mihomo = await asyncio.create_subprocess_exec(args.mihomo, '-d', str(root), '-f', str(config), stdout=log, stderr=log)
        for _ in range(100):
            try:
                _, w = await asyncio.open_connection('127.0.0.1', proxy_port)
                w.close()
                await asyncio.sleep(.15)
                return
            except OSError:
                await asyncio.sleep(.05)
        raise RuntimeError('Mihomo 未启动：' + str(root))

    def query_fake():
        name = b''.join(bytes([len(s)]) + s.encode() for s in host.split('.')) + b'\x00'
        query = struct.pack('!HHHHHH', 123, 256, 1, 0, 0, 0) + name + struct.pack('!HH', 1, 1)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(2)
            sock.sendto(query, ('127.0.0.1', dns_port))
            answer = sock.recv(4096)
        ip = socket.inet_ntoa(answer[-4:])
        assert ip.startswith('198.18.'), answer.hex()
        return ip

    target_ip, fragment = '', 0

    async def shim(reader, writer):
        upstream = None
        try:
            header = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 3)
            first = header.split(b'\r\n')[0].decode()
            if first != f'CONNECT {host}:{origin_port} HTTP/1.1':
                writer.write(b'HTTP/1.1 502 Lab target only\r\n\r\n')
                return
            incoming, upstream = await asyncio.open_connection('127.0.0.1', proxy_port)
            upstream.write(f'CONNECT {target_ip}:{origin_port} HTTP/1.1\r\nHost: {target_ip}:{origin_port}\r\n\r\n'.encode())
            await upstream.drain()
            writer.write(await asyncio.wait_for(incoming.readuntil(b'\r\n\r\n'), 3))
            await writer.drain()
            prefix = await asyncio.wait_for(reader.readexactly(5), 3)
            record = prefix + await reader.readexactly(int.from_bytes(prefix[3:5], 'big'))
            records.append({'client_hello_bytes': len(record), 'fragment_bytes': fragment, 'target': target_ip})
            size = fragment or len(record)
            for i in range(0, len(record), size):
                upstream.write(record[i:i + size])
                await upstream.drain()
                if fragment:
                    await asyncio.sleep(.002)

            async def copy(src, dst):
                while True:
                    buf = await src.read(65536)
                    if not buf:
                        return
                    dst.write(buf)
                    await dst.drain()
            tasks = [asyncio.create_task(copy(reader, upstream)), asyncio.create_task(copy(incoming, writer))]
            try:
                await asyncio.wait(tasks, timeout=10, return_when=asyncio.FIRST_COMPLETED)
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
        except (OSError, asyncio.IncompleteReadError, asyncio.TimeoutError):
            pass
        finally:
            writer.close()
            if upstream:
                upstream.close()

    shim_server = await asyncio.start_server(shim, '127.0.0.1', shim_port)

    async def sample(stage, client):
        if client == 'core':
            command = [args.probe, str(shim_port), host, str(origin_port), str(root / 'cert.pem')]
        else:
            profile = root / ('chrome-' + stage)
            command = [args.chrome, '--headless=new', '--disable-gpu', '--no-first-run', '--disable-background-networking', '--disable-component-update', '--no-default-browser-check', '--disable-quic', '--proxy-server=http://127.0.0.1:' + str(shim_port), '--proxy-bypass-list=<-loopback>', '--user-data-dir=' + str(profile), '--ignore-certificate-errors-spki-list=' + spki, '--dump-dom', f'https://{host}:{origin_port}/']
        started = asyncio.get_running_loop().time()
        process = await asyncio.create_subprocess_exec(*command, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), 18)
        except asyncio.TimeoutError:
            process.kill()
            stdout, stderr = await process.communicate()
        (root / f'{stage}-{client}.out').write_bytes(stdout)
        (root / f'{stage}-{client}.err').write_bytes(stderr)
        result = {'stage': stage, 'client': client, 'ok': b'FLUXDO_PROXY_LAB_OK' in stdout, 'elapsed_ms': round((asyncio.get_running_loop().time() - started) * 1000), 'fragment': fragment, 'fake_ip': target_ip}
        results.append(result)
        print(json.dumps(result), flush=True)

    try:
        await restart()
        target_ip = await asyncio.to_thread(query_fake)
        for stage, size in [('intact', 0), ('segmented', 17)]:
            fragment = size
            for client in ['core', 'chromium']:
                await sample(stage, client)
        await restart()
        for stage, size in [('mapping-missing', 0), ('missing-segmented', 17)]:
            fragment = size
            for client in ['core', 'chromium']:
                await sample(stage, client)
        # 同样缺失映射，禁用嗅探构成负向对照，不能把成功归因于旧缓存。
        config.write_text(config.read_text().replace('sniffer:\n  enable: true', 'sniffer:\n  enable: false'))
        await restart()
        fragment = 0
        for client in ['core', 'chromium']:
            await sample('missing-no-sniffer', client)
        target_ip = await asyncio.to_thread(query_fake)
        for client in ['core', 'chromium']:
            await sample('mapping-refreshed', client)
    finally:
        shim_server.close()
        origin_server.close()
        if mihomo:
            mihomo.terminate()
            await mihomo.wait()
        log.close()
        output = {'artifacts': str(root), 'results': results, 'records': records}
        pathlib.Path(args.output).write_text(json.dumps(output, indent=2))
        print('artifacts=' + str(root), flush=True)
    assert len(results) == 12 and all(
        result['ok'] == (result['stage'] != 'missing-no-sniffer')
        for result in results
    ), '对照结果与预期不同，请检查产物中的代理/客户端日志'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ['mihomo', 'chrome', 'probe', 'output']:
        parser.add_argument('--' + field, required=True)
    asyncio.run(main(parser.parse_args()))
