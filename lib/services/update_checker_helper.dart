import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/apk_update_provider.dart';
import '../utils/dialog_utils.dart';
import '../widgets/download_progress_dialog.dart';
import '../widgets/update_dialog.dart';
import '../widgets/windows_update_dialog.dart';
import 'update_service.dart';
import 'macos_update_service.dart';
import 'windows_update_service.dart';

/// 更新检查助手类
///
/// 负责处理自动更新检查的 UI 逻辑
class UpdateCheckerHelper {
  static bool _windowsUpdateOpen = false;

  /// 在应用启动时自动检查更新
  ///
  /// 如果发现新版本，会显示更新对话框
  static Future<void> checkUpdateOnStartup(
    BuildContext context,
    UpdateService updateService,
  ) async {
    final updateInfo = await updateService.autoCheckUpdate();
    if (updateInfo != null && context.mounted) {
      if (Platform.isMacOS &&
          await MacOSUpdateService.isVersionSkipped(updateInfo.remoteVersion)) {
        return;
      }
      if (!context.mounted) return;
      await _showAutoUpdateDialog(context, updateInfo, updateService);
    }
  }

  /// 处理用户点击"立即更新"后的下载/跳转逻辑
  ///
  /// Android / Windows 安装版及 macOS 使用应用内更新。
  static Future<void> handleUpdate(
    BuildContext context,
    UpdateInfo updateInfo,
  ) async {
    if (Platform.isAndroid) {
      await _startInAppDownload(context, updateInfo);
    } else if (Platform.isWindows) {
      await _startWindowsUpdate(context, updateInfo);
    } else if (Platform.isMacOS) {
      if (!await MacOSUpdateService.checkForUpdates()) {
        _openInBrowser(updateInfo.releaseUrl);
      }
    } else {
      _openInBrowser(updateInfo.releaseUrl);
    }
  }

  static Future<void> _startWindowsUpdate(
    BuildContext context,
    UpdateInfo updateInfo,
  ) async {
    if (_windowsUpdateOpen) return;
    _windowsUpdateOpen = true;
    try {
      final asset = updateInfo.windowsAsset;
      if (asset == null ||
          !asset.canVerify ||
          !await WindowsUpdateService.isInstalled()) {
        _openInBrowser(updateInfo.releaseUrl);
        return;
      }
      if (!context.mounted) return;
      await showAppDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => WindowsUpdateDialog(
          asset: asset,
          releaseUrl: updateInfo.releaseUrl,
        ),
      );
    } finally {
      _windowsUpdateOpen = false;
    }
  }

  /// 显示自动更新对话框
  static Future<void> _showAutoUpdateDialog(
    BuildContext context,
    UpdateInfo updateInfo,
    UpdateService updateService,
  ) {
    return showAppDialog<void>(
      context: context,
      builder: (dialogContext) => UpdateDialog(
        updateInfo: updateInfo,
        onUpdate: () {
          Navigator.of(dialogContext).pop();
          handleUpdate(context, updateInfo);
        },
        onCancel: () => Navigator.of(dialogContext).pop(),
        onIgnore: () {
          updateService.setAutoCheckUpdate(false);
          Navigator.of(dialogContext).pop();
        },
        onOpenReleasePage: () {
          Navigator.of(dialogContext).pop();
          _openInBrowser(updateInfo.releaseUrl);
        },
      ),
    );
  }

  /// 启动应用内下载（通过 Riverpod provider 进入全局状态）
  static Future<void> _startInAppDownload(
    BuildContext context,
    UpdateInfo updateInfo,
  ) async {
    final updateService = UpdateService();
    final apkAsset = await updateService.getMatchingApkAsset(updateInfo);

    if (apkAsset == null) {
      _openInBrowser(updateInfo.releaseUrl);
      return;
    }

    if (!context.mounted) return;

    final container = ProviderScope.containerOf(context);
    await container.read(apkUpdateProvider.notifier).start(apkAsset);

    if (!context.mounted) return;

    showAppDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const DownloadProgressDialog(),
    );
  }

  /// 在浏览器中打开
  static void _openInBrowser(String url) {
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}
