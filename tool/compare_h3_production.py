"""核对真实采样与生产 H3 报文；失败字段原样保留，不把能联网当成等价。"""
import argparse
import json
from pathlib import Path
from compare_fingerprint_capture import stable_tls, extension_ids


def reserved(value):
    return value >= 0x21 and (value - 0x21) % 0x1f == 0


def parameters(rows):
    result = []
    for row in rows:
        number, value = row['id'], row['value']
        # initial_rtt 是路径测量值；源 CID 属于当前连接；版本随机数单独核对。
        if number == 12583:
            continue
        if number>=27 and (number-27)%31==0:
            number, value = 'reserved', None
        elif number == 15:
            value = len(value)
        elif number in (17,0xff73db):
            values = [int.from_bytes(bytes(value[i:i+4]), 'big') for i in range(0, len(value), 4)]
            value = [v for v in values if v & 0x0f0f0f0f != 0x0a0a0a0a]
        result.append((str(number), value))
    return sorted(result)


def settings(boundary):
    return [('reserved', None) if row['grease'] else (row['id'], row['value']) for row in boundary['settings']]


def streams(boundary):
    return sorted((row['stream_id'], row['stream_type']) for row in boundary['streams'])


def controls(boundary):
    # 随机保留类型/负载只核对形状；MAX_PUSH_ID 等已知帧必须比较实际语义值。
    return [('reserved', row['length']) if reserved(row['frame_type']) else
            (row['frame_type'], row['element_id'], row['value'])
            for row in boundary['control'] if row['frame_type'] != 4]


def fields(names, rows):
    result = {}
    for name, row in zip(names, rows, strict=True):
        # 动态索引必须来自新表，不能和另一条连接的数字直接比较。
        static = row['representation'] in ('StaticIndex', 'LiteralStaticName')
        result.setdefault(name, []).append((row['representation'], row['index'] if static else None,
            row['name_huffman'], row['value_huffman'], row['never_index']))
    return result


def complete_boundary(boundary):
    required = ('settings', 'local_settings', 'streams', 'control', 'qpack', 'fields', 'snapshot')
    return (boundary.get('settings_received') is True
            and boundary.get('connection_error') is None
            and all(boundary.get('completeness', {}).get(key) is True for key in required))


def compare(folder):
    source=json.loads((folder/'client/profile.json').read_text())
    actual=json.loads((folder/'server/h3-capture.json').read_text())
    requests=actual.get('h3', [])
    if not requests:
        result={'checks':{'three_production_h3_requests':False},'all_checked_fields_match':False,
                'field_comparison':[], 'error':'missing production H3 requests'}
        (folder/'comparison.json').write_text(json.dumps(result,indent=2)+'\n')
        return result
    checks={'calibrated':True,'three_production_h3_requests':len(requests)>=3,
        'driver_succeeded':actual.get('driver_success') is True,
        'source_boundary_complete':complete_boundary(source['boundary']),
        'source_warm_boundary_complete':complete_boundary(source['warm_boundary']),
        'no_connection_error':not actual['connection_errors'],
        'transport_parameters':parameters(source['parameters'])==parameters(actual['transport_parameters']),
        'settings':settings(source['boundary'])==settings(requests[0]['first_request_boundary']['snapshot']),
        'initial_control_frames':controls(source['boundary'])==controls(requests[0]['first_request_boundary']['snapshot'])}
    for key in ['version','dcid_len','scid_len','first_packet_number','packet_number_lengths','padding','coalesced','datagram_sizes']:
        checks['initial_'+key]=source['flight'][key]==actual['initial'][key]
    if 'hello' in actual['tls']:
        checks['tls_stable_fields']=stable_tls(source['hello'])==stable_tls(actual['tls']['hello'])
        expected,emitted=extension_ids(source['hello']),extension_ids(actual['tls']['hello'])
        checks['tls_extensions']=sorted(expected)==sorted(emitted)
        if not source['permute_tls']:
            checks['tls_fixed_extension_order']=expected==emitted
    else:
        checks['tls_raw_evidence_present']=False
    checks['initial_streams']=streams(source['boundary'])==streams(requests[0]['first_request_boundary']['snapshot'])
    checks['warm_streams']=streams(source['warm_boundary'])==streams(requests[-1]['connection'])
    source_names=source['pseudo_order']+source['header_order']
    differences=[]
    for i,request in enumerate(requests[:3]):
        boundary=request.get('first_request_boundary', {})
        checks[f'qpack_phase_{i}_frozen_boundary']=(boundary.get('status')=='ready'
            and complete_boundary(boundary.get('snapshot', {})))
        checks[f'qpack_phase_{i}_connection_complete']=complete_boundary(request.get('connection', {}))
        evidence=request.get('request') or {}
        names=evidence.get('names')
        rows=evidence.get('fields')
        checks[f'qpack_phase_{i}_fields_complete']=evidence.get('fields_complete') is True
        checks[f'qpack_phase_{i}_stream_id']=evidence.get('stream_id')==i*4
        valid_names=(isinstance(names,list) and isinstance(rows,list)
            and all(isinstance(name,str) for name in names) and len(names)==len(rows)
            and all(names.count(pseudo)==1 for pseudo in source['pseudo_order']))
        checks[f'qpack_phase_{i}_named_evidence']=valid_names
        if not valid_names:
            continue
        expected=fields(source_names,source['wire_fields'][i])
        emitted=fields(names,request['request']['fields'])
        # 业务值与请求字段集合不同；对实际发出的共同字段逐项核对，不补造 Cookie/Origin/CSRF。
        missing=set(emitted)-set(expected)
        mismatch={name:{'source':expected[name],'actual':value} for name,value in emitted.items()
            if name in expected and value!=expected[name]}
        checks[f'qpack_phase_{i}_common_fields']=not mismatch and not missing
        differences.append({'phase':i,'differences':mismatch,'unmatched_fields':sorted(missing),
            'source_fields_not_requested':sorted(set(expected)-set(emitted))})
    result={'checks':checks,'all_checked_fields_match':all(checks.values()),'field_comparison':differences,
        'scope':'production HttpEgressClient versus fresh local browser samples',
        'not_verified':['physical device and production network','Cloudflare acceptance','exact QPACK bytes for identical business requests',
            'random Initial layout distribution','migration, loss and Retry under captured profile']}
    (folder/'comparison.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('folders',nargs='+',type=Path)
    args=parser.parse_args()
    passed=True
    for folder in args.folders:
        result=compare(folder)
        print(folder.name,json.dumps(result['checks']))
        passed &= result['all_checked_fields_match']
    raise SystemExit(0 if passed else 1)
