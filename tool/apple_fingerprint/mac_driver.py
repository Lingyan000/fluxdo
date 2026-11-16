#!/usr/bin/env python3
"""仅在一次性 CI Mac 安装回环实验 CA，运行原生宿主后删除该证书与信任设置。"""
import hashlib
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys

if os.environ.get('GITHUB_ACTIONS') != 'true':
    raise SystemExit('system-trust experiment requires an ephemeral GitHub runner')
ca = Path(os.environ['FLUXDO_APPLE_LAB_CA'])
der = ssl.PEM_cert_to_DER_cert(ca.read_text())
fingerprint = hashlib.sha1(der).hexdigest().upper()
keychain = '/Library/Keychains/System.keychain'
subprocess.run(['sudo', 'security', 'add-trusted-cert', '-d', '-r', 'trustRoot',
                '-k', keychain, str(ca)], check=True, timeout=30)
print(json.dumps({'lab_system_trust': True, 'ca_sha256': hashlib.sha256(der).hexdigest()}), flush=True)
try:
    result = subprocess.run([os.environ['FLUXDO_MAC_DRIVER_BINARY'], *sys.argv[1:]], timeout=80)
    code = result.returncode
finally:
    try:
        subprocess.run(['sudo', 'security', 'remove-trusted-cert', '-d', str(ca)], timeout=30, check=True)
    finally:
        # 信任设置删除失败也必须尝试删除本轮证书；失败保留为实验失败，不隐藏。
        subprocess.run(['sudo', 'security', 'delete-certificate', '-Z', fingerprint, keychain], timeout=30, check=True)
raise SystemExit(code)
