import 'dart:async';
import 'dart:io' as io;

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_clearance_authority.dart';
import 'package:fluxdo/services/network/cookie/boundary_sync_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

import '../../../support/cf_test_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CfTestPlatform();
  final jar = CookieJarService();
  final sync = BoundarySyncService.instance;

  late io.Directory cookieDirectory;
  setUpAll(() async {
    cookieDirectory = await io.Directory.systemTemp.createTemp(
      'cf-boundary-test-',
    );
    await platform.initialize(cookieDirectory: cookieDirectory.path);
  });
  setUp(platform.reset);
  tearDown(platform.reset);
  tearDownAll(() => cookieDirectory.delete(recursive: true));

  Future<void> seed(String value) =>
      jar.cookieJar.saveFromResponse(Uri.parse('https://linux.do'), [
        io.Cookie('cf_clearance', value)
          ..domain = '.linux.do'
          ..path = '/',
      ]);

  test('验证前快照包含 WebView 中并存的所有旧值', () async {
    platform.cookies.values = [cfTestCookie('old-a'), cfTestCookie('old-b')];

    expect(await sync.readCookieValuesFromWebView(name: 'cf_clearance'), {
      'old-a',
      'old-b',
    });
    expect(await jar.getCfClearance(), isNull);
  });

  test('trusted 普通同步仍不能替换健康值', () async {
    await seed('verified');
    platform.cookies.values = [cfTestCookie('residue')];

    await sync.syncFromWebView(cookieNames: {'cf_clearance'}, trusted: true);

    expect(await jar.getCfClearance(), 'verified');
  });

  test('验证确认值可替换抢先写入的副本，后续普通同步不能覆盖', () async {
    await seed('bootstrap-residue');
    platform.cookies.values = [cfTestCookie('residue'), cfTestCookie('fresh')];

    await sync.syncFromWebView(
      cookieNames: {'cf_clearance'},
      trusted: true,
      acceptValues: {'cf_clearance': 'fresh'},
    );
    expect(await jar.getCfClearance(), 'fresh');

    platform.cookies.values = [cfTestCookie('residue')];
    await sync.syncFromWebView(cookieNames: {'cf_clearance'}, trusted: true);
    expect(await jar.getCfClearance(), 'fresh');
  });

  test('在位判定与写入串行，较慢的旧同步不能覆盖新验证值', () async {
    final readStarted = Completer<void>();
    final oldRead = Completer<CanonicalCookie?>();
    var reads = 0;
    CfClearanceAuthority.instance.debugCookieReader = () {
      if (++reads == 1) {
        readStarted.complete();
        return oldRead.future;
      }
      return jar.getCanonicalCookie('cf_clearance');
    };

    platform.cookies.values = [cfTestCookie('slow-residue')];
    final ordinary = sync.syncFromWebView(
      cookieNames: {'cf_clearance'},
      trusted: true,
    );
    await readStarted.future;

    platform.cookies.values = [cfTestCookie('fresh')];
    final verified = sync.syncFromWebView(
      cookieNames: {'cf_clearance'},
      trusted: true,
      acceptValues: {'cf_clearance': 'fresh'},
    );
    await Future<void>.delayed(Duration.zero);
    final readsBeforeRelease = reads;
    oldRead.complete(null);
    await Future.wait([ordinary, verified]);

    expect(readsBeforeRelease, 1, reason: '后续同步必须等前一轮判定与写入完成');
    expect(await jar.getCfClearance(), 'fresh');
  });

  for (final viaCdp in [false, true]) {
    test(
      '${viaCdp ? 'CDP' : 'CookieManager'} 确认值淘汰 expires 更晚的旧分区副本',
      () async {
        final enhanced = jar.cookieJar as EnhancedPersistCookieJar;
        await enhanced.saveCanonicalCookies(Uri.parse('https://linux.do'), [
          CanonicalCookie(
            name: 'cf_clearance',
            value: 'long-lived-residue',
            domain: '.linux.do',
            hostOnly: false,
            expiresAt: DateTime.now().add(const Duration(days: 30)),
            partitionKey: 'old-partition',
            partitioned: true,
          ),
        ]);
        platform.cookies.values = [cfTestCookie('fresh')];
        if (viaCdp) platform.controller.partitionKey = 'new-partition';

        await sync.syncFromWebView(
          controller: viaCdp ? platform.controller.wrapped : null,
          cookieNames: {'cf_clearance'},
          trusted: true,
          acceptValues: {'cf_clearance': 'fresh'},
        );

        expect(await jar.getCfClearance(), 'fresh');
        final remaining = (await enhanced.readAllCookies()).where(
          (cookie) => cookie.name == 'cf_clearance',
        );
        expect(remaining.map((cookie) => cookie.value), ['fresh']);
      },
      skip: viaCdp && !io.Platform.isWindows,
    );
  }

  test('Windows CDP 快路径也保护已验证值', () async {
    await seed('verified');
    platform.cookies.values = [cfTestCookie('cdp-residue')];

    await sync.syncFromWebView(
      controller: platform.controller.wrapped,
      cookieNames: {'cf_clearance'},
      trusted: true,
    );

    expect(await jar.getCfClearance(), 'verified');
  }, skip: !io.Platform.isWindows);

  test('Windows CDP 只接受本轮确认值', () async {
    await seed('bootstrap-residue');
    platform.cookies.values = [cfTestCookie('residue'), cfTestCookie('fresh')];

    await sync.syncFromWebView(
      controller: platform.controller.wrapped,
      cookieNames: {'cf_clearance'},
      trusted: true,
      acceptValues: {'cf_clearance': 'fresh'},
    );

    expect(await jar.getCfClearance(), 'fresh');
  }, skip: !io.Platform.isWindows);
}
