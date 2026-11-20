"""用独立 OpenSSL 生成短期 OCSP 正反对照；仅在调用者临时目录写入测试私钥。"""
import datetime
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(sys.argv[1])


def openssl(*args):
    result = subprocess.run(['openssl', *map(str, args)], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f'openssl {args} failed: {result.stderr.decode()} {result.stdout.decode()}')
    return result.stdout


def tlv(tag, value):
    size = len(value)
    encoded = bytes([size]) if size < 128 else size.to_bytes((size.bit_length() + 7) // 8, 'big')
    if size >= 128:
        encoded = bytes([0x80 | len(encoded)]) + encoded
    return bytes([tag]) + encoded + value


def parts(data):
    result = []
    offset = 0
    while offset < len(data):
        start = offset
        tag, size = data[offset:offset + 2]
        offset += 2
        if size & 128:
            n = size & 127
            size = int.from_bytes(data[offset:offset + n], 'big')
            offset += n
        end = offset + size
        assert end <= len(data)
        result.append((tag, data[offset:end], data[start:end]))
        offset = end
    return result


def sequence(data):
    tag, value, _ = parts(data)[0]
    assert tag == 0x30
    return parts(value)


def children(items):
    return tlv(0x30, b''.join(item[2] for item in items))


def issue(name, serial, eku, key_usage='digitalSignature', days='30', ca='issuer', rsa=False, extra=''):
    openssl('req', '-new', '-newkey', 'rsa:2048' if rsa else 'ec',
            *([] if rsa else ['-pkeyopt', 'ec_paramgen_curve:prime256v1']),
            '-nodes', '-subj', f'/CN={name}', '-keyout', f'{name}.key', '-out', f'{name}.csr')
    (ROOT / f'{name}.ext').write_text(
        f'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,{key_usage}\n'
        f'extendedKeyUsage={eku}\nsubjectAltName=DNS:ocsp.example\n{extra}')
    openssl('x509', '-req', '-in', f'{name}.csr', '-CA', f'{ca}.pem', '-CAkey', f'{ca}.key',
            '-set_serial', serial, '-days', days, '-extfile', f'{name}.ext', '-out', f'{name}.pem')
    openssl('x509', '-in', f'{name}.pem', '-outform', 'DER', '-out', f'{name}.der')


def root(name, subject=None):
    openssl('req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
            '-nodes', '-subj', f'/CN={subject or name}', '-days', '365', '-keyout', f'{name}.key',
            '-out', f'{name}.pem', '-addext', 'basicConstraints=critical,CA:TRUE',
            '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
    openssl('x509', '-in', f'{name}.pem', '-outform', 'DER', '-out', f'{name}.der')


def response(name, signer='issuer', index='valid', cert='leaf', *extra):
    openssl('ocsp', '-index', f'{index}.index', '-rsigner', f'{signer}.pem',
            '-rkey', f'{signer}.key', '-CA', 'issuer.pem', '-issuer', 'issuer.pem',
            *(['-sha256'] if name == 'sha256_id' else []),
            '-cert', f'{cert}.pem', '-no_nonce', '-ndays', '1', '-rmd', 'sha256',
            '-respout', f'{name}.ocsp', *extra)


def rewrite(name, change, source='good', corrupt=False):
    outer = sequence((ROOT / f'{source}.ocsp').read_bytes())
    wrapped = sequence(parts(outer[1][1])[0][2])
    basic = sequence(wrapped[1][1])
    data = sequence(basic[0][2])
    change(data)
    tbs = children(data)
    (ROOT / 'tbs.bin').write_bytes(tbs)
    sig = openssl('dgst', '-sha256', '-sign', 'issuer.key', 'tbs.bin')
    if corrupt:
        sig = sig[:-1] + bytes([sig[-1] ^ 1])
    body = tlv(0x30, tbs + basic[1][2] + tlv(3, b'\0' + sig))
    wrapped = tlv(0x30, wrapped[0][2] + tlv(4, body))
    (ROOT / f'{name}.ocsp').write_bytes(tlv(0x30, outer[0][2] + tlv(0xa0, wrapped)))


def change_single(data, change):
    entries = sequence(data[2][2])
    single = sequence(entries[0][2])
    change(single)
    data[2] = parts(tlv(0x30, children(single)))[0]


root('issuer')
root('foreign', subject='issuer')
issue('leaf', '1', 'serverAuth')
issue('other', '2', 'serverAuth')
issue('delegate', '3', 'OCSPSigning')
issue('unauthorized', '4', 'clientAuth')
issue('expired', '5', 'OCSPSigning')
# 重新签署已过期的响应者证书，避免使用不同 OpenSSL 版本行为不一致的负 days 参数。
expired = sequence((ROOT / 'expired.der').read_bytes())
expired_tbs = sequence(expired[0][2])
now = datetime.datetime.now(datetime.timezone.utc)
validity = tlv(0x30, b''.join(tlv(0x17, (now - datetime.timedelta(days=d)).strftime('%y%m%d%H%M%SZ').encode()) for d in [2, 1]))
expired_tbs[4] = parts(validity)[0]
(ROOT / 'expired-tbs.bin').write_bytes(children(expired_tbs))
expired_signature = openssl('dgst', '-sha256', '-sign', 'issuer.key', 'expired-tbs.bin')
(ROOT / 'expired.der').write_bytes(tlv(0x30, children(expired_tbs) + expired[1][2] + tlv(3, b'\0' + expired_signature)))
openssl('x509', '-inform', 'DER', '-in', 'expired.der', '-out', 'expired.pem')
issue('foreign_delegate', '6', 'OCSPSigning', ca='foreign')
issue('bad_usage', '7', 'OCSPSigning', key_usage='keyEncipherment')
issue('rsa_delegate', '8', 'OCSPSigning', rsa=True)
expiry = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=30)).strftime('%y%m%d%H%M%SZ')
revoked = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).strftime('%y%m%d%H%M%SZ')
(ROOT / 'valid.index').write_text(f'V\t{expiry}\t\t01\tunknown\t/CN=leaf\nV\t{expiry}\t\t02\tunknown\t/CN=other\n')
(ROOT / 'revoked.index').write_text(f'R\t{expiry}\t{revoked}\t01\tunknown\t/CN=leaf\n')
(ROOT / 'unknown.index').write_text('')
for status in ['valid', 'revoked']:
    (ROOT / 'crl.cnf').write_text(
        '[ca]\ndefault_ca=issuer\n[issuer]\n'
        f'database={status}.index\ncertificate=issuer.pem\nprivate_key=issuer.key\n'
        'default_md=sha256\ndefault_crl_days=1\n')
    openssl('ca', '-gencrl', '-config', 'crl.cnf', '-out', f'{status}.crl.pem')
    openssl('crl', '-in', f'{status}.crl.pem', '-outform', 'DER', '-out', f'{status}.crl')
