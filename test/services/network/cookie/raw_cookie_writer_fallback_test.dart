import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/raw_cookie_writer_fallback.dart';

void main() {
  group('RawCookieWriterFallback.resolveCookieDomain', () {
    test('host-only Cookie 不传 domain', () {
      final cookie = SetCookieParser.parse(
        '_t=session; Path=/; Secure; HttpOnly',
        uri: Uri.parse('https://linux.do'),
      );

      expect(
        RawCookieWriterFallback.resolveCookieDomain(
          hostOnly: cookie.hostOnly,
          domain: cookie.domain,
        ),
        isNull,
      );
    });

    test('仅为显式 Domain Cookie 补前导点', () {
      final cookie = SetCookieParser.parse(
        'shared=value; Domain=linux.do; Path=/',
        uri: Uri.parse('https://linux.do'),
      );

      expect(
        RawCookieWriterFallback.resolveCookieDomain(
          hostOnly: cookie.hostOnly,
          domain: cookie.domain,
        ),
        '.linux.do',
      );
      expect(
        RawCookieWriterFallback.resolveCookieDomain(
          hostOnly: false,
          domain: '.linux.do',
        ),
        '.linux.do',
      );
    });
  });
}
