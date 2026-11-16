import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 只供本机 H3 探针使用的独立环境，不复用业务 profile 或修改系统根证书。
class WindowsH3ProbeEnvironment {
  WindowsH3ProbeEnvironment._(this.environment, this.directory);

  final WebViewEnvironment environment;
  final Directory directory;
  Future<void>? _disposing;

  static String arguments(int port, String spki) {
    if (port < 1 ||
        port > 65535 ||
        base64Decode(spki).length != 32 ||
        base64Encode(base64Decode(spki)) != spki) {
      throw const FormatException('Invalid local H3 probe identity');
    }
    return '--origin-to-force-quic-on=localhost:$port '
        '--ignore-certificate-errors-spki-list=$spki '
        '--host-resolver-rules="MAP localhost 127.0.0.1"';
  }

  static Future<WindowsH3ProbeEnvironment> create({
    required int port,
    required String spki,
    required Future<void> cancelled,
    Duration timeout = const Duration(seconds: 15),
    @visibleForTesting
    Future<WebViewEnvironment> Function(WebViewEnvironmentSettings)? factory,
    @visibleForTesting Directory? temporaryRoot,
  }) async {
    // 在创建文件或原生环境前拒绝缺失、损坏和可注入命令行的指纹。
    final flags = arguments(port, spki);
    var stopped = false;
    unawaited(cancelled.then((_) => stopped = true));
    final directory = await (temporaryRoot ?? Directory.systemTemp).createTemp(
      'fluxdo-h3-',
    );
    if (stopped) {
      await _remove(directory);
      throw StateError('H3 probe cancelled');
    }
    final pending = Future<WebViewEnvironment>.sync(
      () =>
          (factory ??
          ((settings) => WebViewEnvironment.create(settings: settings)))(
            WebViewEnvironmentSettings(
              userDataFolder: directory.path,
              additionalBrowserArguments: flags,
            ),
          ),
    );
    try {
      final environment = await Future.any([
        pending,
        cancelled.then<WebViewEnvironment>(
          (_) => throw StateError('H3 probe cancelled'),
        ),
      ]).timeout(timeout);
      return WindowsH3ProbeEnvironment._(environment, directory);
    } catch (_) {
      // 平台调用无法取消；迟到的结果也必须回收，不能落入下一代探针。
      unawaited(
        pending
            .then(
              (environment) async {
                await WindowsH3ProbeEnvironment._(
                  environment,
                  directory,
                ).dispose();
              },
              onError: (Object _, StackTrace _) async {
                await _remove(directory);
              },
            )
            .catchError((Object error) {
              debugPrint('[Fingerprint] H3 迟到环境清理失败: $error');
            }),
      );
      rethrow;
    }
  }

  /// 调用方必须先销毁该环境的探针控制器；此处不会触及主 WebView 环境。
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    final released = environment.dispose();
    // 原生销毁超时后仍等待真正释放再清理，避免删除仍被使用的 profile。
    final cleaned = released.then((_) => _remove(directory));
    try {
      await cleaned.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      unawaited(
        cleaned.catchError((Object error) {
          debugPrint('[Fingerprint] H3 环境延迟清理失败: $error');
        }),
      );
    }
  }

  static Future<void> _remove(Directory directory) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 3) {
          debugPrint('[Fingerprint] H3 临时目录仍被原生进程占用');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }
}

/// 原生控制器在 run 返回前尚未注册，提前 dispose 会直接返回而留下迟到的控制器。
/// 超时只结束调用方的等待，实际资源仍按创建完成、控制器销毁、环境销毁的顺序回收。
Future<void> disposeProbeResources({
  required Future<void>? started,
  required Future<void> Function() disposeView,
  Future<void> Function()? disposeEnvironment,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final cleanup = () async {
    try { await started; } catch (_) { /* 创建失败也继续回收已分配的资源。 */ }
    try { await disposeView(); }
    finally { await disposeEnvironment?.call(); }
  }();
  try {
    await cleanup.timeout(timeout);
  } on TimeoutException {
    unawaited(cleanup.catchError((Object error) {
      debugPrint('[Fingerprint] 迟到探针清理失败: $error');
    }));
  }
}
