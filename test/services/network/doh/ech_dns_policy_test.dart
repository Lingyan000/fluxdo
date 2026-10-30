import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/ech_dns_policy.dart';

void main() {
  test('论坛根域和子域查询公共 ECH 入口', () {
    for (final host in [
      'linux.do',
      'www.linux.do',
      'a.b.linux.do',
      'LINUX.DO.',
      'ldstatic.com',
      'cdn.ldstatic.com',
      'CDN.LDSTATIC.COM.',
    ]) {
      expect(
        const EchDnsPolicy().queryName(host),
        'cloudflare-ech.com',
        reason: host,
      );
    }
  });

  test('其他域名、相似域名和 IP 保持原样', () {
    for (final host in [
      '',
      'notlinux.do',
      'linux.do.example.com',
      'evil-ldstatic.com',
      'challenges.cloudflare.com',
      'cloudflare-ech.com',
      'example.com.',
      '127.0.0.1',
      '::1',
      '中文.example',
    ]) {
      expect(const EchDnsPolicy().queryName(host), host, reason: host);
    }
  });

  test('关闭公共入口后内置和自定义域名均按原名解析，规则仍保留', () {
    const policy = EchDnsPolicy(customDomains: ['example.com']);
    expect(policy.queryName('a.example.com'), EchDnsPolicy.cloudflareQueryName);
    final disabled = policy.copyWith(enabled: false);
    for (final host in ['linux.do', 'cdn.ldstatic.com', 'a.example.com']) {
      expect(disabled.queryName(host), host);
    }
    final restored = EchDnsPolicy.fromJson(disabled.toJson());
    expect(restored.enabled, false);
    expect(restored.customDomains, ['example.com']);
    expect(
      restored.copyWith(enabled: true).queryName('a.example.com'),
      EchDnsPolicy.cloudflareQueryName,
    );
  });

  test('域名输入规范化、去重并过滤非法或被内置规则覆盖的配置', () {
    final policy = EchDnsPolicy.fromJson({
      'enabled': true,
      'custom_domains': [
        ' Example.COM. ',
        'example.com',
        'cdn.linux.do',
        'https://bad.com',
        '127.0.0.1',
        '*.bad.com',
        'bad.com..',
      ],
    });
    expect(policy.customDomains, ['example.com']);
    expect(policy.queryName('notexample.com'), 'notexample.com');
    expect(policy.queryName('example.com.evil.net'), 'example.com.evil.net');
    expect(
      policy.queryName('A.EXAMPLE.COM.'),
      EchDnsPolicy.cloudflareQueryName,
    );
    for (final invalid in [
      '',
      'localhost',
      'a..com',
      '-a.com',
      'a-.com',
      'a.com:443',
      'a.com/path',
      '::1',
      'a.com?key=value',
      'user@a.com',
    ]) {
      expect(EchDnsPolicy.isValidDomain(invalid), false, reason: invalid);
    }
  });
}
