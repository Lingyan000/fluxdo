#!/usr/bin/env python3
"""保存并恢复官方 Tailscale Action 修改的临时 Mac runner DNS 设置。"""
import argparse
import ipaddress
import json
from pathlib import Path
import subprocess


def read_setting(option):
    return subprocess.check_output(['networksetup', option, 'Ethernet'], text=True, timeout=15).splitlines()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--restore', action='store_true')
    args = parser.parse_args()
    if args.restore:
        if not args.state.exists():
            return
        data = json.loads(args.state.read_text())
        for option, values in [('-setdnsservers', data['dns']), ('-setsearchdomains', data['search'])]:
            subprocess.run(['sudo', 'networksetup', option, 'Ethernet', *(values or ['Empty'])], check=True, timeout=15)
        subprocess.run(['sudo', 'dscacheutil', '-flushcache'], check=True, timeout=15)
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
