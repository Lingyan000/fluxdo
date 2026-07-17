import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/linux_do_dns_rewrite.dart';

void main() {
  group('LinuxDoDnsRewrite.matchesHost', () {
    test('匹配根域名和任意层级子域名', () {
      expect(LinuxDoDnsRewrite.matchesHost('linux.do'), isTrue);
      expect(LinuxDoDnsRewrite.matchesHost('CDN.LINUX.DO.'), isTrue);
      expect(LinuxDoDnsRewrite.matchesHost('a.b.linux.do'), isTrue);
    });

    test('不越过域名标签边界', () {
      expect(LinuxDoDnsRewrite.matchesHost('notlinux.do'), isFalse);
      expect(LinuxDoDnsRewrite.matchesHost('linux.do.example.com'), isFalse);
      expect(LinuxDoDnsRewrite.matchesHost('example.com'), isFalse);
    });
  });

  group('LinuxDoDnsRewrite.parseTarget', () {
    test('识别并规范化 A 记录', () {
      final target = LinuxDoDnsRewrite.parseTarget(' 1.1.1.1 ');
      expect(target?.type, LinuxDoDnsRewriteTargetType.a);
      expect(target?.value, '1.1.1.1');
    });

    test('识别并规范化 AAAA 记录', () {
      final target = LinuxDoDnsRewrite.parseTarget('2606:4700:4700::1111');
      expect(target?.type, LinuxDoDnsRewriteTargetType.aaaa);
      expect(target?.value, '2606:4700:4700::1111');
    });

    test('识别并规范化前置域名', () {
      final target = LinuxDoDnsRewrite.parseTarget(' Preferred.Example.COM. ');
      expect(target?.type, LinuxDoDnsRewriteTargetType.frontDomain);
      expect(target?.value, 'preferred.example.com');
      expect(target?.isFrontDomain, isTrue);
    });

    test('拒绝 URL、通配符和不完整域名', () {
      expect(LinuxDoDnsRewrite.parseTarget('https://example.com'), isNull);
      expect(LinuxDoDnsRewrite.parseTarget('*.example.com'), isNull);
      expect(LinuxDoDnsRewrite.parseTarget('localhost'), isNull);
      expect(LinuxDoDnsRewrite.parseTarget(''), isNull);
    });
  });

  group('LinuxDoDomainFronting', () {
    test('只替换传输 URL 的域名并保留路径与查询参数', () {
      final original = Uri.parse('https://connect.linux.do/t/123?foo=bar');
      final rewritten = LinuxDoDomainFronting.rewriteUri(
        original,
        'preferred.example.com',
      );

      expect(
        rewritten.toString(),
        'https://preferred.example.com/t/123?foo=bar',
      );
      expect(
        LinuxDoDomainFronting.originalHostHeader(original),
        'connect.linux.do',
      );
    });

    test('原始非默认端口会保留在 Host 中', () {
      final original = Uri.parse('https://linux.do:8443/challenge');
      expect(
        LinuxDoDomainFronting.originalHostHeader(original),
        'linux.do:8443',
      );
    });
  });
}
