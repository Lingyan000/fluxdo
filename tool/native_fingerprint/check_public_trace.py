"""只读核对公开诊断页是否声明 H3；不保存响应中的出口 IP。"""
import json
from pathlib import Path
import sys
import urllib.request
import urllib.error


def main():
    rows = []
    targets = {
        'cloudflare-quic.com': ('/', '/cdn-cgi/trace'),
        'one.one.one.one': ('/', '/cdn-cgi/trace'),
        'www.cloudflare.com': ('/robots.txt', '/cdn-cgi/trace'),
        'speed.cloudflare.com': ('/__down?bytes=0', '/cdn-cgi/trace'),
    }
    for host, paths in targets.items():
        for path in paths:
            row = {'url': 'https://'+host+path}
            try:
                try:
                    response = urllib.request.urlopen(row['url'], timeout=10)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    row.update(status=response.status, final_url=response.url,
                               alt_svc=response.headers.get('alt-svc'), server=response.headers.get('server'))
                    if path.endswith('/trace'):
                        fields = dict(line.split('=', 1) for line in response.read(8192).decode().splitlines() if '=' in line)
                        row['trace'] = {k: fields.get(k) for k in ('http', 'tls', 'sni')}
            except Exception as error:
                row['error'] = str(error)
            rows.append(row)
            print(json.dumps(row), flush=True)
    Path(sys.argv[1]).write_text(json.dumps(rows, indent=2)+'\n')


if __name__ == '__main__':
    main()