response('good', 'issuer', 'valid', 'leaf', '-resp_no_certs')
response('by_key', 'issuer', 'valid', 'leaf', '-resp_key_id', '-resp_no_certs')
response('sha256_id', 'issuer')
response('delegated', 'delegate')
response('missing_delegate', 'delegate', 'valid', 'leaf', '-resp_no_certs')
response('unauthorized', 'unauthorized')
response('expired_signer', 'expired')
response('foreign_signer', 'foreign_delegate')
response('bad_usage', 'bad_usage')
response('rsa', 'rsa_delegate')
response('rsa_pss', 'rsa_delegate', 'valid', 'leaf', '-rsigopt', 'rsa_padding_mode:pss', '-rsigopt', 'rsa_pss_saltlen:32')
response('revoked', 'issuer', 'revoked')
response('unknown', 'issuer', 'unknown')
response('wrong_serial', 'issuer', 'valid', 'other')
rewrite('bad_signature', lambda data: None, corrupt=True)
rewrite('missing_next_update', lambda data: change_single(data, lambda single: single.pop(3)))

# 未知扩展，OID 1.2.3.4；非关键扩展应允许，关键扩展必须拒绝。
for critical in [False, True]:
    ext = tlv(0x30, tlv(6, b'\x2a\x03\x04') + (b'\x01\x01\xff' if critical else b'') + tlv(4, b'\x05\x00'))
    field = parts(tlv(0xa1, tlv(0x30, ext)))[0]
    rewrite('critical_extension' if critical else 'noncritical_extension', lambda data: data.append(field))
    if critical:
        rewrite('critical_single', lambda data: change_single(data, lambda single: single.append(field)))

