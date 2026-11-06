import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/client_hints.dart';

void main() {
  group('ClientHints.brandList', () {
    test('与正式版 Chrome 156 实测一致', () {
      expect(
        ClientHints.brandList(156, 'Google Chrome'),
        '"Not:A-Brand";v="8", "Chromium";v="156", "Google Chrome";v="156"',
      );
    });

    test('与安卓 WebView 133 实测一致（品牌排在 Chromium 之前）', () {
      expect(
        ClientHints.brandList(133, 'Android WebView'),
        '"Not(A:Brand";v="99", "Android WebView";v="133", "Chromium";v="133"',
      );
    });
  });

  group('ClientHints.fromUserAgent', () {
    test('安卓清理后的 UA 推导出 Chrome 低熵三件套', () {
      const ua =
          'Mozilla/5.0 (Linux; Android 16; Pixel 7 Build/BP2A.250605.031) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 '
          'Mobile Safari/537.36';
      expect(ClientHints.fromUserAgent(ua), {
        'sec-ch-ua':
            '"Not:A-Brand";v="8", "Chromium";v="156", "Google Chrome";v="156"',
        'sec-ch-ua-mobile': '?1',
        'sec-ch-ua-platform': '"Android"',
      });
    });

    test('桌面 Chrome UA 为非移动端', () {
      const ua =
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36';
      final hints = ClientHints.fromUserAgent(ua)!;
      expect(hints['sec-ch-ua-mobile'], '?0');
      expect(hints['sec-ch-ua-platform'], '"macOS"');
    });

    test('Edge UA 使用 Microsoft Edge 品牌', () {
      const ua =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0';
      expect(
        ClientHints.fromUserAgent(ua)!['sec-ch-ua'],
        '"Not_A Brand";v="8", "Chromium";v="120", "Microsoft Edge";v="120"',
      );
    });

    test('Safari / WebKit UA 不发送 Client Hints', () {
      const ua =
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 '
          'Mobile/15E148 Safari/604.1';
      expect(ClientHints.fromUserAgent(ua), isNull);
    });

    test('只发送低熵头，不主动发送高熵头', () {
      const ua =
          'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
      expect(ClientHints.fromUserAgent(ua)!.keys, [
        'sec-ch-ua',
        'sec-ch-ua-mobile',
        'sec-ch-ua-platform',
      ]);
    });
  });
}
