import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/core/metaverse_link_rule.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

const _reserved = ['linux.do'];

Map<String, dynamic> _example() => jsonDecode(
  File('test/fixtures/metaverse/api1_token.json').readAsStringSync(),
) as Map<String, dynamic>;

MetaversePluginManifest _parse(Map<String, dynamic> json) =>
    MetaversePluginManifest.parse(json, reservedHosts: _reserved);

/// 记录请求并返回固定响应的适配器。
class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  String body = '{}';
  Uint8List? bytes;
  String? contentType = 'application/json';
  ResponseBody Function(RequestOptions)? responseFor;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (responseFor case final respond?) return respond(options);
    return ResponseBody.fromBytes(
      bytes ?? utf8.encode(body),
      status,
      headers: {
        if (contentType != null) 'content-type': [contentType!],
        'set-cookie': ['sid=1'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('历史业务清单只能作为升级元数据读取，新安装拒绝旧协议', () {
    final raw = jsonDecode(File('test/fixtures/metaverse/api1_shop.json').readAsStringSync());
    expect(() => MetaversePluginManifest.parse(raw), throwsA(isA<MetaverseManifestException>()));
    final old = MetaversePluginManifest.parse(raw, allowLegacyMetadata: true);
    expect(old.runtimeSupported, isFalse);
    expect(old.auth.canAttachCredential, isFalse);
    expect(old.raw, raw);
    expect(old.sameApprovalAs(_parse(_example())), isFalse);
  });
  test('网站会话只接受公开的登录地址，后续入口须为同源路径', () {
    final shop = _parse({
      ..._example(),
      'schema': 2,
      'webLogin': 'https://shop.example.org/login',
    });
    expect(
      shop.webSessionPage('/orders?q=12')?.toString(),
      'https://shop.example.org/orders?q=12',
    );
    expect(_parse(_example()).webSessionPage('/orders'), isNull);
    for (final path in [
      '//other.example.org',
      r'/\other.example.org',
      'https://other.example.org/',
      'file:///orders',
      'relative',
    ]) {
      expect(shop.webSessionPage(path), isNull, reason: path);
    }
    for (final url in [
      'http://shop.example.org',
      'https://id@shop.example.org',
      'https://connect.linux.do/login',
      'https://shop.local/login',
    ]) {
      expect(
        () => _parse({..._example(), 'schema': 2, 'webLogin': url}),
        throwsA(isA<MetaverseManifestException>()),
        reason: url,
      );
    }
  });
  test('文件安装保持插件来源稳定，复用清单和 UI 校验', () async {
    final manifest = _example();
    final installer = MetaversePluginInstaller(
      network: MetaversePluginNetwork(),
      reservedHosts: _reserved,
    );
    Future<MetaversePluginPackage> bundle(String ui, String script) =>
        installer.importBundle(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'manifest': manifest,
                'files': {'ui.rfwtxt': ui, 'main.js': script},
              }),
            ),
          ),
        );
    const ui = 'import fluxdo; widget Card = Gap(); widget OrderPage = Gap();';
    final first = await bundle(ui, '// v1');
    expect((await bundle(ui, '// v2')).source, first.source);
    expect(first.source, 'file:${manifest['id']}');
    await expectLater(
      installer.importBundle(Stream.value(utf8.encode('{}')), expectedDigest: '0' * 64),
      throwsA(isA<MetaversePluginInstallException>()),
    );
    await expectLater(
      bundle('widget Bad = Gap();', ''),
      throwsA(isA<MetaversePluginInstallException>()),
    );
    await expectLater(
      installer.importBundle(
        Stream.value(Uint8List(MetaversePluginInstaller.maxBundleBytes + 1)),
      ),
      throwsA(isA<MetaversePluginInstallException>()),
    );
  });

  test('公开图片权限不扩大脚本联网权限，也不允许加载站内和非公网资源', () async {
    final adapter = _Adapter()
      ..contentType = 'image/png'
      ..body = 'image';
    final network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = adapter,
      lookup: (host) async => [
        InternetAddress(
          host == 'private.example.org' ? '127.0.0.1' : '8.8.8.8',
        ),
      ],
    );
    final json = _example();
    (json['permissions'] as Map)['publicImages'] = true;
    expect(() => _parse(json), throwsA(isA<MetaverseManifestException>()));
    json['schema'] = 2;
    final manifest = _parse(json);
    expect(
      await network.loadImage(
        manifest,
        Uri.parse('https://images.example.org/a'),
      ),
      utf8.encode('image'),
    );
    for (final uri in ['https://private.example.org/a', 'https://linux.do/a']) {
      await expectLater(
        network.loadImage(manifest, Uri.parse(uri)),
        throwsA(isA<MetaversePluginCallException>()),
      );
    }
    await expectLater(
      network.fetch(
        manifest,
        request: {'url': 'https://images.example.org/a'},
        authToken: null,
      ),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.headers['User-Agent'], isNotEmpty);
    expect(adapter.requests.single.headers['Accept'], 'image/*');
    expect(adapter.requests.single.headers.containsKey('Cookie'), isFalse);
    expect(
      adapter.requests.single.headers.containsKey('Authorization'),
      isFalse,
    );
  });
  test('公开图片支持超过 2 MiB 的原图，拒绝超限数据与 HTML 响应', () async {
    final adapter = _Adapter()
      ..contentType = 'image/png'
      ..body = 'x' * 3170395;
    final network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = adapter,
      lookup: (_) async => [InternetAddress('198.18.0.6')],
    );
    addTearDown(network.dispose);
    final raw = _example()..['schema'] = 2;
    (raw['permissions'] as Map)['publicImages'] = true;
    final manifest = _parse(raw);
    final uri = Uri.parse('https://images.example.org/large.png');
    expect((await network.loadImage(manifest, uri)).length, 3170395);
    adapter.body = 'x' * (MetaversePluginNetwork.maxImageBytes + 1);
    await expectLater(
      network.loadImage(manifest, uri),
      throwsA(
        isA<MetaversePluginCallException>().having(
          (e) => e.message,
          '大小限制',
          '响应过大',
        ),
      ),
    );
    adapter
      ..body = '<html>image unavailable</html>'
      ..contentType = 'text/html';
    await expectLater(
      network.loadImage(manifest, uri),
      throwsA(
        isA<MetaversePluginCallException>().having(
          (e) => e.message,
          '格式检查',
          '图片不可用',
        ),
      ),
    );
  });
  test('缺省或错误 MIME 按图片文件头识别，不依赖网址后缀', () async {
    final adapter = _Adapter();
    final network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = adapter,
      lookup: (_) async => [InternetAddress('198.18.0.6')],
    );
    addTearDown(network.dispose);
    final raw = _example()..['schema'] = 2;
    (raw['permissions'] as Map)['publicImages'] = true;
    final manifest = _parse(raw);
    final uri = Uri.parse('https://images.example.org/file');
    for (final type in [
      null,
      '',
      'application/octet-stream',
      'Application/Octet-Stream; charset=binary',
      'jpg',
      'text/plain',
    ]) {
      adapter.contentType = type;
      for (final bytes in [
        Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 0, 0x10]),
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+'
          'A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
        Uint8List.fromList(utf8.encode(
          '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>',
        )),
      ]) {
        adapter.bytes = bytes;
        expect(await network.loadImage(manifest, uri), bytes);
      }
      for (final body in ['', '<html>unavailable</html>', '{"error":true}']) {
        adapter.bytes = Uint8List.fromList(utf8.encode(body));
        await expectLater(
          network.loadImage(
            manifest,
            Uri.parse('https://images.example.org/fake.jpeg'),
          ),
          throwsA(isA<MetaversePluginCallException>()),
        );
      }
    }
  });
  test('图片跳转逐跳校验且保持匿名，仅发送公开主页 origin', () async {
    final adapter = _Adapter()
      ..responseFor = (request) {
        if (request.uri.path == '/start') {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['/next'],
            },
          );
        }
        if (request.uri.path == '/next') {
          return ResponseBody.fromString(
            '',
            301,
            headers: {
              'location': ['http://image_bed.example.org:8443/end'],
              'set-cookie': ['image_session=never-forward'],
            },
          );
        }
        return ResponseBody.fromBytes(
          [0xff, 0xd8, 0xff, 0xe0],
          200,
          headers: {
            'content-type': ['jpg'],
          },
        );
      };
    final network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = adapter,
      lookup: (_) async => [InternetAddress('198.18.0.6')],
    );
    addTearDown(network.dispose);
    final raw = _example()..['schema'] = 2;
    raw['homepage'] = 'https://service.example.org/about?private=query';
    (raw['permissions'] as Map)['publicImages'] = true;
    final manifest = _parse(raw);
    expect(
      await network.loadImage(
        manifest,
        Uri.parse('http://images.example.org/start'),
      ),
      [0xff, 0xd8, 0xff, 0xe0],
    );
    expect(adapter.requests, hasLength(3));
    for (final request in adapter.requests) {
      expect(request.headers['Referer'], 'https://service.example.org/');
      expect(request.uri.scheme, 'https');
      expect(request.headers.containsKey('Cookie'), isFalse);
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(request.followRedirects, isFalse);
    }
    // 图片地址兼容不会扩大脚本请求的地址范围。
    await expectLater(
      network.fetch(
        manifest,
        request: {'url': 'https://image_bed.example.org:8443/end'},
        authToken: null,
      ),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(adapter.requests, hasLength(3));
  });

  test('图片跳转拒绝内网、宿主域名和地址凭证并限制跳转次数', () async {
    var location = '';
    final adapter = _Adapter()
      ..responseFor = (_) => ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [location],
        },
      );
    final network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = adapter,
      lookup: (host) async => [
        InternetAddress(
          host == 'private.example.org' ? '127.0.0.1' : '198.18.0.6',
        ),
      ],
    );
    addTearDown(network.dispose);
    final raw = _example()..['schema'] = 2;
    (raw['permissions'] as Map)['publicImages'] = true;
    final manifest = _parse(raw);
    final source = Uri.parse('https://images.example.org/start');
    for (final target in [
      'https://private.example.org:8443/a',
      'http://private.example.org/a',
      'https://linux.do/a',
      'https://sub.linux.do/a',
      'https://127.0.0.1/a',
      'file:///private/image.png',
      'https://user:password@images.example.org/a',
      'https://images.example.org:0/a',
      'https://images.example.org:65536/a',
    ]) {
      location = target;
      adapter.requests.clear();
      await expectLater(
        network.loadImage(manifest, source),
        throwsA(isA<MetaversePluginCallException>()),
      );
      expect(adapter.requests, hasLength(1), reason: target);
    }
    location = source.toString();
    adapter.requests.clear();
    await expectLater(
      network.loadImage(manifest, source),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(adapter.requests, hasLength(6));
  });

  test('没有公开图片权限时重定向仍受声明域名约束', () async {
    final adapter = _Adapter()
      ..responseFor = (_) => ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://unlisted.example.org/image.png'],
        },
      );
    final network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = adapter,
      lookup: (_) async => [InternetAddress('198.18.0.6')],
    );
    addTearDown(network.dispose);
    final manifest = _parse(_example());
    await expectLater(
      network.loadImage(
        manifest,
        Uri.parse('https://${manifest.networkHosts.first}/image.png'),
      ),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(adapter.requests, hasLength(1));
  });

  group('清单校验', () {
    test('示例清单合法，声明的能力被完整解析', () {
      final manifest = _parse(_example());
      expect(manifest.id, 'com.example.points');
      expect(manifest.networkHosts, ['api.example.com']);
      expect(manifest.identity, isTrue);
      expect(manifest.auth.type, MetaversePluginAuthType.token);
      expect(manifest.cardWidget, 'Card');
      expect(manifest.page('order')?.widget, 'OrderPage');
      expect(manifest.linkHosts, ['example.com']);
    });

    // 插件不能把站点自身、内网或 IP 写进网络白名单：前者会让请求有机会
    // 带上站点登录态，后者让第三方代码够到用户的局域网。
    for (final host in [
      'linux.do',
      'connect.linux.do',
      '*.linux.do',
      'LINUX.DO',
      'localhost',
      'router.local',
      '192.168.1.1',
      '127.0.0.1',
      '*',
      '*.com.',
      'a..b.com',
    ]) {
      test('网络白名单拒绝 $host', () {
        final json = _example();
        json['permissions'] = {
          'network': [host],
        };
        (json['auth'] as Map)['hosts'] = [host];
        expect(() => _parse(json), throwsA(isA<MetaverseManifestException>()));
      });
    }

    test('链接规则不能接管站点自身的链接', () {
      final json = _example();
      json['links'] = [
        {'host': 'linux.do', 'path': '/t/:id', 'page': 'order'},
      ];
      expect(() => _parse(json), throwsA(isA<MetaverseManifestException>()));
    });

    test('凭证只能发往网络白名单内的域名', () {
      final json = _example();
      (json['auth'] as Map)['hosts'] = ['evil.example.org'];
      expect(
        () => _parse(json),
        throwsA(
          isA<MetaverseManifestException>().having(
            (e) => e.field,
            'field',
            'auth.hosts',
          ),
        ),
      );
    });

    test('凭证域名的通配范围不能比白名单更宽', () {
      final json = _example();
      (json['auth'] as Map)['hosts'] = ['*.example.com'];
      expect(() => _parse(json), throwsA(isA<MetaverseManifestException>()));
    });

    test('凭证不能写进 Cookie 这类保留请求头', () {
      final json = _example();
      (json['auth'] as Map)['header'] = 'Cookie';
      expect(() => _parse(json), throwsA(isA<MetaverseManifestException>()));
    });

    for (final path in [
      '../main.js',
      '/main.js',
      'https://x.com/a.js',
      r'a\b.js',
    ]) {
      test('代码文件路径拒绝 $path', () {
        final json = _example()..['script'] = path;
        expect(() => _parse(json), throwsA(isA<MetaverseManifestException>()));
      });
    }

    test('链接规则指向未声明的页面时拒绝', () {
      final json = _example();
      (json['links'] as List).first['page'] = 'missing';
      expect(() => _parse(json), throwsA(isA<MetaverseManifestException>()));
    });

    test('界面描述缺少清单引用的组件时拒绝安装', () {
      expect(
        () => MetaversePluginInstaller.validateUi(
          _parse(_example()),
          'import fluxdo; widget Card = Gap();',
        ),
        throwsA(
          isA<MetaversePluginInstallException>().having(
            (e) => e.message,
            'message',
            contains('OrderPage'),
          ),
        ),
      );
    });

    test('Windows CRLF 与 LF 的插件界面均能解析', () {
      const ui =
          'import fluxdo;\nwidget Card = Gap();\nwidget OrderPage = Gap();\n';
      for (final text in [ui, ui.replaceAll('\n', '\r\n')]) {
        final library = MetaversePluginInstaller.validateUi(
          _parse(_example()),
          text,
        );
        expect(library.widgets, hasLength(2));
      }
    });

    test('界面描述不能 import 宿主组件库以外的库', () {
      expect(
        () => MetaversePluginInstaller.validateUi(
          _parse(_example()),
          'import core.widgets; widget Card = Gap(); widget OrderPage = Gap();',
        ),
        throwsA(isA<MetaversePluginInstallException>()),
      );
    });
  });

  group('链接规则', () {
    MetaverseLinkRule rule(String host, String path) =>
        MetaverseLinkRule.parse(host: host, path: path, page: 'p')!;

    test('按段匹配并捕获参数', () {
      final r = rule('example.com', '/orders/:id');
      expect(r.match(Uri.parse('https://example.com/orders/42')), {'id': '42'});
      expect(r.match(Uri.parse('https://example.com/orders/42/')), {
        'id': '42',
      });
      expect(r.match(Uri.parse('https://example.com/orders')), isNull);
      expect(r.match(Uri.parse('https://example.com/orders/42/items')), isNull);
      expect(r.match(Uri.parse('https://example.com/other/42')), isNull);
    });

    test('精确域名不匹配子域，也不匹配同后缀的其它域名', () {
      final r = rule('example.com', '/orders/:id');
      expect(r.match(Uri.parse('https://a.example.com/orders/1')), isNull);
      expect(r.match(Uri.parse('https://evilexample.com/orders/1')), isNull);
      expect(
        r.match(Uri.parse('https://example.com.evil.io/orders/1')),
        isNull,
      );
    });

    test('通配域名只匹配子域', () {
      final r = rule('*.example.com', '/x');
      expect(r.match(Uri.parse('https://a.example.com/x')), isEmpty);
      expect(r.match(Uri.parse('https://example.com/x')), isNull);
      expect(r.match(Uri.parse('https://evilexample.com/x')), isNull);
    });

    test('末尾通配捕获剩余路径；非 http(s) 协议不匹配', () {
      final r = rule('example.com', '/docs/*');
      expect(r.match(Uri.parse('https://example.com/docs/a/b')), {
        'rest': 'a/b',
      });
      expect(r.match(Uri.parse('ftp://example.com/docs/a')), isNull);
    });

    test('不合法的路径模式被拒绝', () {
      for (final path in ['orders', '/a/*/b', '/:id/:id', '/a:b', '/:1x']) {
        expect(
          MetaverseLinkRule.parse(host: 'example.com', path: path, page: 'p'),
          isNull,
          reason: path,
        );
      }
    });
  });

  group('插件网络', () {
    late _Adapter adapter;
    late MetaversePluginNetwork network;
    late MetaversePluginManifest manifest;

    setUp(() {
      adapter = _Adapter();
      network = MetaversePluginNetwork(
        dio: Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = adapter,
        lookup: (host) async => [
          InternetAddress(
            host == 'api.example.com' ? '93.184.216.34' : '10.0.0.5',
          ),
        ],
      );
      manifest = _parse(_example());
    });

    Future<Map<String, Object?>> fetch(
      Map<String, Object?> request, {
      String? token,
    }) => network.fetch(manifest, request: request, authToken: token);

    test('白名单内的请求发出，响应不含 Set-Cookie', () async {
      adapter.body = '{"balance": 7}';
      final response = await fetch({
        'url': 'https://api.example.com/v1/balance',
      });
      expect(response['status'], 200);
      expect(response['body'], '{"balance": 7}');
      expect((response['headers'] as Map).containsKey('set-cookie'), isFalse);
      expect(adapter.requests.single.headers.keys, isNot(contains('cookie')));
    });

    for (final url in [
      'https://evil.example.org/x',
      'https://linux.do/session/current.json',
      'http://api.example.com/x',
      'https://api.example.com:8443/x',
      'https://user:pw@api.example.com/x',
      'file:///etc/passwd',
    ]) {
      test('拒绝 $url', () async {
        await expectLater(
          fetch({'url': url}),
          throwsA(isA<MetaversePluginCallException>()),
        );
        expect(adapter.requests, isEmpty);
      });
    }

    test('白名单域名解析到内网地址时拒绝（DNS 重绑定）', () async {
      final json = _example();
      json['permissions'] = {
        'network': ['api.example.com', 'rebind.example.com'],
      };
      manifest = _parse(json);
      await expectLater(
        fetch({'url': 'https://rebind.example.com/x'}),
        throwsA(
          isA<MetaversePluginCallException>().having(
            (e) => e.message,
            'message',
            contains('内网'),
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    });

    test('请求只解析一次，传输收到同一份筛选结果', () async {
      var lookups = 0;
      final client = MetaversePluginNetwork(
        dio: Dio()..httpClientAdapter = adapter,
        lookup: (host) async {
          expect(host, 'api.example.com');
          return ++lookups == 1
              ? [InternetAddress('10.0.0.2'), InternetAddress('8.8.8.8')]
              : [InternetAddress('127.0.0.1')];
        },
      );
      addTearDown(client.dispose);
      await client.fetch(
        manifest,
        request: {'url': 'https://api.example.com/'},
        authToken: null,
      );
      expect(lookups, 1);
      expect(adapter.requests.single.extra['pinnedAddresses'], ['8.8.8.8']);
    });

    test('脚本不能自己设置 Cookie 等保留请求头', () async {
      for (final header in [
        'Cookie',
        'Host',
        'Proxy-Authorization',
        'Sec-Fetch-Site',
      ]) {
        await expectLater(
          fetch({
            'url': 'https://api.example.com/x',
            'headers': {header: 'v'},
          }),
          throwsA(isA<MetaversePluginCallException>()),
          reason: header,
        );
      }
      expect(adapter.requests, isEmpty);
    });

    test('auth: true 由宿主附带凭证，并覆盖脚本自带的同名请求头', () async {
      await fetch({
        'url': 'https://api.example.com/x',
        'auth': true,
        'headers': {'authorization': 'Bearer forged'},
      }, token: 'secret');
      // Dio 的请求头表不区分大小写，所以按值断言：只有一份，且是宿主的凭证。
      final values = adapter.requests.single.headers.entries
          .where((e) => e.key.toLowerCase() == 'authorization')
          .map((e) => e.value)
          .toList();
      expect(values, ['Bearer secret']);
    });

    test('凭证不会发往 auth.hosts 之外的白名单域名', () async {
      final json = _example();
      json['permissions'] = {
        'network': ['api.example.com', 'cdn.example.net'],
      };
      manifest = _parse(json);
      network = MetaversePluginNetwork(
        dio: Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = adapter,
        lookup: (_) async => [InternetAddress('93.184.216.34')],
      );
      await expectLater(
        fetch({'url': 'https://cdn.example.net/x', 'auth': true}, token: 's'),
        throwsA(isA<MetaversePluginCallException>()),
      );
      expect(adapter.requests, isEmpty);
    });

    test('未授权时 auth 请求以 auth_required 失败，不发出请求', () async {
      await expectLater(
        fetch({'url': 'https://api.example.com/x', 'auth': true}),
        throwsA(
          isA<MetaversePluginCallException>().having(
            (e) => e.message,
            'message',
            'auth_required',
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    });

    test('响应超过上限时中止', () async {
      adapter.body = 'x' * (MetaversePluginNetwork.maxResponseBody + 1);
      await expectLater(
        fetch({'url': 'https://api.example.com/x'}),
        throwsA(isA<MetaversePluginCallException>()),
      );
    });

    test('内网地址判定', () {
      for (final ip in [
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.0.1',
        '169.254.169.254',
        '100.64.0.1',
        '0.0.0.0',
        '::1',
        '::',
        'fe80::1',
        'fd00::1',
        '::ffff:10.0.0.1',
      ]) {
        expect(
          MetaversePluginNetwork.isPrivateAddress(InternetAddress(ip)),
          isTrue,
          reason: ip,
        );
      }
      for (final ip in ['93.184.216.34', '172.32.0.1', '2606:4700::1111']) {
        expect(
          MetaversePluginNetwork.isPrivateAddress(InternetAddress(ip)),
          isFalse,
          reason: ip,
        );
      }
    });
  });
}
