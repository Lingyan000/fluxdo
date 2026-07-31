import 'dart:io';

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:test/test.dart';

void main() {
  group('EnhancedPersistCookieJar', () {
    late Directory tempDir;
    late EnhancedPersistCookieJar jar;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'enhanced_cookie_jar_test_',
      );
      jar = EnhancedPersistCookieJar(
        store: FileCookieStore(tempDir.path),
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('domain cookie matches subdomain requests', () async {
      await jar.saveFromSetCookieHeaders(
        Uri.parse('https://linux.do'),
        ['cf_clearance=abc; Domain=.linux.do; Path=/; Secure; HttpOnly'],
      );

      final cookies = await jar.loadForRequest(
        Uri.parse('https://connect.linux.do/oauth2/authorize'),
      );

      expect(cookies.map((e) => e.name), contains('cf_clearance'));
    });

    test('host-only cookie only matches exact host', () async {
      await jar.saveFromSetCookieHeaders(
        Uri.parse('https://connect.linux.do/oauth2/authorize'),
        ['auth.session-token=token123; Path=/; Secure; HttpOnly; SameSite=Lax'],
      );

      final exactHostCookies = await jar.loadForRequest(
        Uri.parse('https://connect.linux.do/discourse/sso_callback'),
      );
      final siblingHostCookies = await jar.loadForRequest(
        Uri.parse('https://cdk.linux.do/callback'),
      );

      expect(
          exactHostCookies.map((e) => e.name), contains('auth.session-token'));
      expect(
        siblingHostCookies.map((e) => e.name),
        isNot(contains('auth.session-token')),
      );
    });

    test('invalid cookie values are encoded when converted to io.Cookie',
        () async {
      await jar.saveCanonicalCookies(
        Uri.parse('https://linux.do'),
        [
          CanonicalCookie(
            name: 'g_state',
            value: '{"i_l":0,"i_ll":1774544311822}',
            domain: 'linux.do',
            path: '/',
            originUrl: 'https://linux.do',
            hostOnly: false,
          ),
        ],
      );

      final cookies = await jar.loadForRequest(Uri.parse('https://linux.do'));
      final gState = cookies.firstWhere((e) => e.name == 'g_state');

      expect(gState.value, startsWith('~enc~'));
    });

    // =========================================================================
    // storageKey 去重：同 (name, domain, path) 不同 hostOnly 不共存
    // =========================================================================

    group('storageKey 去重', () {
      test('A1.1: hostOnly=false → hostOnly=true 替换，不共存', () async {
        // 先存 domain cookie (hostOnly=false)
        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: '_t',
              value: 'old',
              domain: '.linux.do',
              path: '/',
              hostOnly: false,
              originUrl: 'https://linux.do',
            ),
          ],
        );

        // 再存 host-only cookie (hostOnly=true)
        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: '_t',
              value: 'new',
              domain: 'linux.do',
              path: '/',
              hostOnly: true,
              originUrl: 'https://linux.do',
            ),
          ],
        );

        final all = await jar.readAllCookies();
        final tCookies = all.where((c) => c.name == '_t').toList();
        expect(tCookies.length, 1, reason: '同名 cookie 只保留一份');
        expect(tCookies.first.value, 'new');
        expect(tCookies.first.hostOnly, true);
      });

      test('A1.2: hostOnly=true → hostOnly=false 替换', () async {
        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: '_t',
              value: 'host_only',
              domain: 'linux.do',
              path: '/',
              hostOnly: true,
              originUrl: 'https://linux.do',
            ),
          ],
        );

        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: '_t',
              value: 'domain',
              domain: '.linux.do',
              path: '/',
              hostOnly: false,
              originUrl: 'https://linux.do',
            ),
          ],
        );

        final all = await jar.readAllCookies();
        final tCookies = all.where((c) => c.name == '_t').toList();
        expect(tCookies.length, 1);
        expect(tCookies.first.value, 'domain');
        expect(tCookies.first.hostOnly, false);
      });

      test('A1.3: 不同 domain 不互相覆盖', () async {
        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: '_t',
              value: 'main',
              domain: 'linux.do',
              path: '/',
              hostOnly: true,
              originUrl: 'https://linux.do',
            ),
          ],
        );

        await jar.saveCanonicalCookies(
          Uri.parse('https://cdn.linux.do'),
          [
            CanonicalCookie(
              name: '_t',
              value: 'cdn',
              domain: 'cdn.linux.do',
              path: '/',
              hostOnly: true,
              originUrl: 'https://cdn.linux.do',
            ),
          ],
        );

        final all = await jar.readAllCookies();
        final tCookies = all.where((c) => c.name == '_t').toList();
        expect(tCookies.length, 2, reason: '不同域名各自独立');
      });

      test('A1.4: 不同 path 不互相覆盖', () async {
        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: 'sid',
              value: 'root',
              domain: 'linux.do',
              path: '/',
              originUrl: 'https://linux.do',
            ),
          ],
        );

        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do/forum'),
          [
            CanonicalCookie(
              name: 'sid',
              value: 'forum',
              domain: 'linux.do',
              path: '/forum',
              originUrl: 'https://linux.do/forum',
            ),
          ],
        );

        final all = await jar.readAllCookies();
        final sidCookies = all.where((c) => c.name == 'sid').toList();
        expect(sidCookies.length, 2);
      });

      test('A1.5: 不同 partitionKey 不互相覆盖（CHIPS）', () async {
        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: '_t',
              value: 'no_pk',
              domain: 'linux.do',
              path: '/',
              partitionKey: null,
              originUrl: 'https://linux.do',
            ),
          ],
        );

        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: '_t',
              value: 'with_pk',
              domain: 'linux.do',
              path: '/',
              partitionKey: 'https://other.com',
              originUrl: 'https://linux.do',
            ),
          ],
        );

        final all = await jar.readAllCookies();
        final tCookies = all.where((c) => c.name == '_t').toList();
        expect(tCookies.length, 2, reason: '不同 partitionKey 各自独立');
      });

      test('A1.6: 完全相同 storageKey 正常覆盖', () async {
        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: '_t',
              value: 'old',
              domain: 'linux.do',
              path: '/',
              hostOnly: true,
              originUrl: 'https://linux.do',
            ),
          ],
        );

        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: '_t',
              value: 'new',
              domain: 'linux.do',
              path: '/',
              hostOnly: true,
              originUrl: 'https://linux.do',
            ),
          ],
        );

        final all = await jar.readAllCookies();
        final tCookies = all.where((c) => c.name == '_t').toList();
        expect(tCookies.length, 1);
        expect(tCookies.first.value, 'new');
      });
    });

    // =========================================================================
    // domain 归一化
    // =========================================================================

    group('domain 归一化', () {
      test('A2.5: .linux.do 和 linux.do 视为同一域名', () async {
        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: '_t',
              value: 'with_dot',
              domain: '.linux.do',
              path: '/',
              hostOnly: false,
              originUrl: 'https://linux.do',
            ),
          ],
        );

        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: '_t',
              value: 'without_dot',
              domain: 'linux.do',
              path: '/',
              hostOnly: true,
              originUrl: 'https://linux.do',
            ),
          ],
        );

        final all = await jar.readAllCookies();
        final tCookies = all.where((c) => c.name == '_t').toList();
        expect(tCookies.length, 1, reason: '归一化后是同一个 storageKey');
        expect(tCookies.first.value, 'without_dot');
      });

      test('WebView 同值快照不把 domain cookie 降级成 host-only', () async {
        await jar.saveFromSetCookieHeaders(
          Uri.parse('https://linux.do'),
          [
            'linux_do_cdk_session_id=token; Domain=.linux.do; Path=/; Secure; SameSite=Lax',
          ],
          trusted: true,
        );

        await jar.saveFromCdpCookies(
          Uri.parse('https://linux.do'),
          [
            {
              'name': 'linux_do_cdk_session_id',
              'value': 'token',
              'domain': 'linux.do',
              'path': '/',
              'secure': true,
              'sameSite': 'Lax',
            },
          ],
          trusted: true,
        );

        final all = await jar.readAllCookies();
        final cdk = all.singleWhere(
          (cookie) => cookie.name == 'linux_do_cdk_session_id',
        );
        expect(cdk.hostOnly, isFalse);
        expect(cdk.domain, '.linux.do');
      });
    });

    // =========================================================================
    // saveFromResponse: io.Cookie → CanonicalCookie hostOnly 解析
    // =========================================================================

    group('saveFromResponse hostOnly 解析', () {
      test('A4.1: domain=null → hostOnly=true', () async {
        final cookie = Cookie('_t', 'token')..path = '/';
        await jar.saveFromResponse(Uri.parse('https://linux.do'), [cookie]);

        final all = await jar.readAllCookies();
        final t = all.firstWhere((c) => c.name == '_t');
        expect(t.hostOnly, true);
      });

      test('A4.2: domain=".linux.do" → hostOnly=false', () async {
        final cookie = Cookie('_t', 'token')
          ..domain = '.linux.do'
          ..path = '/';
        await jar.saveFromResponse(Uri.parse('https://linux.do'), [cookie]);

        final all = await jar.readAllCookies();
        final t = all.firstWhere((c) => c.name == '_t');
        expect(t.hostOnly, false);
      });

      test('A4.3: domain="linux.do" → hostOnly=false', () async {
        final cookie = Cookie('_t', 'token')
          ..domain = 'linux.do'
          ..path = '/';
        await jar.saveFromResponse(Uri.parse('https://linux.do'), [cookie]);

        final all = await jar.readAllCookies();
        final t = all.firstWhere((c) => c.name == '_t');
        expect(t.hostOnly, false);
      });

      test('A4.4: domain="" → hostOnly=true', () async {
        final cookie = Cookie('_t', 'token')
          ..domain = ''
          ..path = '/';
        await jar.saveFromResponse(Uri.parse('https://linux.do'), [cookie]);

        final all = await jar.readAllCookies();
        final t = all.firstWhere((c) => c.name == '_t');
        expect(t.hostOnly, true);
      });
    });

    // =========================================================================
    // loadForRequest 匹配
    // =========================================================================

    group('loadForRequest 匹配', () {
      test('A3.1: host-only cookie 不匹配子域名', () async {
        await jar.saveFromSetCookieHeaders(
          Uri.parse('https://linux.do'),
          ['_t=token; Path=/; Secure; HttpOnly'],
        );

        final cookies = await jar.loadForRequest(
          Uri.parse('https://cdn.linux.do/image.png'),
        );
        expect(cookies.map((e) => e.name), isNot(contains('_t')));
      });

      test('A3.3: host-only cookie 精确匹配主域名', () async {
        await jar.saveFromSetCookieHeaders(
          Uri.parse('https://linux.do'),
          ['_t=token; Path=/; Secure; HttpOnly'],
        );

        final cookies = await jar.loadForRequest(
          Uri.parse('https://linux.do/latest.json'),
        );
        expect(cookies.map((e) => e.name), contains('_t'));
      });

      test('A3.4: 过期 cookie 不返回', () async {
        final pastDate = DateTime.now().subtract(const Duration(days: 1));
        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: 'expired',
              value: 'old',
              domain: 'linux.do',
              path: '/',
              expiresAt: pastDate,
              originUrl: 'https://linux.do',
            ),
          ],
        );

        final cookies = await jar.loadForRequest(
          Uri.parse('https://linux.do'),
        );
        expect(cookies.map((e) => e.name), isNot(contains('expired')));
      });
    });

    // =========================================================================
    // 持久化
    // =========================================================================

    group('持久化', () {
      test('A5.1: session cookie 不持久化', () async {
        // 无 expires 的 cookie 是 session cookie
        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: 'session',
              value: 'temp',
              domain: 'linux.do',
              path: '/',
              originUrl: 'https://linux.do',
            ),
          ],
        );

        // 创建新 jar 实例（模拟重启），共享同一磁盘路径
        final jar2 = EnhancedPersistCookieJar(
          store: FileCookieStore(tempDir.path),
        );
        final all = await jar2.readAllCookies();
        expect(all.where((c) => c.name == 'session'), isEmpty,
            reason: 'session cookie 不应持久化到磁盘');
      });

      test('A5.2: persistent cookie 持久化', () async {
        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: 'persist',
              value: 'keep',
              domain: 'linux.do',
              path: '/',
              expiresAt: DateTime.now().add(const Duration(days: 30)),
              originUrl: 'https://linux.do',
            ),
          ],
        );

        final jar2 = EnhancedPersistCookieJar(
          store: FileCookieStore(tempDir.path),
        );
        final all = await jar2.readAllCookies();
        expect(all.any((c) => c.name == 'persist' && c.value == 'keep'), true);
      });

      test('A5.3: 文件损坏容错', () async {
        // 写入一个合法 cookie
        await jar.saveCanonicalCookies(
          Uri.parse('https://linux.do'),
          [
            CanonicalCookie(
              name: 'test',
              value: 'ok',
              domain: 'linux.do',
              path: '/',
              expiresAt: DateTime.now().add(const Duration(days: 1)),
              originUrl: 'https://linux.do',
            ),
          ],
        );

        // 手动损坏文件
        final cookieFile = File('${tempDir.path}/cookies.v1.json');
        if (await cookieFile.exists()) {
          await cookieFile.writeAsString('CORRUPTED{{{');
        }

        // 新实例应优雅处理
        final jar2 = EnhancedPersistCookieJar(
          store: FileCookieStore(tempDir.path),
        );
        final all = await jar2.readAllCookies();
        expect(all, isEmpty, reason: '损坏文件返回空列表，不崩溃');
      });
    });

    // =========================================================================
    // 原有测试
    // =========================================================================

    test('redirect oauth cookie stays available for same host', () async {
      await jar.saveFromSetCookieHeaders(
        Uri.parse(
          'https://connect.linux.do/oauth2/authorize?client_id=test',
        ),
        [
          'auth.session-token=oauth-token; Path=/; Secure; HttpOnly; SameSite=Lax',
        ],
      );

      final cookies = await jar.loadForRequest(
        Uri.parse('https://connect.linux.do/oauth2/approve/test'),
      );

      expect(
        cookies.any(
          (cookie) =>
              cookie.name == 'auth.session-token' &&
              cookie.value == 'oauth-token',
        ),
        isTrue,
      );
    });
    test('saveFromResponse domain cookie → loadForRequest 能读到', () async {
      final cookie = Cookie('_t', 'token123')
        ..domain = '.linux.do'
        ..path = '/'
        ..secure = false
        ..httpOnly = false;

      await jar.saveFromResponse(Uri.parse('https://linux.do'), [cookie]);

      final loaded = await jar.loadForRequest(Uri.parse('https://linux.do'));
      expect(loaded.any((c) => c.name == '_t'), true,
          reason: '_t should be loadable');
    });

    // =========================================================================
    // deleteByName 显式删除
    // =========================================================================

    group('deleteByName', () {
      test('删除未过期的持久 cookie（过期写入方式会被新鲜度仲裁跳过的场景）', () async {
        await jar.saveFromSetCookieHeaders(
          Uri.parse('https://linux.do'),
          [
            'cf_clearance=token; Domain=.linux.do; Path=/; Secure; HttpOnly; Max-Age=31536000',
          ],
          trusted: true,
        );

        final removed = await jar.deleteByName(
            Uri.parse('https://linux.do'), 'cf_clearance');

        expect(removed, 1);
        final cookies = await jar.loadForRequest(Uri.parse('https://linux.do'));
        expect(cookies.map((e) => e.name), isNot(contains('cf_clearance')));
      });

      test('同站子域上的同名 cookie 一并删除', () async {
        await jar.saveFromSetCookieHeaders(
          Uri.parse('https://connect.linux.do'),
          ['_t=sub; Path=/; Max-Age=3600'],
        );
        await jar.saveFromSetCookieHeaders(
          Uri.parse('https://linux.do'),
          ['_t=main; Path=/; Max-Age=3600'],
        );

        final removed =
            await jar.deleteByName(Uri.parse('https://linux.do'), '_t');

        expect(removed, 2);
        expect(await jar.readAllCookies(), isEmpty);
      });

      test('其他名称的 cookie 不受影响', () async {
        await jar.saveFromSetCookieHeaders(
          Uri.parse('https://linux.do'),
          [
            '_t=keep; Path=/; Max-Age=3600',
            'cf_clearance=x; Path=/; Max-Age=3600',
          ],
        );

        await jar.deleteByName(Uri.parse('https://linux.do'), 'cf_clearance');

        final all = await jar.readAllCookies();
        expect(all.map((c) => c.name).toList(), ['_t']);
      });
    });

    group('replaceByNameForSite', () {
      test('原子替换同站相关的同名 cookie，保留其他站点和其他名称', () async {
        await jar.saveFromSetCookieHeaders(
          Uri.parse('https://linux.do'),
          [
            '_t=main; Path=/; Max-Age=3600',
            '_t=path; Path=/u; Max-Age=3600',
            'cf_clearance=cf; Domain=.linux.do; Path=/; Max-Age=3600',
          ],
          trusted: true,
        );
        await jar.saveFromSetCookieHeaders(
          Uri.parse('https://connect.linux.do'),
          ['_t=sub; Path=/; Max-Age=3600'],
          trusted: true,
        );
        await jar.saveFromSetCookieHeaders(
          Uri.parse('https://example.com'),
          ['_t=other-site; Path=/; Max-Age=3600'],
          trusted: true,
        );

        final removed = await jar.replaceByNameForSite(
          Uri.parse('https://linux.do'),
          '_t',
          [
            CanonicalCookie(
              name: '_t',
              value: 'winner',
              domain: 'linux.do',
              path: '/',
              hostOnly: true,
              originUrl: 'https://linux.do',
            ),
          ],
        );

        expect(removed, 3);
        final all = await jar.readAllCookies();
        final linuxTokens = all
            .where((c) => c.name == '_t' && c.normalizedDomain == 'linux.do');
        expect(linuxTokens.length, 1);
        expect(linuxTokens.single.value, 'winner');
        expect(linuxTokens.single.hostOnly, true);
        expect(linuxTokens.single.path, '/');
        expect(
          all.where(
              (c) => c.name == '_t' && c.normalizedDomain == 'example.com'),
          hasLength(1),
        );
        expect(all.map((c) => c.name), contains('cf_clearance'));
      });
    });

    // =========================================================================
    // 写入一致性
    // =========================================================================

    group('写入一致性', () {
      test('同一 tick 并发保存不丢更新（lost update 回归）', () async {
        final uri = Uri.parse('https://linux.do');
        await Future.wait([
          jar.saveFromSetCookieHeaders(uri, ['a=1; Path=/; Max-Age=3600']),
          jar.saveFromSetCookieHeaders(uri, ['b=2; Path=/; Max-Age=3600']),
          jar.saveFromSetCookieHeaders(uri, ['c=3; Path=/; Max-Age=3600']),
        ]);

        final all = await jar.readAllCookies();
        expect(all.map((c) => c.name).toSet(), {'a', 'b', 'c'});

        // 磁盘内容同样完整（新实例重读验证文件未被互相覆盖/写坏）
        final jar2 = EnhancedPersistCookieJar(
          store: FileCookieStore(tempDir.path),
        );
        final persisted = await jar2.readAllCookies();
        expect(persisted.map((c) => c.name).toSet(), {'a', 'b', 'c'});
      });

      test('替换同 key cookie 时继承 creationTime（RFC 6265 §5.3.11.3）', () async {
        final uri = Uri.parse('https://linux.do');
        await jar.saveFromSetCookieHeaders(
          uri,
          ['_t=old; Path=/; Max-Age=3600'],
          trusted: true,
        );
        final created = (await jar.readAllCookies()).single.creationTime;

        await Future<void>.delayed(const Duration(milliseconds: 20));
        await jar.saveFromSetCookieHeaders(
          uri,
          ['_t=new; Path=/; Max-Age=3600'],
          trusted: true,
        );

        final replaced = (await jar.readAllCookies()).single;
        expect(replaced.value, 'new');
        expect(replaced.creationTime, created);
      });

      test('重复下发相同 Set-Cookie 不触发磁盘重写（脏检查）', () async {
        final uri = Uri.parse('https://linux.do');
        const header = '_t=tok; Path=/; Expires=Wed, 01 Jan 2098 00:00:00 GMT';
        await jar.saveFromSetCookieHeaders(uri, [header], trusted: true);

        // 删掉正式文件后重复保存相同内容：脏检查生效则跳过写盘，文件不重建
        final file = File('${tempDir.path}/cookies.v1.json');
        expect(await file.exists(), true);
        await file.delete();

        await jar.saveFromSetCookieHeaders(uri, [header], trusted: true);
        expect(await file.exists(), false, reason: '内容未变应跳过磁盘写');

        // 值变化时正常写盘
        await jar.saveFromSetCookieHeaders(
          uri,
          ['_t=rotated; Path=/; Expires=Wed, 01 Jan 2098 00:00:00 GMT'],
          trusted: true,
        );
        expect(await file.exists(), true);
      });

      test('session cookie 刷新不触发磁盘重写', () async {
        final uri = Uri.parse('https://linux.do');
        await jar.saveFromSetCookieHeaders(
          uri,
          ['_t=tok; Path=/; Max-Age=3600'],
          trusted: true,
        );

        final file = File('${tempDir.path}/cookies.v1.json');
        await file.delete();

        // session cookie（无 expires/max-age）不持久化，
        // 高频刷新不应导致持久集合全量重写
        await jar.saveFromSetCookieHeaders(
          uri,
          ['_forum_session=abc; Path=/; HttpOnly'],
          trusted: true,
        );
        await jar.saveFromSetCookieHeaders(
          uri,
          ['_forum_session=def; Path=/; HttpOnly'],
          trusted: true,
        );
        expect(await file.exists(), false);

        // 内存中仍可读到 session cookie 最新值
        final loaded = await jar.loadForRequest(uri);
        final session = loaded.firstWhere((c) => c.name == '_forum_session');
        expect(session.value, 'def');
      });
    });

    // =========================================================================
    // 跨 isolate 重载
    // =========================================================================

    group('reloadPersistedCookies', () {
      test('吸收磁盘新值并保留内存 session cookie', () async {
        final uri = Uri.parse('https://linux.do');
        await jar.saveFromSetCookieHeaders(
          uri,
          ['_t=old; Path=/; Max-Age=3600', '_forum_session=mem; Path=/'],
          trusted: true,
        );

        // 模拟另一个 isolate 写盘：用独立 store 实例改写文件中的 _t
        final otherJar = EnhancedPersistCookieJar(
          store: FileCookieStore(tempDir.path),
        );
        await otherJar.saveFromSetCookieHeaders(
          uri,
          ['_t=rotated-by-bg; Path=/; Max-Age=3600'],
          trusted: true,
        );

        await jar.reloadPersistedCookies();

        final loaded = await jar.loadForRequest(uri);
        final t = loaded.firstWhere((c) => c.name == '_t');
        final session = loaded.firstWhere((c) => c.name == '_forum_session');
        expect(t.value, 'rotated-by-bg', reason: '持久 cookie 以磁盘为准');
        expect(session.value, 'mem', reason: '内存 session cookie 不丢失');
      });
    });

    // =========================================================================
    // 分区 cookie 去重
    // =========================================================================

    group('分区 cookie 去重', () {
      test('同名同域同路径、仅 partitionKey 不同时只发送更新鲜的一条', () async {
        final uri = Uri.parse('https://linux.do');
        final now = DateTime.now().toUtc();
        // 旧的非分区 cf_clearance（较早过期）
        await jar.saveFromCdpCookies(uri, [
          {
            'name': 'cf_clearance',
            'value': 'stale-value',
            'domain': '.linux.do',
            'path': '/',
            'expires':
                now.add(const Duration(days: 30)).millisecondsSinceEpoch / 1000,
            'secure': true,
            'httpOnly': true,
          },
        ]);
        // CF 以 CHIPS 分区 cookie 重新签发的新 cf_clearance
        await jar.saveFromCdpCookies(uri, [
          {
            'name': 'cf_clearance',
            'value': 'fresh-value',
            'domain': '.linux.do',
            'path': '/',
            'expires':
                now.add(const Duration(days: 365)).millisecondsSinceEpoch /
                    1000,
            'secure': true,
            'httpOnly': true,
            'partitionKey': 'https://linux.do',
          },
        ]);

        final loaded = await jar.loadForRequest(uri);
        final clearances =
            loaded.where((c) => c.name == 'cf_clearance').toList();
        expect(clearances, hasLength(1), reason: '同名 cookie 不应重复发送');
        expect(clearances.single.value, 'fresh-value');
      });
    });
  });
}
