"""补查真实抓包中的 Fetch Metadata 头是否存在；不推断请求上下文或改写请求。"""
import argparse
import json
from pathlib import Path


def audit(folder):
    reference = json.loads((folder / 'reference.json').read_text(encoding='utf-8'))
    if reference.get('low_entropy_client_hints') is None:
        return {'verified': False, 'reason': '参考模板尚未确认采到 fetch 请求'}
    expected = sorted(name.lower() for name in reference['fetch_header_order']
                      if name.lower().startswith('sec-fetch-'))
    requests = json.loads((folder / 'core-headers.json').read_text(encoding='utf-8'))
    checks = []
    for request in requests:
        actual = sorted(name.lower() for name, _ in request['headers']
                        if name.lower().startswith('sec-fetch-'))
        checks.append({'uri': request['uri'], 'expected_names': expected,
                       'actual_names': actual, 'matches': actual == expected})
    result = {'verified': bool(checks), 'reference_user_agent': reference.get('user_agent'),
              'requests': checks, 'all_match': bool(checks) and all(c['matches'] for c in checks),
              'scope': '仅检查原始三次 Core 请求的头存在性；不证明头值、完整应用链或 CF 结果'}
    (folder / 'fetch-metadata-audit.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('folders', nargs='+', type=Path)
    args = parser.parse_args()
    passed = True
    for folder in args.folders:
        result = audit(folder)
        print(folder, json.dumps(result, ensure_ascii=False))
        passed &= result.get('all_match', False)
    raise SystemExit(0 if passed else 1)
