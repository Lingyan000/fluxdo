#!/usr/bin/env python3
"""macOS 传输对照：相同回环响应、交错运行、进程 CPU/RSS；不包含渲染。"""
import argparse
import http.server
import json
import pathlib
import re
import subprocess
import threading
import time


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        time.sleep(.01)
        self.send_response(200)
        self.send_header('Content-Length', '65536')
        self.end_headers()
        self.wfile.write(b'x' * 65536)

    def log_message(self, *args):
        pass


def main(args):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    results = []

    def run(name, command):
        result = subprocess.run(['/usr/bin/time', '-l', *command], capture_output=True, text=True, timeout=60, check=True)
        data = json.loads(result.stdout)
        data['mode'] = name
        for pattern, key in [(r'(\d+)\s+maximum resident set size', 'rss_bytes'), (r'([\d.]+) user', 'user_s'), (r'([\d.]+) sys', 'sys_s')]:
            match = re.search(pattern, result.stderr)
            if match:
                data[key] = float(match.group(1))
        results.append(data)
        print(json.dumps(data), flush=True)

    try:
        for index in range(5):
            for name in (['baseline', 'candidate'] if index % 2 == 0 else ['candidate', 'baseline']):
                run(name, [getattr(args, name), f'http://127.0.0.1:{server.server_port}/avatar', '600', '12'])
        for scenario, count in [('normal', '100'), ('slow', '5'), ('stall', '3')]:
            for mode in ['baseline', 'backup']:
                run('tls-' + mode, [args.tls_probe, mode, scenario, count])
    finally:
        server.shutdown()
        server.server_close()
        pathlib.Path(args.output).write_text(json.dumps(results, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ['baseline', 'candidate', 'tls-probe', 'output']:
        parser.add_argument('--' + field, required=True)
    main(parser.parse_args())
