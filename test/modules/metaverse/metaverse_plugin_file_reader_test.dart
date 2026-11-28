import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_file_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(MetaversePluginFileReader.channel, null);
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    test('授权文件通过平台读取并保留字节 $platform', () async {
      debugDefaultTargetPlatformOverride = platform;
      final uri = Uri.parse(
        platform == TargetPlatform.android
            ? 'content://documents/document/123'
            : 'file:///Documents/%E6%8F%92%E4%BB%B6.fluxplugin',
      );
      messenger.setMockMethodCallHandler(MetaversePluginFileReader.channel, (
        call,
      ) async {
        expect(call.method, 'readFile');
        expect(call.arguments, uri.toString());
        return Uint8List.fromList([1, 2, 3]);
      });
      expect(await MetaversePluginFileReader.read(uri).single, [1, 2, 3]);
    });
  }

  test('平台拒绝权限时向安装队列传播错误', () async {
    messenger.setMockMethodCallHandler(MetaversePluginFileReader.channel, (
      _,
    ) async {
      throw PlatformException(code: 'plugin_file_read', message: 'denied');
    });
    await expectLater(
      MetaversePluginFileReader.read(Uri.parse('content://documents/1'))
          .drain<void>(),
      throwsA(isA<PlatformException>()),
    );
  });

  test('桌面文件使用本地流，中文、空格及井号路径可读取', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final dir = await Directory.systemTemp.createTemp('fluxdo_plugin_file_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/插件 #1.fluxplugin');
    await file.writeAsBytes([1, 2, 3]);
    final bytes = await MetaversePluginFileReader.read(file.uri)
        .expand((value) => value)
        .toList();
    expect(bytes, [1, 2, 3]);
  });
}
