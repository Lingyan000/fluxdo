import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../constants.dart';
import '../l10n/s.dart';
import '../services/toast_service.dart';
import 'platform_utils.dart';

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

  /// 图片扩展名 → 标准 MIME 类型(jpg 的正确 MIME 是 image/jpeg;
  /// 直接拼 'image/$ext' 会得到非法类型,部分接收方不认)。
  static String imageMimeType(String ext) => switch (ext.toLowerCase()) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'avif' => 'image/avif',
        'heic' || 'heif' => 'image/heic',
        'bmp' => 'image/bmp',
        'svg' => 'image/svg+xml',
        'tif' || 'tiff' => 'image/tiff',
        _ => 'image/$ext',
      };

  /// 分享图片文件:复制为带可读文件名的临时文件再走系统分享/另存为。
  /// 命名回退链:[fileName](接口/cooked 提供的原始文件名)→ [urlHint]
  /// 末段 → `fluxdo_<毫秒时间戳>`;扩展名始终以 [ext](实际下载 URL)
  /// 为准,保证与字节格式一致。临时文件由 OS 按需清理。
  static Future<ShareOutcome> shareImageFile(
    File file, {
    required String ext,
    String? fileName,
    String? urlHint,
    String? subject,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final base = safeFileBaseName(fileName) ??
        safeFileBaseName(_urlLastSegment(urlHint)) ??
        'fluxdo_${DateTime.now().millisecondsSinceEpoch}';
    final shareFile = File(p.join(tempDir.path, 'share', '$base.$ext'));
    await shareFile.parent.create(recursive: true);
    await file.copy(shareFile.path);
    return shareOrSaveFile(
      XFile(shareFile.path, mimeType: imageMimeType(ext)),
      subject: subject,
    );
  }

  /// 分享/保存命名的文件名主干:去路径与扩展名、洗掉各平台非法字符
  /// (路径分隔/:`*?"<>|/控制字符 → 空格,连续空白压成单个);洗完为空
  /// 返回 null,交给调用方的下一级回退。
  static String? safeFileBaseName(String? name) {
    if (name == null) return null;
    var base = p.basenameWithoutExtension(name.trim());
    base = base
        .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    base = base.replaceFirst(RegExp(r'^\.+'), '').trim();
    if (base.isEmpty || base == '.' || base == '..') return null;
    return base;
  }

  /// URL 末段(命名回退用):空串/无路径返回 null。
  static String? _urlLastSegment(String? url) {
    if (url == null) return null;
    final segments = Uri.tryParse(url)?.pathSegments;
    if (segments == null || segments.isEmpty) return null;
    final last = segments.last.trim();
    return last.isEmpty ? null : last;
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
