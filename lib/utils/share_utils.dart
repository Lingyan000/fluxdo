import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../constants.dart';
import '../l10n/s.dart';
import '../services/download_service.dart';
import '../services/public_file_channel.dart';
import '../services/toast_service.dart';
import 'platform_utils.dart';

/// 文件分享/保存结果。
///
/// [finalPath] 为用户最终保存位置；移动端通过系统分享面板时无法知道用户的
/// 目的地，[finalPath] 为 null 但 [shared] 为 true。用户取消时 [shared]
/// 为 false 且 [finalPath] 为 null。
///
/// Android 落公共目录（MediaStore / SAF 另存为）时 [finalPath] 是 content
/// uri 而非文件路径，见 [isContentUri]：这类引用不能用 `File()` 打开，
/// 要走 [PublicFileChannel.openUri]。
/// [displayName] 是文件最终落盘的名字，仅用于提示文案（MediaStore 遇同名
/// 会自动加序号，所以未必等于请求的名字）。
class ShareOutcome {
  const ShareOutcome({required this.shared, this.finalPath, this.displayName});

  final bool shared;
  final String? finalPath;
  final String? displayName;

  /// [finalPath] 是 Android content uri 而非可 `File()` 打开的路径。
  bool get isContentUri => finalPath?.startsWith('content://') ?? false;
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

  /// 分享/导出用的中转文件目录名（在 `getTemporaryDirectory()` 下）。
  static const String _kOutboxDir = 'outbox';

  /// 保留时长：超过这个时间的中转文件在下次写入时被清掉。
  static const Duration _kOutboxTtl = Duration(days: 1);

  /// 建一个「待送出」的临时文件（分享面板的中转、落盘前的产物）。
  ///
  /// 这些文件既不属于图片缓存的分类统计、也不在「清理缓存」的口径里，此前散落
  /// 在 temp 根目录与 temp/share 下只增不减；统一收进一个目录并在每次写入前
  /// 清掉过期件，避免长期占着「其它数据」。
  static Future<File> createOutboxFile(String fileName) async {
    final tempDir = await getTemporaryDirectory();
    final dir = Directory(p.join(tempDir.path, _kOutboxDir));
    await dir.create(recursive: true);
    await _pruneOutbox(dir);
    return File(p.join(dir.path, fileName));
  }

