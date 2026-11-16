#!/usr/bin/env python3
"""保存并恢复官方 Tailscale Action 修改的临时 Mac runner DNS 设置。"""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import socket
import subprocess
import tempfile


def resolver_for(status):
    host = status['Self']['DNSName'].rstrip('.')
    if status.get('BackendState') != 'Running' or not re.fullmatch(r'[a-z0-9][a-z0-9-]*\.[a-z0-9-]+\.ts\.net', host):
        raise ValueError('Expected a running node with its own tailnet DNS name')
    domain = host.split('.', 1)[1]
    return '/etc/resolver/'+domain, '# FluxDO ephemeral CI resolver\nnameserver 100.100.100.100\n'


def restore_public_dns(data):
    for option, values in [('-setdnsservers', data['dns']), ('-setsearchdomains', data['search'])]:
        subprocess.run(['sudo', 'networksetup', option, 'Ethernet', *(values or ['Empty'])], check=True, timeout=15)
    subprocess.run(['sudo', 'dscacheutil', '-flushcache'], check=True, timeout=15)


def read_setting(option):
    return subprocess.check_output(['networksetup', option, 'Ethernet'], text=True, timeout=15).splitlines()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--restore', action='store_true')
    parser.add_argument('--split', action='store_true')
    args = parser.parse_args()
    if args.restore and args.split:
        parser.error('--restore and --split cannot be combined')
    if args.split:
        data = json.loads(args.state.read_text())
        status = json.loads(subprocess.check_output(['tailscale', 'status', '--json'], timeout=20))
        path, content = resolver_for(status)
        # 公网解析保留 runner 原设置；仅当前 tailnet 的域名走 MagicDNS。
        # daemon 也会创建分域文件；先让它撤回自身配置，再判断是否有其他现存配置。
        subprocess.run(['sudo', 'tailscale', 'set', '--accept-dns=false'], check=True, timeout=20)
        restore_public_dns(data)
        if Path(path).exists():
            raise RuntimeError('Refusing to replace an existing scoped resolver after disabling managed DNS')
        data['owned_resolver'] = {'path': path, 'content': content}
        args.state.write_text(json.dumps(data)+'\n')
        with tempfile.NamedTemporaryFile(mode='w') as source:
            source.write(content)
            source.flush()
            subprocess.run(['sudo', 'mkdir', '-p', '/etc/resolver'], check=True, timeout=15)
            subprocess.run(['sudo', 'install', '-m', '644', source.name, path], check=True, timeout=15)
        subprocess.run(['sudo', 'dscacheutil', '-flushcache'], check=True, timeout=15)
        for host in ('acme-v02.api.letsencrypt.org', status['Self']['DNSName'].rstrip('.')):
            socket.getaddrinfo(host, 443)
            print('DNS resolved: '+host, flush=True)
        return
    if args.restore:
        if not args.state.exists():
            return
        data = json.loads(args.state.read_text())
        owned = data.get('owned_resolver')
        if owned and Path(owned['path']).exists():
            if Path(owned['path']).read_text() != owned['content']:
                raise RuntimeError('Scoped resolver changed; refusing to remove it')
            subprocess.run(['sudo', 'rm', '--', owned['path']], check=True, timeout=15)
        restore_public_dns(data)
        print('Restored the runner DNS and search domains saved before Tailscale')
        return
    servers = []
    for line in read_setting('-getdnsservers'):
        try:
            ipaddress.ip_address(line)
            servers.append(line)
        except ValueError:
            pass
    # 没有配置时 networksetup 返回说明句；域名不含空白。
    search = [line for line in read_setting('-getsearchdomains') if line and not any(c.isspace() for c in line)]
    args.state.write_text(json.dumps({'dns': servers, 'search': search})+'\n')


if __name__ == '__main__':
    main()
