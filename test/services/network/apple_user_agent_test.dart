import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/apple_user_agent.dart';

void main() {
  const frozen = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';
  test('Safari 实际版本优先于冻结 UA，保留系统段和移动端标记', () {
    final ua = completeIosUserAgent(frozen, safariProductVersion: '26.2');
    expect(ua, '$frozen Safari/604.1'.replaceFirst(
      'Mobile/', 'Version/26.2 Mobile/'));
    expect(ua, contains('OS 18_7'));
  });
  test('真实 Safari 的产品补丁号不能丢弃，拒绝无效版本', () {
    // 系统 Safari 原始 UA：云端 run 43690750306，iOS 26.0.1。
    expect(iosSafariUserAgentVersion('26.0.1'), '26.0.1');
    expect(completeIosUserAgent(frozen, safariProductVersion: '26.0.1'),
        '$frozen Safari/604.1'.replaceFirst('Mobile/', 'Version/26.0.1 Mobile/'));
    expect(iosSafariUserAgentVersion('100.1'), '100.1');
    expect(iosSafariUserAgentVersion(''), isNull);
    expect(iosSafariUserAgentVersion('26.2 extra'), isNull);
  });
  test('已有 Safari UA 原样保留，不重复增加 Version', () {
    const ua = '$frozen Version/26.2 Safari/604.1';
    expect(completeIosUserAgent(ua, safariProductVersion: '26.1'), ua);
    expect(completeIosUserAgent('$frozen Version/26.2'),
        '$frozen Version/26.2 Safari/604.1');
  });
  test('Safari 不可读时保留已有兼容回退，旧系统同样使用产品版本', () {
    expect(completeIosUserAgent(frozen), contains('Version/18.7'));
    expect(completeIosUserAgent(frozen, safariProductVersion: '15.5'),
        contains('Version/15.5'));
  });
}
