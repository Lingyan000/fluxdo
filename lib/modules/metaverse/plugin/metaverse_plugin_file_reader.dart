import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 移动端和 Apple 文件授权由平台读取，桌面普通路径使用受安装器限流的流。
class MetaversePluginFileReader {
  static const channel = MethodChannel('com.fluxdo/plugin_files');

  static Stream<List<int>> read(Uri uri) async* {
    if (uri.scheme == 'content' ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      final bytes = await channel.invokeMethod<Uint8List>(
        'readFile',
        uri.toString(),
      );
      if (bytes == null) throw const FormatException('无法读取插件文件');
      yield bytes;
      return;
    }
    yield* File.fromUri(uri).openRead();
  }
}
