import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/s.dart';
import '../../../services/toast_service.dart';
import 'metaverse_plugin_file_queue.dart';
import 'metaverse_plugin_file_reader.dart';
import 'metaverse_plugin_installer.dart';
import 'providers/metaverse_plugin_providers.dart';
import 'ui/metaverse_plugin_dialogs.dart';

/// 系统文件入口复用插件安装器和权限确认界面。
class MetaversePluginFileService {
  MetaversePluginFileService._();
  static final instance = MetaversePluginFileService._();
  static const _channel = MethodChannel('com.fluxdo/plugin_files');
  final _queue = MetaversePluginFileQueue(
    onConsumed: (uri) => unawaited(_releaseFile(uri)),
    onError: (error, _) {
      ToastService.showError(
        S.current.metaverse_pluginInstallFailed(error.toString()),
      );
    },
  );
  BuildContext? _context;
  bool _started = false;

  static Future<void> _releaseFile(Uri uri) async {
    if (!Platform.isIOS && !Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<void>('releaseFile', uri.toString());
    } on PlatformException catch (error) {
      debugPrint('[PluginFiles] ${error.code}');
    } on MissingPluginException {
      // 旧 runner 热重启时没有文件授权通道。
    }
  }

  void initialize(List<String> arguments) {
    if (_started) return;
    _started = true;
    for (final argument in arguments) {
      final uri = fileArgument(argument, windows: Platform.isWindows);
      if (uri != null) _queue.add(uri);
    }
    if (Platform.isWindows ||
        Platform.isLinux ||
        Platform.isIOS ||
        Platform.isMacOS) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'filesAvailable') await _takeNativeFiles();
      });
      unawaited(_takeNativeFiles());
    }
  }

  Future<void> _takeNativeFiles() async {
    try {
      final paths = await _channel.invokeListMethod<String>('takePendingFiles');
      for (final path in paths ?? <String>[]) {
        final uri = fileArgument(path, windows: Platform.isWindows);
        if (uri != null) _queue.add(uri);
      }
    } on MissingPluginException {
      // 热重启可能仍使用尚未包含文件入口的旧 runner。
    } on PlatformException catch (error) {
      debugPrint('[PluginFiles] ${error.code}');
    }
  }

  static Uri? fileArgument(String value, {required bool windows}) {
    final isFileUri = value.toLowerCase().startsWith('file:');
    if (!isFileUri && !value.toLowerCase().endsWith('.fluxplugin')) return null;
    final Uri? uri;
    try {
      uri = isFileUri ? Uri.tryParse(value) : Uri.file(value, windows: windows);
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
    if (uri == null ||
        uri.scheme != 'file' ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.toLowerCase().endsWith('.fluxplugin')) {
      return null;
    }
    return uri;
  }

  bool handleUri(Uri uri) {
    // Android 文档提供器常用不带文件名的 content URI，平台层核对显示名称。
    if (Platform.isAndroid && uri.scheme == 'content') {
      _queue.add(uri);
      return true;
    }
    if (uri.scheme != 'file' ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.toLowerCase().endsWith('.fluxplugin')) {
      return false;
    }
    // Apple 原生入口保留带授权的 URL，并通过平台队列交付全部文件。
    if (Platform.isIOS || Platform.isMacOS) return true;
    _queue.add(uri);
    return true;
  }

  void attach(BuildContext context) {
    _context = context;
    _queue.attach((uri) => _install(context, uri));
  }

  void detach(BuildContext context) {
    if (!identical(_context, context)) return;
    _context = null;
    _queue.detach();
  }

  Future<bool> _install(BuildContext context, Uri uri) async {
    if (!context.mounted) return false;
    final container = ProviderScope.containerOf(context, listen: false);
    final installer = MetaversePluginInstaller(
      network: container.read(metaversePluginNetworkProvider),
      reservedHosts: container.read(metaversePluginStoreProvider).reservedHosts,
    );
    final package = await installer.importBundle(
      MetaversePluginFileReader.read(uri),
    );
    if (!context.mounted) return false;
    final controller = container.read(metaversePluginsProvider.notifier);
    final confirmed = await showMetaversePluginInstallSheet(
      context,
      package.manifest,
      isUpdate: controller.byId(package.manifest.id) != null,
    );
    if (!confirmed) return true;
    await controller.install(package);
    ToastService.showSuccess(
      S.current.metaverse_pluginInstalled(package.manifest.name),
    );
    return true;
  }
}
