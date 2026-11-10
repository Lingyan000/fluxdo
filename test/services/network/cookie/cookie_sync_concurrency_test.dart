import 'dart:async';

import '../../../support/cookie_sync_fakes.dart';

import 'dart:io' as io;

import 'package:cookie_jar/cookie_jar.dart';

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/network/cookie/cookie_full_info.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_store_observer.dart';
import 'package:fluxdo/services/network/cookie/raw_cookie_writer.dart';
import 'package:fluxdo/services/network/cookie/session_cookie_sentinel.dart';
import 'package:fluxdo/services/network/cookie/webview_cookie_priming.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryJar jar;
  late MemoryWriter writer;
  final sentinel = SessionCookieSentinel.instance;
  final priming = WebViewCookiePriming.instance;

  setUp(() {
    jar = MemoryJar();
    writer = MemoryWriter();
    sentinel.resetForTest();
    priming.resetForTest();
    sentinel.replaceDependenciesForTest(
      jar: jar,
      writer: writer,
      auth: AuthSession(),
    );
    priming.replaceDependenciesForTest(
      jar: jar,
      writer: writer,
      sentinel: sentinel,
    );
  });
  tearDown(() async {
    await sentinel.drain();
    CookieStoreObserver.instance.resetForTest();
    priming.resetForTest();
    sentinel.resetForTest();
    sentinel.replaceDependenciesForTest(
      jar: CookieJarService(),
      writer: RawCookieWriter.instance,
    );
    priming.replaceDependenciesForTest(
      jar: CookieJarService(),
      writer: RawCookieWriter.instance,
    );
  });

  test('内存 jar 降级后仍可枚举完整域名和路径', () async {
    final memory = DefaultCookieJar();
    await memory.saveFromResponse(Uri.parse('$origin/apps/one'), [
      io.Cookie('theme', 'root')..path = '/',
      io.Cookie('theme', 'scoped')..path = '/apps',
      io.Cookie('shared', 'domain')
        ..path = '/'
        ..domain = '.linux.do',
    ]);
    final all = CookieJarService.canonicalCookiesFromMemoryJar(memory);
    expect(
      all.map((cookie) => (cookie.name, cookie.path, cookie.hostOnly)),
      unorderedEquals([
        ('theme', '/', true),
        ('theme', '/apps', true),
        ('shared', '/', false),
      ]),
    );
    expect(
      all.every((cookie) => cookie.normalizedDomain == 'linux.do'),
      isTrue,
    );
  });

  test('旧清理等待期间收到新 canonical，最终写回新值', () async {
    writer.cookies = [info(token('old')), info(token('older'))];
    final release = writer.holdDelete = Completer<void>();
    final cleaning = sentinel.sweep(origin, '_t', force: true);
    await writer.deleteStarted.future;
    jar.cookies = [token('new', version: 2)];
    await writer.setRawCookie(origin, jar.cookies.single.toSetCookieHeader());
    release.complete();
    await cleaning;
    final again = await sentinel.sweep(origin, '_t', force: true);
    expect(writer.cookies.single.value, 'new');
    expect(again.status, SweepStatus.noop);
  });

  test('旧删除任务等待计数时切换会话，保留新登录 Cookie', () async {
    writer.cookies = [info(token('old'))];
    final release = writer.holdCount = Completer<void>();
    final deleting = sentinel.sweep(
      origin,
      '_t',
      intent: SweepIntent.delete,
      force: true,
    );
    await writer.countStarted.future;
    AuthSession().advance();
    jar.cookies = [token('new-login')];
    writer.cookies = [info(jar.cookies.single)];
    release.complete();
    expect((await deleting).status, SweepStatus.cancelled);
    expect(writer.deletes, 0);
    expect(writer.cookies.single.value, 'new-login');
  });

  test('批量检查等待读取时切换会话，不再启动旧检查的后续任务', () async {
    writer.cookies = [info(token('old'))];
    final release = writer.holdRead = Completer<void>();
    final checking = sentinel.sweepAll(origin);
    await writer.readStarted.future;
    AuthSession().advance();
    jar.cookies = [token('new-login')];
    writer.cookies = [info(jar.cookies.single)];
    release.complete();
    expect(await checking, isEmpty);
    expect(writer.writes, 0);
    expect(writer.cookies.single.value, 'new-login');
  });

  test('取消标记在原生调用迟到返回时仍有效', () async {
    writer.cookies = [info(token('old'))];
    final release = writer.holdCount = Completer<void>();
    final deleting = sentinel.sweep(
      origin,
      '_t',
      intent: SweepIntent.delete,
      force: true,
    );
    await writer.countStarted.future;
    await sentinel.cancelAllSweeps();
    release.complete();
    expect((await deleting).status, SweepStatus.cancelled);
    expect(writer.deletes, 0);
  });

  test('删除已经发出后换会话，新写入排在旧操作完成之后', () async {
    writer.cookies = [
      CookieFullInfo(name: '_t', value: 'old', domain: '.linux.do', path: '/'),
    ];
    jar.cookies = [token('rotated')];
    final release = writer.holdDelete = Completer<void>();
    final old = sentinel.syncFromJar(origin, '_t');
    await writer.deleteStarted.future;
    AuthSession().advance();
    jar.cookies = [token('new-login')];
    final current = sentinel.syncFromJar(origin, '_t');
    release.complete();
    expect((await old).status, SweepStatus.cancelled);
    expect((await current).status, SweepStatus.swept);
    expect(writer.cookies.single.value, 'new-login');
  });

  test('原生写入等待期间再次轮换，结束时对齐最新版本', () async {
    final release = writer.holdWrite = Completer<void>();
    final syncing = sentinel.syncFromJar(origin, '_t');
    await writer.writeStarted.future;
    jar.cookies = [token('new', version: 2)];
    release.complete();
    expect((await syncing).status, SweepStatus.swept);
    expect(writer.cookies.single.value, 'new');
  });

  test('缺失和单个旧认证 Cookie 都会被修复', () async {
    await sentinel.syncFromJar(origin, '_t');
    expect(writer.cookies.single.value, 'old');
    jar.cookies = [token('new', version: 2)];
    await sentinel.syncFromJar(origin, '_t');
    expect(writer.cookies.single.value, 'new');
  });

  test('原生删除失败只报告该项失败，避免重新灌入认证 Cookie', () async {
    writer.cookies = [info(token('old'))];
    writer.acceptDeletes = false;
    final result = await sentinel.sweep(
      origin,
      '_t',
      intent: SweepIntent.delete,
      force: true,
    );
    expect(result.status, SweepStatus.failed);
    expect(writer.writes, 0);
    expect(writer.deletes, 2);
  });

  test('相同作用域正常轮换直接覆盖，省去删除操作', () async {
    writer.cookies = [info(token('old'))];
    jar.cookies = [token('new', version: 2)];
    await sentinel.syncFromJar(origin, '_t');
    expect(writer.cookies.single.value, 'new');
    expect(writer.deletes, 0);
    expect(writer.writes, 1);
  });

  test('同名不同路径的后台变更全部处理', () async {
    jar.cookies = [token('root', name: 'theme')];
    writer.cookies = [
      info(jar.cookies.single),
      info(token('stale', name: 'theme', path: '/apps')),
    ];
    sentinel.scheduleSyncFromJar('$origin/apps', ['theme']);
    sentinel.scheduleSyncFromJar(origin, ['theme']);
    await sentinel.drain();
    expect(writer.cookies.map((cookie) => cookie.path), ['/']);
  });

  test('同名不同 path 的 canonical 在清理后全部保留', () async {
    jar.cookies = [
      token('root', name: 'theme'),
      token('scoped', name: 'theme', path: '/apps'),
    ];
    writer.cookies = [
      info(token('stale', name: 'theme')),
      info(jar.cookies.last),
    ];
    await sentinel.syncFromJar('$origin/apps/one', 'theme');
    await sentinel.sweep('$origin/apps/one', 'theme', force: true);
    expect(
      writer.cookies.map((cookie) => (cookie.path, cookie.value)),
      unorderedEquals([('/', 'root'), ('/apps', 'scoped')]),
    );
  });

  test('后台连续更新共享任务并只保留最新待写值', () async {
    for (var i = 0; i < 30; i++) {
      jar.cookies = [token('token-$i', version: i + 1)];
      sentinel.scheduleSyncFromJar(origin, ['_t']);
    }
    await sentinel.drain();
    expect(writer.cookies.single.value, 'token-29');
    expect(writer.writes, 1);
  });

  test('后台写入在途时收到后续更新，完成后仍落最新值', () async {
    final release = writer.holdWrite = Completer<void>();
    sentinel.scheduleSyncFromJar(origin, ['_t']);
    await writer.writeStarted.future;
    jar.cookies = [token('latest', version: 2)];
    sentinel.scheduleSyncFromJar(origin, ['_t']);
    release.complete();
    await sentinel.drain();
    expect(writer.cookies.single.value, 'latest');
  });

  test('已经就绪后 Cookie 丢失，下次使用仍会检查并修复', () async {
    await priming.prime(origin);
    expect(priming.isPrimed, isTrue);
    writer.cookies.clear();
    await priming.prime(origin);
    expect(writer.cookies.single.value, 'old');
    expect(priming.isPrimed, isTrue);
  });

  test('原生写入失败不能把预热标记成就绪', () async {
    writer.acceptWrites = false;
    await expectLater(
      priming.prime(origin),
      throwsA(isA<WebViewPrimingException>()),
    );
    expect(priming.isPrimed, isFalse);
  });

  test('同站点不同页面共用在途预热，避免并发清理', () async {
    final release = writer.holdRead = Completer<void>();
    final first = priming.prime(origin);
    await writer.readStarted.future;
    final second = priming.prime('$origin/apps/one');
    await Future<void>.delayed(Duration.zero);
    expect(writer.reads, 1);
    release.complete();
    await Future.wait([first, second]);
    expect(writer.writes, 1);
    expect(writer.maxActiveReads, 1);
    expect(priming.isPrimed, isTrue);
  });

  test('已匹配的 Cookie 只核对，保留现存浏览器 Cookie', () async {
    writer.cookies = [info(jar.cookies.single)];
    await priming.prime(origin);
    expect(writer.writes, 0);
    expect(writer.deletes, 0);
    expect(priming.isPrimed, isTrue);
  });

  test('浏览器自身轮换的单个认证 Cookie 等待反向同步', () async {
    writer.cookies = [info(token('browser-rotated'))];
    final result = await sentinel.sweep(origin, '_t', force: true);
    expect(result.status, SweepStatus.noop);
    expect(writer.cookies.single.value, 'browser-rotated');
    expect(writer.writes, 0);
  });

  test('就绪校验检查已知的 SameSite 和分区属性', () {
    final expected = token('value').copyWith(sameSite: CookieSameSite.none);
    expect(
      SessionCookieSentinel.matchesCanonical(
        CookieFullInfo(name: '_t', value: 'value', sameSite: 'Lax'),
        expected,
      ),
      isFalse,
    );
    expect(
      SessionCookieSentinel.matchesCanonical(
        CookieFullInfo(name: '_t', value: 'value', sameSite: 'None'),
        expected,
      ),
      isTrue,
    );
    expect(
      SessionCookieSentinel.matchesCanonical(
        CookieFullInfo(name: '_t', value: 'value', isPartitioned: true),
        expected,
      ),
      isFalse,
    );
  });

  test('客户端尚无认证 Cookie 时保留浏览器自行取得的值', () async {
    jar.cookies = [];
    writer.cookies = [info(token('browser-login'))];
    await sentinel.sweep(origin, '_t', force: true);
    await priming.prime(origin);
    expect(writer.cookies.single.value, 'browser-login');
    expect(writer.deletes, 0);
  });

  test('取消并排水时保持已经发出的原生写操作有序', () async {
    final release = writer.holdWrite = Completer<void>();
    sentinel.scheduleSyncFromJar(origin, ['_t']);
    await writer.writeStarted.future;
    await sentinel.cancelAllSweeps();
    var drained = false;
    final drain = sentinel.drain().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    release.complete();
    await drain;
    expect(drained, isTrue);
  });
}
