"""比较 fingerprint_probe 产物；不把随机密钥、GREASE 或 ACK 时序当成稳定指纹。"""
import argparse
import json
from pathlib import Path

from audit_fetch_metadata import audit


def grease(value):
    return value & 0x0F0F == 0x0A0A and value >> 8 == value & 255


def extension_ids(hello):
    kinds = {'ServerName': 0, 'SupportedGroups': 10, 'ECPointFormats': 11,
             'ApplicationLayerProtocolNegotiation': 16, 'SignatureAlgorithms': 13,
             'SupportedVersions': 43, 'CertificateCompression': 27,
             'EncryptedClientHello': 65037, 'RecordSizeLimit': 28}
    ids = []
    for entry in hello['extensions']:
        kind = next(iter(entry))
        value = entry[kind]
        if kind == 'Opaque':
            number = value['id']
        elif kind == 'ApplicationSettings':
            number = 17513 if value['new_codepoint'] else 17613
        else:
            number = kinds[kind]
        if not grease(number) and number not in (21, 41, 44):
            ids.append(number)
    return ids


def stable_tls(hello):
    fields = {'cipher_suites': [v for v in hello['cipher_suites'] if not grease(v)],
              'compression_algorithms': hello['compression_algorithms'],
              'protocol_version': hello['protocol_version']}
    for entry in hello['extensions']:
        kind = next(iter(entry))
        if kind in ('SupportedGroups', 'SupportedVersions', 'SignatureAlgorithms'):
            fields[kind] = [v for v in entry[kind] if not grease(v)]
        elif kind in ('ApplicationSettings', 'ApplicationLayerProtocolNegotiation',
                      'CertificateCompression', 'ECPointFormats', 'RecordSizeLimit'):
            fields[kind] = entry[kind]
        elif kind == 'Opaque' and entry[kind]['id'] == 51:
            data = bytes(entry[kind]['data'])
            shapes = []
            cursor = 2
            while cursor + 4 <= len(data):
                group = int.from_bytes(data[cursor:cursor+2], 'big')
                size = int.from_bytes(data[cursor+2:cursor+4], 'big')
                assert cursor + 4 + size <= len(data), 'truncated key_share'
                if not grease(group):
                    shapes.append([group, size])
                cursor += 4 + size
            fields['key_share_shapes'] = shapes
    return fields


def initial_frames(template):
    return [f for f in template['early_frames']
            if not ('Settings' in f and f['Settings']['flags'] & 1)]


def compare(folder):
    load = lambda name: json.loads((folder / name).read_text(encoding='utf-8'))
    reference = load('reference.json')
    hello = reference['hello']
    policy = reference.get('tls_permute_extensions')
    connections = []
    paths = sorted(folder.glob('core-[0-9]*.json'))
    paths.extend(sorted(folder.glob('scenario-*-core.json')))
    if (folder / 'restored-core.json').exists():
        paths.append(folder / 'restored-core.json')
    for path in paths:
        actual = json.loads(path.read_text(encoding='utf-8'))
        checks = {
            'stable_tls_fields': stable_tls(hello) == stable_tls(actual['hello']),
            'tls_extension_set': sorted(extension_ids(hello)) == sorted(extension_ids(actual['hello'])),
            'h2_initial_frames': initial_frames(reference) == initial_frames(actual),
            'h2_pseudo_order': reference['pseudo_order'] == actual['pseudo_order'],
            'accept_encoding': reference['accept_encoding'] == actual['accept_encoding'],
        }
        if reference.get('fetch_h2_priority') is not None:
            expected_priority = dict(reference['fetch_h2_priority'])
            if expected_priority.get('dependency') is not None:
                # 采样流号属于另一条连接；生产 fetch 保留属性并重挂当前连接根节点。
                expected_priority['dependency'] = dict(expected_priority['dependency'], dependency_id=0)
            checks['h2_fetch_priority'] = expected_priority == actual.get('fetch_h2_priority')
        if policy is False:
            checks['fixed_extension_order'] = extension_ids(hello) == extension_ids(actual['hello'])
        if reference.get('low_entropy_client_hints') is not None:
            checks['sampled_client_hints'] = reference['low_entropy_client_hints'] == actual['low_entropy_client_hints']
        differences = {}
        expected_tls, actual_tls = stable_tls(hello), stable_tls(actual['hello'])
        for key in expected_tls.keys() | actual_tls.keys():
            if expected_tls.get(key) != actual_tls.get(key):
                differences[key] = {'reference': expected_tls.get(key), 'actual': actual_tls.get(key)}
        if not checks['tls_extension_set']:
            differences['extension_ids'] = {'reference': extension_ids(hello), 'actual': extension_ids(actual['hello'])}
        connections.append({'file': path.name, 'checks': checks, 'tls_differences': differences})
    emitted = load('emitted-hellos.json')
    orders = {tuple(extension_ids(h)) for h in emitted}
    checks = {'three_connections': len(list(folder.glob('core-[0-9]*.json'))) == 3,
              'wire_checks': all(all(c['checks'].values()) for c in connections)}
    # 单独核对原始三次 API 请求，避免 TLS/H2 通过掩盖旧 WebKit 多发请求头。
    checks['fetch_metadata_presence'] = audit(folder).get('all_match', False)
    if reference.get('hpack_indexing') is not None:
        hpack_policy = reference['hpack_indexing']
        if 'if-none-match' in hpack_policy:
            rows = load('core-headers.json')
            checks['hpack_conditional_indexing'] = len(rows) == 3 and all(
                row.get('hpack_indexing', {}).get('if-none-match') == hpack_policy['if-none-match']
                for row in rows)
    if (folder / 'scenarios.json').exists():
        scenarios = load('scenarios.json')
        checks['transport_scenarios'] = len(scenarios) == 5 and all(s['passed'] for s in scenarios)
        checks['scenario_wire_captures'] = len(list(folder.glob('scenario-*-core.json'))) == 4
    if policy is not None:
        checks['permutation_policy'] = len(orders) > 1 if policy else all(extension_ids(h) == extension_ids(hello) for h in emitted)
    if (folder / 'template-cache.json').exists():
        cached = load('template-cache.json')
        checks['cache_matches_calibrated_template'] = (
            initial_frames(reference) == initial_frames(cached)
            and all(reference.get(k) == cached.get(k) for k in (
                'pseudo_order', 'fetch_header_order', 'accept_encoding', 'low_entropy_client_hints',
                'tls_permute_extensions', 'user_agent', 'hpack_indexing')))
    result = {'browser': reference['user_agent'], 'permutation_policy': policy,
              'distinct_emitted_orders': len(orders), 'checks': checks, 'connections': connections,
              'all_checked_fields_match': all(checks.values()),
              'excluded': ['random/key material', 'GREASE values', 'ECH ciphertext',
                           'padding length', 'PSK/cookie extensions', 'SETTINGS ACK timing'],
              'not_verified': ['platforms/devices outside the supplied capture and full application flow', 'Cloudflare outcome',
                               'cross-connection H2 dependency-tree identity; sampled weights are reanchored to root',
                               'navigation/resource priority and exact HPACK bytes', 'QUIC/H3 fingerprint']}
    (folder / 'comparison.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('folders', nargs='+', type=Path)
    parser.add_argument('--expect-match', action='store_true')
    args = parser.parse_args()
    valid = True
    for folder in args.folders:
        result = compare(folder)
        valid &= result['all_checked_fields_match']
        print(folder.name, json.dumps(result['checks'], ensure_ascii=False))
    if args.expect_match and not valid:
        raise SystemExit(1)