  static Future<void> _pruneOutbox(Directory dir) async {
    try {
      final deadline = DateTime.now().subtract(_kOutboxTtl);
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (stat.modified.isBefore(deadline)) {
          await entity.delete().catchError((_) => entity);
        }
      }
    } catch (e) {
      // 清理是尽力而为，失败不该挡住这次分享
      debugPrint('[ShareUtils] prune outbox failed: $e');
    }
  }

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
    final base = safeFileBaseName(fileName) ??
        safeFileBaseName(_urlLastSegment(urlHint)) ??
        'fluxdo_${DateTime.now().millisecondsSinceEpoch}';
    final shareFile = await createOutboxFile('$base.$ext');
    await file.copy(shareFile.path);
    return ShareUtils.shareFile(
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

  /// 当前平台能否走系统分享面板发送文件。
  ///
  /// Linux 上 share_plus 只支持文本（分享文件会抛 UnimplementedError），
  /// 因此该平台的入口应隐藏"分享"，只留"保存"。
  static bool get canShareFiles => kIsWeb || !Platform.isLinux;

  /// 走系统分享面板发送文件（不落地保存）。
  ///
  /// 与 [saveFile] 的分工：本方法只负责"发出去"，落地保存是另一个动作。
  /// Linux 上不可用，入口需先看 [canShareFiles]。
  static Future<ShareOutcome> shareFile(XFile file, {String? subject}) async {
    await SharePlus.instance.share(
      ShareParams(files: [file], subject: subject),
    );
    return const ShareOutcome(shared: true);
  }

  /// 把文件落地保存到本机的「公共」位置。
  ///
  /// - 桌面：弹"另存为"由用户选位置；
  /// - Android 10+：MediaStore 静默写入公共「下载」目录（零权限、卸载不删），
  ///   [ShareOutcome.finalPath] 是 content uri；Android 9 及以下没有该集合，
  ///   回退到应用私有下载目录（系统文件管理器里不可达，只能在应用内取用）；
  /// - iOS：沙盒里没有对外可见的落点（`getDownloadsDirectory` 返回的是
  ///   `Library/Downloads`，而 UIFileSharingEnabled 只暴露 Documents，那里
  ///   躺着数据库/cookie/日志，不能整目录暴露），因此转交 [saveFileAs] 走
  ///   系统导出面板让用户挑位置。
  ///
  /// 成功提示交给调用方（各入口的成功文案不同），失败提示在此统一给出。
  static Future<ShareOutcome> saveFile(XFile file) async {
    if (PlatformUtils.isDesktop) {
      return _saveFileDialog(file, showSuccessToast: false);
    }
    if (PublicFileChannel.isSupported) {
      try {
        final saved = await PublicFileChannel.saveToDownloads(
          sourcePath: file.path,
          fileName: p.basename(file.path),
        );
        if (saved != null) {
          return ShareOutcome(
            shared: true,
            finalPath: saved.uri,
            displayName: saved.displayName,
          );
        }
        // null = 系统版本没有 MediaStore.Downloads 集合，落到私有目录分支
        return _saveToAppDownloads(file);
      } catch (e) {
        debugPrint('[ShareUtils] saveToDownloads failed, fallback: $e');
        return _saveToAppDownloads(file);
      }
    }
    return saveFileAs(file);
  }

  /// 「另存为」：让用户自己挑位置。
  ///
  /// - Android：SAF 建档（返回 content uri，已持久化授权，可长期打开）；
  /// - iOS：UIDocumentPicker 导出（file_picker 在移动端要求传 bytes）；
  /// - 桌面：与 [saveFile] 同为"另存为"对话框，所以桌面端不必单独暴露该入口。
  ///
  /// 返回 `shared == false` 表示用户取消。
  static Future<ShareOutcome> saveFileAs(XFile file) async {
    if (PlatformUtils.isDesktop) {
      return _saveFileDialog(file, showSuccessToast: false);
    }
    final fileName = p.basename(file.path);
    if (PublicFileChannel.isSupported) {
      try {
        final saved = await PublicFileChannel.saveAs(
          sourcePath: file.path,
          fileName: fileName,
        );
        if (saved == null) return const ShareOutcome(shared: false);
        return ShareOutcome(
          shared: true,
          // iOS 导出面板的落点在沙盒外，拿不到长期可读的引用，只回名字
          finalPath: saved.uri.isEmpty ? null : saved.uri,
          displayName: saved.displayName.isEmpty ? fileName : saved.displayName,
        );
      } catch (e) {
        // 原生腿不可用（未注册/旧版本）才落到下面的 file_picker
        debugPrint('[ShareUtils] native saveAs unavailable, fallback: $e');
      }
    }
    // 兜底：file_picker 的移动端 saveFile 必须带 bytes（大文件有内存尖峰，
    // 所以只在原生腿走不通时用）
    try {
      final ext = p.extension(fileName).replaceFirst('.', '');
      final outputPath = await FilePicker.platform.saveFile(
        dialogTitle: S.current.share_selectSaveLocation,
        fileName: fileName,
        bytes: await File(file.path).readAsBytes(),
        type: ext.isNotEmpty ? FileType.custom : FileType.any,
        allowedExtensions: ext.isNotEmpty ? [ext] : null,
      );
      if (outputPath == null) return const ShareOutcome(shared: false);
      // iOS 侧落点在应用沙盒外，返回值长期不保证可读，只当提示用，
      // 不作为可打开的引用交给导出历史。
      return ShareOutcome(shared: true, displayName: fileName);
    } catch (e) {
      debugPrint('[ShareUtils] saveFileAs (picker) failed: $e');
      ToastService.showError(S.current.share_saveFailed);
      return const ShareOutcome(shared: false);
    }
  }

  /// 回退路径：写入应用自己的下载目录（与下载功能同一目录）。
  static Future<ShareOutcome> _saveToAppDownloads(XFile file) async {
    try {
      final dir = await DownloadService.resolveDownloadDirectory();
      final reservation = DownloadService.reserveAvailableDownload(
        directory: dir,
        fileName: p.basename(file.path),
      );
      try {
        await File(file.path).copy(reservation.temporaryPath);
        await reservation.commit();
      } catch (e) {
        await reservation.release();
        rethrow;
      }
      return ShareOutcome(
        shared: true,
        finalPath: reservation.savePath,
        displayName: p.basename(reservation.savePath),
      );
    } catch (e) {
      debugPrint('[ShareUtils] saveFile to app downloads failed: $e');
      ToastService.showError(S.current.share_saveFailed);
      return const ShareOutcome(shared: false);
    }
  }

  /// 桌面端"另存为"对话框
  static Future<ShareOutcome> _saveFileDialog(
    XFile file, {
    bool showSuccessToast = true,
  }) async {
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
      if (showSuccessToast) ToastService.show(S.current.share_fileSaved);
      return ShareOutcome(
        shared: true,
        finalPath: outputPath,
        displayName: p.basename(outputPath),
      );
    } catch (e) {
      debugPrint('[ShareUtils] saveFile failed: $e');
      ToastService.showError(S.current.share_saveFailed);
      return const ShareOutcome(shared: false);
    }
  }
}
