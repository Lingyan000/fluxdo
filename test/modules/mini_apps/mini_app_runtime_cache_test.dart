import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_runtime_cache.dart';

void main() {
  late Directory directory;
  late MiniAppRuntimeCache cache;
  String digest(String source) =>
      sha256.convert(utf8.encode(source)).toString();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'mini-app-runtime-cache-',
    );
    cache = MiniAppRuntimeCache(directory: () async => directory);
  });
  tearDown(() => directory.delete(recursive: true));

  test('新建运行器可复用缓存，内容被修改或哈希不符时拒绝使用', () async {
    const source = 'export const version = "1.0.0";';
    final hash = digest(source);
    expect(await cache.read(hash), isNull);
    expect(await cache.write(hash, source), true);
    final reopened = MiniAppRuntimeCache(directory: () async => directory);
    expect(await reopened.read(hash), source);
    expect(await reopened.write(hash, '$source changed'), false);
    expect(await reopened.read(hash), source);
    await File('${directory.path}/mini_app_runtime/$hash.js')
        .writeAsString('changed');
    expect(await reopened.read(hash), isNull);
    expect(await reopened.read('../other'), isNull);
    expect(await reopened.write('../other', source), false);
  });

  test('并发写入保留三个运行器版本，并限制桥接操作与文件大小', () async {
    final sources = List.generate(
      4,
      (index) => 'export const version = $index;',
    );
    expect(
      await Future.wait(
        sources.map((source) => cache.write(digest(source), source)),
      ),
      everyElement(true),
    );
    final files = await Directory('${directory.path}/mini_app_runtime')
        .list()
        .toList();
    expect(files.where((file) => file.path.endsWith('.js')), hasLength(3));
    expect(await cache.read(digest(sources.last)), sources.last);
    expect(
      await cache.handle({'action': 'fetch', 'hash': digest(sources.last)}),
      isNull,
    );
    expect(
      await cache.handle({
        'action': 'write',
        'hash': digest(sources.last),
        'source': 1,
      }),
      isNull,
    );
    expect(
      await cache.write(
        digest('large'),
        'x' * (MiniAppRuntimeCache.maxBytes + 1),
      ),
      false,
    );
  });

  test('缓存目录暂不可用后仍能恢复写入', () async {
    final blocker = File('${directory.path}/blocked');
    await blocker.writeAsString('');
    var available = false;
    final recovering = MiniAppRuntimeCache(
      directory: () async => available ? directory : Directory(blocker.path),
    );
    const source = 'export const ready = true;';
    expect(await recovering.write(digest(source), source), false);
    available = true;
    expect(await recovering.write(digest(source), source), true);
    expect(await recovering.read(digest(source)), source);
  });
}
