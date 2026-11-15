"""只统计指定本机探针的 QUIC；浏览器后台联网不能冒充采样成功。"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re


def summarize(data, ports):
    names = {value: key for key, value in data['constants']['logEventTypes'].items()}
    events = data['events']
    sessions = {}
    for event in events:
        params = event.get('params', {})
        if (names.get(event['type']) == 'QUIC_SESSION' and params.get('host') == 'localhost'
                and params.get('port') in ports):
            sessions[event['source']['id']] = params['port']
    counts = Counter()
    errors = []
    alternatives = 0
    for event in events:
        name = names.get(event['type'], str(event['type']))
        params = event.get('params', {})
        if name == 'HTTP_STREAM_JOB_CONTROLLER_ALT_SVC_FOUND':
            match = re.search(r'\blocalhost:(\d+)(?:,|\s|$)', params.get('alt_svc', ''))
            if match and int(match[1]) in ports:
                alternatives += 1
        if event['source']['id'] not in sessions:
            continue
        counts[name] += 1
        if 'QUIC' in name and any(key in params for key in ('net_error', 'quic_error', 'details')):
            errors.append({'event': name, 'params': params})
    return {'probe_ports': sorted(ports), 'local_quic_sessions': len(sessions),
            'local_alt_svc_events': alternatives, 'local_session_events': dict(counts),
            'local_errors': errors,
            'scope': 'localhost probe sessions only; background browser requests excluded'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    rows = []
    for path in sorted(args.folder.rglob('browser-netlog-*.json')):
        status = json.loads((path.parent / 'status.json').read_text())
        row = summarize(json.loads(path.read_text()), set(status['h3']['probe_ports']))
        row['file'] = str(path.relative_to(args.folder))
        rows.append(row)
        print(row['file'], 'local QUIC sessions:', row['local_quic_sessions'],
              'Alt-Svc events:', row['local_alt_svc_events'])
    (args.folder / 'netlog-summary.json').write_text(json.dumps(rows, indent=2) + '\n')


if __name__ == '__main__':
    main()
