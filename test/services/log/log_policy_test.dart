import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_policy.dart';

void main() {
  test('用户接口、头像路径与历史消息脱敏，保留接口形状', () {
    final source = {
      'sessionId': 'old',
      'username': 'private-person',
      'url': 'https://linux.do/u/private-person/summary.json?key=secret',
      'message': 'GET /u/private-person.json',
      'nested': {
        'avatar': 'https://cdn.example/user_avatar/linux.do/private-person/48/1.png',
        'encoded': '/u/private%2Dperson.json',
        'unicode': '/u/私人名字/activity.json',
      },
    };
    final normalized = LogPolicy.normalize(source);
    expect(normalized['url'], 'https://linux.do/u/[user]/summary.json');
    expect(normalized['message'], 'GET /u/[user].json');
    final content = '${jsonEncode(source)}\n${jsonEncode(normalized)}';
    for (final fullHistory in [true, false]) {
      final exported = LogPolicy.export(content, fullHistory: fullHistory);
      for (final secret in ['private-person', 'private%2Dperson', '私人名字', 'key=secret']) {
        expect(exported, isNot(contains(secret)));
      }
      expect(exported, contains('/u/[user]/summary.json'));
      expect(exported, contains('/user_avatar/linux.do/[user]/48/1.png'));
    }
    expect(LogPolicy.cleanText('POST /uploads/complete-multipart.json'),
        'POST /uploads/complete-multipart.json');
  });

  test('历史 Core 请求路径和非法 DoH 输入不会在导出时暴露密钥', () {
    for (final message in [
      '[Core/fluxdo_net::client] Request GET /private-key?dns=encoded',
      'Request GET https://resolver.example/private-key?dns=encoded',
      "Invalid DOH URL 'https://resolver.example/private-key': invalid character",
      "Unsupported DOH URL scheme 'http': http://resolver.example/private-key",
      'Missing URL scheme: resolver.example/private-key',
    ]) {
      final row = jsonEncode({'message': message, 'sessionId': 'old'});
      final exported = LogPolicy.export(row);
      expect(exported, isNot(contains('private-key')));
      expect(exported, isNot(contains('encoded')));
      expect(exported, contains('[redacted]'));
    }
  });

  test('导出头与历史正文共同脱敏，保留排查证书需要的目标信息', () {
    final old = {
      'sessionId': 'old',
      'computerName': 'Alice-PC',
      'proxyHost': 'private-proxy.example:7890',
      'dohServer': 'https://resolver.example/account-path-secret?key=query-secret',
      'fields': {'doh_server_ech': 'https://user:pass@resolver.example/secret'},
      'message': 'DoH https://resolver.example/path-secret，'
          '应用代理 socks5://private-proxy.example:7890，'
          '系统代理 [fd00::1234]:8080; via proxy private-proxy.example:7890; '
          'SOCKS5 proxy socks5h://private-proxy.example:7890; '
          'Shadowsocks proxy ss://fd00::1234:8080',
      'peerAddr': '203.0.113.1:443',
      'addressFamily': 'ipv4',
      'echRequested': true,
      'error': 'platform verifier: certificate issuer is not trusted',
    };
    final current = LogPolicy.normalize({...old, 'message': 'current'});
    final content = '${jsonEncode(old)}\n${jsonEncode(current)}';
    for (final fullHistory in [true, false]) {
      final exported = LogPolicy.export(content, fullHistory: fullHistory, headers: [
        {...old, '_header': 'device_info', 'proxyEnabled': true},
      ]);
      for (final private in [
        'Alice-PC', 'private-proxy.example', 'fd00::1234',
        'resolver.example', 'path-secret', 'query-secret', 'user:pass',
      ]) {
        expect(exported, isNot(contains(private)), reason: private);
      }
      expect(exported, contains('203.0.113.1:443'));
      expect(exported, contains('"echRequested":true'));
      expect(exported, contains('certificate issuer is not trusted'));
      expect(exported, contains('"proxyEnabled":true'));
    }
  });

  test('敏感字段和 URL 参数统一移除，诊断字段保留', () {
    final row = LogPolicy.normalize({
      'url': 'https://user:password@example.com:8443/image?token=hidden#secret',
      'headers': {'Authorization': 'secret', 'Cookie': 'private'},
      'message': 'failed https://example.com/a?token=private',
      'coreRequestId': 42,
      'statusCode': 403,
    });
    expect(jsonEncode(row), isNot(contains('private')));
    expect(row['url'], 'https://example.com:8443/image');
    expect(row['coreRequestId'], 42);
    expect(row['statusCode'], 403);
    expect(row['schemaVersion'], 2);
  });
  test('导出默认包含保留历史，也可显式选择当前启动，非法行计数', () {
    final current = LogPolicy.normalize({
      'message': 'current',
      'level': 'warning',
    });
    final previous = {
      ...current,
      'sessionId': 'old',
      'message': 'previous',
      'cookie': 'historical-secret',
    };
    final content = '${jsonEncode(previous)}\n${jsonEncode(current)}\nnot-json';
    final full = LogPolicy.export(content);
    expect(full, contains('previous'));
    expect(full, contains('"scope":"retained_history"'));
    expect(full, isNot(contains('historical-secret')));
    final scoped = LogPolicy.export(content, fullHistory: false);
    expect(scoped, contains('current'));
    expect(scoped, isNot(contains('previous')));
    expect(scoped, contains('"invalidLines":1'));
    expect(LogPolicy.export(content, fullHistory: true), contains('previous'));
  });
  test('超大字段有上限且保留关联标识', () {
    final row = LogPolicy.normalize({
      'traceId': 'trace',
      'message': 'x' * 100000,
      'fields': List.filled(64, 'y' * 10000),
    });
    expect(utf8.encode(jsonEncode(row)).length, lessThan(16384));
    expect(row['traceId'], 'trace');
    expect(row['truncated'], true);
  });
}
