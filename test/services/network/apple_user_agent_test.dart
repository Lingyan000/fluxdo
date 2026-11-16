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
  test('未知产品版本不会从冻结 UA 或 WebKit token 补成已确认', () {
    final identity = appleBrowserIdentityDiagnostics(
      userAgent: completeIosUserAgent(frozen), readStatus: 'metadata_unavailable',
    );
    expect(identity['safari_product_version'], isNull);
    expect(identity['safari_version_verified'], false);
    expect(identity['safari_version_source'], 'unknown');
    expect(identity['ua_declared_version'], '18.7');
    expect(identity['ua_version_verified'], false);
    expect(identity['ua_webkit_token'], '605.1.15');
  });
  test('实际版本与 UA 声明不同时保留差异，不误报一致', () {
    final identity = appleBrowserIdentityDiagnostics(
      userAgent: completeIosUserAgent(frozen), safariProductVersion: '26.2',
      readStatus: 'read',
    );
    expect(identity['safari_product_version'], '26.2');
    expect(identity['safari_version_verified'], true);
    expect(identity['ua_version_verified'], false);
  });
  test('合法 Bundle 产品版本匹配当前 UA 才确认一致', () {
    final identity = appleBrowserIdentityDiagnostics(
      userAgent: completeIosUserAgent(frozen, safariProductVersion: '26.0.1'),
      safariProductVersion: '26.0.1', readStatus: 'read',
    );
    expect(identity['safari_version_source'], 'safari_bundle');
    expect(identity['ua_version_verified'], true);
  });
  test('无效元数据与缺失 UA 均保留为未知', () {
    final identity = appleBrowserIdentityDiagnostics(
      userAgent: '', safariProductVersion: '26.2 extra', readStatus: 'metadata_invalid',
    );
    expect(identity['safari_product_version'], isNull);
    expect(identity['ua_declared_version'], isNull);
    expect(identity['ua_version_verified'], false);
  });
}
