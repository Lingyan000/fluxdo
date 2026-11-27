import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/cookie_full_info.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/cookie/raw_cookie_writer.dart';

import '../../../support/cf_test_platform.dart';

class _RecordingRawCookieWriter implements RawCookieWriter {
  _RecordingRawCookieWriter({this.supported = true, this.shouldThrow = false});

  final bool supported;
  final bool shouldThrow;
  final calls =
      <
        ({
          String url,
          String name,
          List<String?> domainCandidates,
          List<String> pathCandidates,
        })
      >[];

  @override
  bool get isSupported => supported;

  @override
  void invalidateReads() {}

  @override
  Future<int> nukeAllVariants({
    required String url,
    required String name,
    required List<String?> domainCandidates,
    required List<String> pathCandidates,
  }) async {
    calls.add((
      url: url,
      name: name,
      domainCandidates: List.of(domainCandidates),
      pathCandidates: List.of(pathCandidates),
    ));
    if (shouldThrow) {
      throw StateError('nuke failed');
    }
    return 1;
  }

  @override
  Future<List<CookieFullInfo>> getAllCookieInfos(String url) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CfTestPlatform();
  final jar = CookieJarService();

  setUpAll(platform.initialize);
  setUp(() async {
    await platform.reset();
    jar.setRawCookieWriterForTesting(null);
  });
  tearDown(() async {
    jar.setRawCookieWriterForTesting(null);
    await platform.reset();
  });

  test('deleteWebViewCookie 优先走 RawCookieWriter.nukeAllVariants', () async {
    final writer = _RecordingRawCookieWriter();
    jar.setRawCookieWriterForTesting(writer);
    platform.cookies.values = [cfTestCookie('stale-clearance')];

    await jar.deleteWebViewCookie('cf_clearance');

    expect(writer.calls, hasLength(1));
    final call = writer.calls.single;
    expect(call.url, 'https://linux.do');
    expect(call.name, 'cf_clearance');
    expect(call.domainCandidates, containsAll([null, 'linux.do', '.linux.do']));
    expect(call.pathCandidates, ['/']);
    // 走了原生 nukeAllVariants 后不应再额外调用插件 deleteCookie
    expect(platform.cookies.values, hasLength(1));
  });

  test('deleteWebViewCookie 在 nukeAllVariants 抛错时回退插件 deleteCookie', () async {
    final writer = _RecordingRawCookieWriter(shouldThrow: true);
    jar.setRawCookieWriterForTesting(writer);
    platform.cookies.values = [cfTestCookie('stale-clearance')];

    await jar.deleteWebViewCookie('cf_clearance');

    expect(writer.calls, hasLength(1));
    expect(platform.cookies.values, isEmpty);
  });

  test('deleteWebViewCookie 在 RawCookieWriter 不支持时回退插件 deleteCookie', () async {
    final writer = _RecordingRawCookieWriter(supported: false);
    jar.setRawCookieWriterForTesting(writer);
    platform.cookies.values = [cfTestCookie('stale-clearance')];

    await jar.deleteWebViewCookie('cf_clearance');

    expect(writer.calls, isEmpty);
    expect(platform.cookies.values, isEmpty);
  });
}
