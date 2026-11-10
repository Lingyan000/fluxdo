import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'update_service.dart';

enum WindowsUpdateStage { downloading, verifying }

enum WindowsUpdateFailure { missingChecksum, invalidChecksum, sizeMismatch }

class WindowsUpdateException implements Exception {
  final WindowsUpdateFailure reason;
  const WindowsUpdateException(this.reason);
}

/// 下载与安装分开，只有校验成功的文件才能交给安装器。
class WindowsUpdateDownload {
  final Directory _directory;
  final File installer;

  WindowsUpdateDownload._(this._directory, this.installer);

  Future<void> delete() async {
    if (await _directory.exists()) await _directory.delete(recursive: true);
  }
}

class WindowsUpdateService {
  static const _channel = MethodChannel('com.fluxdo/windows_update');
  final Dio _dio;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<String> Function() _githubProxy;

  static void _checkCancelled(CancelToken token) {
    if (token.isCancelled) throw token.cancelError!;
  }

  WindowsUpdateService({
    Dio? dio,
    Future<Directory> Function()? temporaryDirectory,
    Future<String> Function()? githubProxy,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 30),
               receiveTimeout: const Duration(minutes: 2),
             ),
           ),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _githubProxy = githubProxy ?? UpdateService.getGithubProxy;

  /// 注册表中的安装目录必须与当前程序一致，便携版不自动转成安装版。
  static Future<bool> isInstalled() async {
    if (!Platform.isWindows) return false;
    try {
      return await _channel.invokeMethod<bool>('isInstalled') ?? false;
    } on MissingPluginException {
      // 热重载未包含新的原生桥时，仍可手动更新。
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<WindowsUpdateDownload> download(
    WindowsUpdateAsset asset, {
    required CancelToken cancelToken,
    required void Function(WindowsUpdateStage stage, double? progress)
    onProgress,
  }) async {
    Directory? directory;
    try {
      final proxy = await _githubProxy();
      _checkCancelled(cancelToken);
      String? expected = asset.sha256;
      if (expected == null) {
        if (asset.sha256Url == null) {
          throw const WindowsUpdateException(
            WindowsUpdateFailure.missingChecksum,
          );
        }
        final response = await _dio.get<String>(
          UpdateService.applyGithubProxy(asset.sha256Url!, proxy),
          cancelToken: cancelToken,
          options: Options(responseType: ResponseType.plain),
        );
        expected = (response.data ?? '').trim().split(RegExp(r'\s+')).first;
      }
      if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expected)) {
        throw const WindowsUpdateException(
          WindowsUpdateFailure.invalidChecksum,
        );
      }
      _checkCancelled(cancelToken);
      final root = await _temporaryDirectory();
      await root.create(recursive: true);
      directory = await root.createTemp('fluxdo-update-');
      // 不使用远端文件名构造路径；每次下载使用独立目录，避免复用残缺文件。
      final installer = File(p.join(directory.path, 'fluxdo-setup.exe'));
      onProgress(WindowsUpdateStage.downloading, null);
      await _dio.download(
        UpdateService.applyGithubProxy(asset.downloadUrl, proxy),
        installer.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) => onProgress(
          WindowsUpdateStage.downloading,
          total > 0 ? (received / total).clamp(0.0, 1.0) : null,
        ),
      );
      _checkCancelled(cancelToken);
      onProgress(WindowsUpdateStage.verifying, null);
      if (asset.size > 0 && await installer.length() != asset.size) {
        throw const WindowsUpdateException(WindowsUpdateFailure.sizeMismatch);
      }
      final digest = await sha256
          .bind(
            installer.openRead().map((chunk) {
              _checkCancelled(cancelToken);
              return chunk;
            }),
          )
          .first;
      _checkCancelled(cancelToken);
      if (digest.toString() != expected.toLowerCase()) {
        throw const WindowsUpdateException(
          WindowsUpdateFailure.invalidChecksum,
        );
      }
      return WindowsUpdateDownload._(directory, installer);
    } catch (_) {
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
      rethrow;
    }
  }

  /// 安装器准备就绪后关闭当前窗口；取消 UAC 或安装失败时应用继续运行。
  static Future<void> install(WindowsUpdateDownload download) async {
    await _channel.invokeMethod<void>('startUpdate', download.installer.path);
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final exitCode = await _channel.invokeMethod<int>('getUpdateExitCode');
      if (exitCode != null) {
        // 成功更新会退出本进程。仍在运行表示交接没有完成，不能报告成功。
        throw PlatformException(
          code: 'installer_exited',
          message: 'Installer exited before application shutdown ($exitCode).',
        );
      }
    }
  }
}
