import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../constants.dart';
import '../l10n/s.dart';
import '../services/toast_service.dart';
import 'platform_utils.dart';

/// Windows 链接分享菜单的用户选择。
enum _LinkShareChoice { copy, system }

/// 文件分享/保存结果。
///
/// [finalPath] 为用户最终保存位置（桌面端"另存为"的路径）；移动端通过系统
/// 分享面板时无法知道用户的目的地，[finalPath] 为 null 但 [shared] 为 true。
/// 用户取消时 [shared] 为 false 且 [finalPath] 为 null。
class ShareOutcome {
  const ShareOutcome({required this.shared, this.finalPath});

  final bool shared;
  final String? finalPath;
}

/// 分享链接工具类
class ShareUtils {
  /// 构建分享链接
  ///
  /// [path] 路径部分，如 `/t/topic/123` 或 `/u/username`
  /// [username] 当前用户名
  /// [anonymousShare] 是否匿名分享（不附带用户标识）
  static String buildShareUrl({
    required String path,
    String? username,
    required bool anonymousShare,
  }) {
    final base = '${AppConstants.baseUrl}$path';
    if (anonymousShare || username == null || username.isEmpty) {
      return base;
    }
    return '$base?u=$username';
  }

  /// 分享一条链接。
  ///
  /// Windows 的原生分享面板体验很差(还不带"复制链接"),这里在 Windows 上
  /// 先弹一个轻量菜单让用户在「复制链接 / 系统分享」间选择;其它平台维持
  /// 原样直接调用系统分享面板。
  static Future<void> shareLink(
    BuildContext context, {
    required String url,
    String? subject,
  }) async {
    if (!PlatformUtils.isWindows) {
      await SharePlus.instance.share(ShareParams(text: url, subject: subject));
      return;
    }

    final choice = await showDialog<_LinkShareChoice>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(S.current.common_share),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _LinkShareChoice.copy),
            child: Row(
              children: [
                const Icon(Icons.link_rounded, size: 20),
                const SizedBox(width: 12),
                Text(S.current.common_copyLink),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _LinkShareChoice.system),
            child: Row(
              children: [
                const Icon(Icons.ios_share_rounded, size: 20),
                const SizedBox(width: 12),
                Text(S.current.common_systemShare),
              ],
            ),
          ),
        ],
      ),
    );

    switch (choice) {
      case _LinkShareChoice.copy:
        await Clipboard.setData(ClipboardData(text: url));
        ToastService.show(S.current.common_linkCopied);
      case _LinkShareChoice.system:
        await SharePlus.instance.share(
          ShareParams(text: url, subject: subject),
        );
      case null:
        break; // 用户取消
    }
  }

  /// 分享或保存文件
  ///
  /// 桌面端弹出"另存为"对话框，移动端使用系统分享面板。
  /// 返回 [ShareOutcome]：桌面端 `finalPath` 为用户选择的最终路径，
  /// 移动端为 null（系统分享面板不暴露目的地）。
  static Future<ShareOutcome> shareOrSaveFile(
    XFile file, {
    String? subject,
  }) async {
    if (PlatformUtils.isDesktop) {
      return _saveFileDialog(file);
    }
    await SharePlus.instance.share(
      ShareParams(files: [file], subject: subject),
    );
    return const ShareOutcome(shared: true);
  }

  /// 桌面端"另存为"对话框
  static Future<ShareOutcome> _saveFileDialog(XFile file) async {
    final fileName = p.basename(file.path);
    final ext = p.extension(fileName).replaceFirst('.', '');

    final outputPath = await FilePicker.platform.saveFile(
      dialogTitle: S.current.share_selectSaveLocation,
      fileName: fileName,
      type: ext.isNotEmpty ? FileType.custom : FileType.any,
      allowedExtensions: ext.isNotEmpty ? [ext] : null,
    );

    if (outputPath == null) {
      return const ShareOutcome(shared: false);
    }

    try {
      final sourceFile = File(file.path);
      await sourceFile.copy(outputPath);
      ToastService.show(S.current.share_fileSaved);
      return ShareOutcome(shared: true, finalPath: outputPath);
    } catch (e) {
      debugPrint('[ShareUtils] saveFile failed: $e');
      ToastService.showError(S.current.share_saveFailed);
      return const ShareOutcome(shared: false);
    }
  }
}
