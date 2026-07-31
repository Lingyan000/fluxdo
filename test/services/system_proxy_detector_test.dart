import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/system_proxy_detector.dart';

void main() {
  group('SystemProxyDetector.parseProxyServer', () {
    test('host:port 形式默认 http', () {
      expect(
        SystemProxyDetector.parseProxyServer('127.0.0.1:7890'),
        'http://127.0.0.1:7890',
      );
    });

    test('带 scheme 的值归一化', () {
      expect(
        SystemProxyDetector.parseProxyServer('http://127.0.0.1:7890'),
        'http://127.0.0.1:7890',
      );
      expect(
        SystemProxyDetector.parseProxyServer('socks5://127.0.0.1:7891'),
        'socks5://127.0.0.1:7891',
      );
    });

    test('分协议列表优先 https,其次 http,最后 socks', () {
      expect(
        SystemProxyDetector.parseProxyServer(
          'http=1.2.3.4:80;https=1.2.3.4:443;socks=1.2.3.4:1080',
        ),
        'http://1.2.3.4:443',
      );
      expect(
        SystemProxyDetector.parseProxyServer('http=1.2.3.4:80;socks=1.2.3.4:1080'),
        'http://1.2.3.4:80',
      );
      expect(
        SystemProxyDetector.parseProxyServer('socks=1.2.3.4:1080'),
        'socks5://1.2.3.4:1080',
      );
    });

    test('非法输入返回 null', () {
      expect(SystemProxyDetector.parseProxyServer(''), isNull);
      expect(SystemProxyDetector.parseProxyServer('nonsense'), isNull);
      expect(SystemProxyDetector.parseProxyServer('ftp=1.2.3.4:21'), isNull);
      expect(SystemProxyDetector.parseProxyServer('host-without-port'), isNull);
    });
  });

  group('SystemProxyConfig', () {
    test('isEnabled 判定', () {
      expect(const SystemProxyConfig().isEnabled, isFalse);
      expect(
        const SystemProxyConfig(proxyUrl: 'http://127.0.0.1:7890').isEnabled,
        isTrue,
      );
      expect(
        const SystemProxyConfig(pacUrl: 'http://pac.local/p.pac').isEnabled,
        isTrue,
      );
    });
  });
}