def wrong_hash(single, index):
    cert_id = sequence(single[0][2])
    old = cert_id[index]
    cert_id[index] = parts(tlv(4, bytes([old[1][0] ^ 1]) + old[1][1:]))[0]
    single[0] = parts(children(cert_id))[0]

rewrite('wrong_name_hash', lambda data: change_single(data, lambda single: wrong_hash(single, 1)))
rewrite('wrong_key_hash', lambda data: change_single(data, lambda single: wrong_hash(single, 2)))
rewrite('wrong_responder', lambda data: data.__setitem__(0, parts(tlv(0xa2, tlv(4, bytes(20))))[0]))

# 签名算法参数必须被实际执行，不能只读取 PSS 的主摘要算法。
mgf_sha384 = tlv(0x30, bytes.fromhex('06092a864886f70d010108') +
                tlv(0x30, bytes.fromhex('06096086480165030402020500')))
for field, value, name in [(0xa2, tlv(2, b'\x21'), 'pss_wrong_salt'),
                           (0xa3, tlv(2, b'\x02'), 'pss_wrong_trailer'),
                           (0xa1, mgf_sha384, 'pss_wrong_mgf')]:
    outer = sequence((ROOT / 'rsa_pss.ocsp').read_bytes())
    wrapped = sequence(parts(outer[1][1])[0][2])
    basic = sequence(wrapped[1][1])
    alg = sequence(basic[1][2])
    params = [p for p in sequence(alg[1][2]) if p[0] != field]
    params.append(parts(tlv(field, value))[0])
    params.sort(key=lambda p: p[0])
    alg[1] = parts(children(params))[0]
    basic[1] = parts(children(alg))[0]
    wrapped[1] = parts(tlv(4, children(basic)))[0]
    outer[1] = parts(tlv(0xa0, children(wrapped)))[0]
    (ROOT / f'{name}.ocsp').write_bytes(children(outer))

def multi(data):
    good = sequence(data[2][2])[0][2]
    # 同一证书有 good 与 unknown 时，不能挑选 good 放行。
    single = sequence(good)
    single[1] = parts(b'\x82\x00')[0]
    data[2] = parts(tlv(0x30, good + children(single)))[0]

rewrite('conflicting_status', multi)
(ROOT / 'response_error.ocsp').write_bytes(bytes.fromhex('30030a0103'))
(ROOT / 'trailing_data.ocsp').write_bytes((ROOT / 'good.ocsp').read_bytes() + b'\0')
(ROOT / 'truncated.ocsp').write_bytes((ROOT / 'good.ocsp').read_bytes()[:-1])
(ROOT / 'now.json').write_text(json.dumps(int(time.time())))

# 独立实现正向验收；禁止使用 noverify/no_signature_verify 等豁免。
for name in ['good', 'by_key', 'sha256_id', 'delegated', 'rsa', 'rsa_pss']:
    openssl('ocsp', '-respin', f'{name}.ocsp', '-issuer', 'issuer.pem',
            *(['-sha256'] if name == 'sha256_id' else []), '-cert', 'leaf.pem',
            '-CAfile', 'issuer.pem', '-verify_other', 'issuer.pem', '-no_nonce')
