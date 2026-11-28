import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/services/plugin_image_cache.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
final _uri = Uri.https('images.example.org', '/photo.png');

class _Server implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  late FutureOr<ResponseBody> Function(RequestOptions) reply;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return await reply(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory temp;
  late PluginImageCache cache;
  late DateTime now;
  late _Server server;
  late MetaversePluginNetwork network;
  late MetaversePluginManifest manifest;
  late int lookups;
  PluginImageCache newCache({
    int memory = 4096,
    int plugin = 1 << 20,
    int disk = 2 << 20,
    int count = 256,
  }) => PluginImageCache(
    directory: () async => Directory(p.join(temp.path, 'images')),
    now: () => now,
    memoryLimit: memory,
    pluginLimit: plugin,
    diskLimit: disk,
    entryLimit: count,
  );
  ResponseBody photo({
    String? control,
    Map<String, List<String>> headers = const {},
  }) => ResponseBody.fromBytes(
    _png,
    200,
    headers: {
      'content-type': ['image/png'],
      if (control != null) 'cache-control': [control],
      ...headers,
    },
  );
  Future<Uint8List> get({
    Uri? uri,
    int? account = 1,
    String? source = 'market',
    bool external = true,
    bool avatar = false,
    bool reload = false,
    Object? runtime,
    void Function()? active,
    MetaversePluginManifest? as,
  }) => network.loadImage(
    as ?? manifest,
    uri ?? _uri,
    cache: cache,
    account: account,
    cacheSource: source,
    allowPublicImages: external,
    forumAvatar: avatar,
    reload: reload,
    runtime: runtime,
    checkActive: active,
  );
  MetaversePluginManifest other() => MetaversePluginManifest.parse(
    {...manifest.raw, 'id': 'example.other'},
    reservedHosts: ['linux.do'],
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('plugin-image-test-');
    now = DateTime.utc(2026, 1, 1, 12);
    cache = newCache();
    lookups = 0;
    server = _Server()..reply = (_) => photo();
    network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = server,
      lookup: (_) async {
        lookups++;
        return [InternetAddress('198.18.0.6')];
      },
    );
    final raw = jsonDecode(
      File('test/fixtures/metaverse/api1_token.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    (raw['permissions'] as Map)['publicImages'] = true;
    manifest = MetaversePluginManifest.parse(
      {...raw, 'schema': 2},
      reservedHosts: ['linux.do'],
    );
  });
  tearDown(() async {
    network.dispose();
    await temp.delete(recursive: true);
  });

  test('列表和详情合并下载，重建组件与重开应用不再查询 DNS', () async {
    final started = Completer<void>(), finish = Completer<void>();
    server.reply = (_) async {
      started.complete();
      await finish.future;
      return photo();
    };
    final first = get();
    await started.future;
    final next = get(
      uri: _uri.replace(scheme: 'http', fragment: 'thumb'),
    );
    finish.complete();
    final values = await Future.wait([first, next]);
    expect(identical(values.first, values.last), isTrue);
    expect(identical(await get(runtime: Object()), values.first), isTrue);
    cache = newCache();
    expect(await get(runtime: Object()), _png);
    expect(server.requests, hasLength(1));
    expect(lookups, 1);
    expect(await cache.size(manifest.id), _png.length);
    final names =
        (await temp.list(recursive: true).where((f) => f is File).toList()).map(
          (f) => p.basename(f.path),
        );
    expect(names.single, matches(RegExp(r'^[a-f0-9]{64}-[a-f0-9]{64}$')));
  });

  test('响应年龄决定到期时间，过期后不以旧图掩盖失败', () async {
    server.reply = (_) => photo(
      control: 'max-age="60"',
      headers: {
        'age': ['40'],
      },
    );
    await get();
    now = now.add(const Duration(seconds: 19));
    await get();
    cache = newCache();
    await get();
    expect(server.requests.length, 1);
    now = now.add(const Duration(seconds: 1));
    server.reply = (_) => ResponseBody.fromString('unavailable', 503);
    await expectLater(get(), throwsA(isA<MetaversePluginCallException>()));
    server.reply = (_) => photo();
    expect(await get(), _png);
    expect(server.requests.length, 3);
  });

  test('不保存私有响应、查询参数、未知变体或只声明为图片的错误页', () async {
    for (final entry in [
      (
        uri: _uri,
        headers: {
          'cache-control': ['Public, no-store'],
        },
      ),
      (
        uri: _uri,
        headers: {
          'cache-control': ['private="x", max-age=300'],
        },
      ),
      (
        uri: _uri,
        headers: {
          'cache-control': ['no-cache'],
        },
      ),
      (
        uri: _uri,
        headers: {
          'cache-control': ['max-age=0'],
        },
      ),
      (
        uri: _uri,
        headers: {
          'vary': ['User-Agent'],
        },
      ),
      (
        uri: _uri,
        headers: {
          'vary': ['*'],
        },
      ),
      (
        uri: _uri.replace(queryParameters: {'ticket': 'sample'}),
        headers: <String, List<String>>{},
      ),
    ]) {
      server.reply = (_) => photo(headers: entry.headers);
      final before = server.requests.length;
      await get(uri: entry.uri);
      await get(uri: entry.uri);
      expect(server.requests.length - before, 2);
      expect(await cache.size(), 0);
    }
    server.reply = (_) => ResponseBody.fromString(
      '<html>unavailable</html>',
      200,
      headers: {
        'content-type': ['image/jpeg'],
      },
    );
    await get();
    expect(await cache.size(), 0);
    server.reply = (_) => photo();
    expect(await get(), _png);
  });

  test('相同网址按插件、来源和账号隔离，开发预览不读取正式缓存', () async {
    await get();
    await get(as: other());
    await get(source: 'different');
    await get(account: null);
    await get(account: 2);
    await get(source: null);
    await get(source: null);
    await get();
    expect(server.requests.length, 7);
    expect(await cache.size(manifest.id), 4 * _png.length);
    expect(await cache.size(other().id), _png.length);
  });

  test('图片权限先于命中，跳转每次检查权限与论坛头像资格', () async {
    await get();
    await expectLater(
      get(external: false),
      throwsA(isA<MetaversePluginCallException>()),
    );
    final avatar = Uri.https('linux.do', '/user_avatar/alice/48/1.png');
    await get(uri: avatar, avatar: true);
    await expectLater(
      get(uri: avatar),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(server.requests.length, 2);
    final from = Uri.https('api.example.com', '/redirect');
    server.reply = (r) => r.uri == from
        ? ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': [_uri.toString()],
            },
          )
        : photo();
    expect(await get(uri: from), _png);
    await expectLater(
      get(uri: from, external: false),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(await get(uri: from), _png);
    expect(server.requests.length, 7);
  });

  test('撤销实例不交付迟到字节，也不向新会话写入', () async {
    var active = true;
    final started = Completer<void>(), finish = Completer<void>();
    server.reply = (_) async {
      started.complete();
      await finish.future;
      return photo();
    };
    final old = get(
      active: () {
        if (!active) throw const PluginOperationCancelled();
      },
    );
    await started.future;
    final failed = expectLater(old, throwsA(isA<PluginOperationCancelled>()));
    active = false;
    finish.complete();
    await failed;
    expect(await cache.size(), 0);
    server.reply = (_) => photo();
    expect(await get(runtime: Object()), _png);
    expect(server.requests.length, 2);
  });

  test('清除时旧请求不能覆盖新图，其他插件保持命中', () async {
    await get();
    await get(as: other());
    final oldImage = Uint8List.fromList([..._png, 1]);
    final started = Completer<void>(), finish = Completer<void>();
    server.reply = (_) async {
      started.complete();
      await finish.future;
      return ResponseBody.fromBytes(oldImage, 200);
    };
    final old = get(reload: true);
    await started.future;
    final cleared = cache.clear(manifest.id);
    server.reply = (_) => photo();
    final fresh = get();
    await cleared;
    expect(await fresh, _png);
    finish.complete();
    expect(await old, oldImage);
    cache = newCache();
    expect(await get(), _png);
    expect(await get(as: other()), _png);
    expect(server.requests.length, 4);
    await cache.clear();
    expect(await cache.size(), 0);
    expect(await get(), _png);
    expect(server.requests.length, 5);
  });

  test('手动重试替换坏图，源站要求不缓存时不留下旧副本', () async {
    final broken = _png.sublist(0, 12);
    server.reply = (_) => ResponseBody.fromBytes(broken, 200);
    expect(await get(), broken);
    server.reply = (_) => photo(control: 'no-store');
    expect(await get(reload: true), _png);
    expect(await cache.size(), 0);
    server.reply = (_) => photo();
    await get();
    await get();
    expect(server.requests.length, 3);
  });

  test('长列表冷加载有并发上限，损坏的缓存目录不阻止图片显示', () async {
    var busy = 0, peak = 0;
    final firstBatch = Completer<void>(), finish = Completer<void>();
    server.reply = (_) async {
      busy++;
      if (busy > peak) peak = busy;
      if (busy == 4 && !firstBatch.isCompleted) firstBatch.complete();
      await finish.future;
      busy--;
      return photo();
    };
    final batch = Future.wait([
      for (var i = 0; i < 12; i++) get(uri: _uri.replace(path: '/item/$i')),
    ]);
    await firstBatch.future;
    finish.complete();
    expect(await batch, everyElement(_png));
    expect(peak, 4);
    final invalid = File(p.join(temp.path, 'not-a-directory'));
    await invalid.writeAsString('');
    cache = PluginImageCache(
      directory: () async => Directory(invalid.path),
      now: () => now,
    );
    expect(await get(), _png);
    expect(server.requests.length, 13);
  });

  test('磁盘限制同时约束单插件、总字节和条目数', () async {
    final n = _png.length;
    cache = newCache(memory: 0, plugin: 2 * n, disk: 3 * n, count: 3);
    for (var i = 0; i < 5; i++) {
      await get(uri: _uri.replace(path: '/$i.png'));
      now = now.add(const Duration(seconds: 1));
    }
    expect(await cache.size(manifest.id), 2 * n);
    await get(as: other());
    await get(
      as: other(),
      uri: _uri.replace(path: '/other.png'),
    );
    expect(await cache.size(), 3 * n);
    cache = newCache(memory: 0, count: 1);
    await get(uri: _uri.replace(path: '/new.png'));
    expect(await cache.size(), n);
  });

  test('插件管理计入图片，清理和卸载仅删除当前插件的图片', () async {
    SharedPreferences.setMockInitialValues({});
    final store = MetaversePluginStore(
      preferences: await SharedPreferences.getInstance(),
      secretStore: InMemorySecretStore(),
      rootDirectory: () async => Directory(p.join(temp.path, 'data')),
      imageCache: cache,
    );
    final base = await store.localBytes(manifest.id);
    await get();
    await get(as: other());
    expect(await store.localBytes(manifest.id), base + _png.length);
    await store.resetData(manifest.id);
    expect(await cache.size(manifest.id), 0);
    await get();
    await store.deleteFiles(manifest.id);
    expect(await store.localBytes(manifest.id), 0);
    expect(await cache.size(other().id), _png.length);
  });

  test('遵守 Expires、Date、Age、上限和无效的新鲜度声明', () {
    DateTime? expiry(Map<String, String> h) =>
        PluginImageCache.freshUntil(h, now);
    expect(expiry({}), now.add(const Duration(hours: 24)));
    expect(
      expiry({'cache-control': 'max-age=31536000'}),
      now.add(const Duration(days: 7)),
    );
    expect(
      expiry({
        'date': HttpDate.format(now.subtract(const Duration(seconds: 10))),
        'cache-control': 'max-age=12',
      }),
      now.add(const Duration(seconds: 2)),
    );
    expect(
      expiry({'expires': HttpDate.format(now.add(const Duration(seconds: 9)))}),
      now.add(const Duration(seconds: 9)),
    );
    for (final h in [
      {'expires': '0'},
      {'age': '-2'},
      {'cache-control': 'max-age=one'},
      {'cache-control': 'max-age=6, max-age=9'},
    ]) {
      expect(expiry(h), isNull);
    }
  });
}
