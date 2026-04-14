import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../constants.dart';
import '../l10n/s.dart';
import '../services/toast_service.dart';
import 'platform_utils.dart';

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

  /// 分享或保存文件
  ///
  /// 桌面端弹出"另存为"对话框，移动端使用系统分享面板
  static Future<void> shareOrSaveFile(
    XFile file, {
    String? subject,
  }) async {
    if (PlatformUtils.isDesktop) {
      await _saveFileDialog(file);
    } else {
      await SharePlus.instance.share(
        ShareParams(files: [file], subject: subject),
      );
    }
  }

  /// 桌面端"另存为"对话框
  static Future<void> _saveFileDialog(XFile file) async {
    final fileName = p.basename(file.path);
    final ext = p.extension(fileName).replaceFirst('.', '');

    final outputPath = await FilePicker.platform.saveFile(
      dialogTitle: S.current.share_selectSaveLocation,
      fileName: fileName,
      type: ext.isNotEmpty ? FileType.custom : FileType.any,
      allowedExtensions: ext.isNotEmpty ? [ext] : null,
    );

    if (outputPath == null) return;

    try {
      final sourceFile = File(file.path);
      await sourceFile.copy(outputPath);
      ToastService.show(S.current.share_fileSaved);
    } catch (e) {
      debugPrint('[ShareUtils] saveFile failed: $e');
      ToastService.showError(S.current.share_saveFailed);
    }
  }
}
