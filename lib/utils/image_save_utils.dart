import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../l10n/s.dart';
import '../services/toast_service.dart';
import 'platform_utils.dart';
import 'share_utils.dart';

/// 「把这张图交给用户」的统一出口。
///
/// 平台分工：
/// - 移动端 → 系统相册（gal）；
/// - 桌面端 → 另存为对话框存成文件。桌面用户对「保存图片」的预期是自己选
///   目录而不是塞进系统图片库；更关键的是 **gal 没有 Linux 实现**（pubspec
///   只声明 android/ios/macos/windows），在 Linux 上调用会抛
///   `MissingPluginException`，走文件对话框才能五端齐活。
///
/// 提示文案由本类统一给出（成功/失败/权限），各入口只需要拿返回值更新自己的
/// loading 状态，避免同一个动作在不同页面弹出不同措辞。
abstract final class ImageSaveUtils {
  /// 当前平台「保存图片」的动作文案：桌面「保存图片」/ 移动「保存到相册」。
  static String get actionLabel => PlatformUtils.isDesktop
      ? S.current.share_saveImageToFile
      : S.current.share_saveToGallery;

  /// 保存图片字节。返回是否成功落地（用户取消 = false，且不弹任何提示）。
  ///
  /// [fileName] 需带扩展名，如 `foo.png`；为空时用时间戳兜底。
  static Future<bool> saveBytes(
    Uint8List bytes, {
    required String fileName,
  }) async {
    if (bytes.isEmpty) {
      ToastService.showError(S.current.image_fetchFailed);
      return false;
    }
    final safeName = _resolveFileName(fileName);
    return PlatformUtils.isDesktop
        ? _saveAsFile(bytes, safeName)
        : _saveToGallery(bytes, safeName);
  }

  /// 桌面：写临时文件再走另存为对话框（失败提示由 ShareUtils 给出）。
  static Future<bool> _saveAsFile(Uint8List bytes, String fileName) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final file = File(p.join(tempDir.path, fileName));
      await file.writeAsBytes(bytes);
      final ext = p.extension(fileName).replaceFirst('.', '');
      final outcome = await ShareUtils.saveFile(
        XFile(file.path, mimeType: ShareUtils.imageMimeType(ext)),
      );
      if (outcome.shared) ToastService.showSuccess(S.current.share_fileSaved);
      return outcome.shared;
    } catch (e) {
      debugPrint('[ImageSaveUtils] saveAsFile failed: $e');
      ToastService.showError(S.current.share_saveFailed);
      return false;
    }
  }

  /// 移动端：存进系统相册。
  static Future<bool> _saveToGallery(Uint8List bytes, String fileName) async {
    try {
      if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
        ToastService.showInfo(S.current.imageViewer_grantPermission);
        return false;
      }
      await Gal.putImageBytes(bytes, name: fileName);
      ToastService.showSuccess(S.current.share_imageSaved);
      return true;
    } on GalException catch (e) {
      debugPrint('[ImageSaveUtils] GalException: ${e.type.message}');
      ToastService.showError(S.current.imageViewer_saveFailed(e.type.message));
      return false;
    } catch (e) {
      debugPrint('[ImageSaveUtils] saveToGallery failed: $e');
      ToastService.showError(S.current.share_saveFailed);
      return false;
    }
  }

  /// 洗干净文件名并保证带扩展名。
  static String _resolveFileName(String fileName) {
    final base =
        ShareUtils.safeFileBaseName(fileName) ??
        'fluxdo_${DateTime.now().millisecondsSinceEpoch}';
    final ext = p.extension(fileName).replaceFirst('.', '');
    return ext.isEmpty ? '$base.png' : '$base.$ext';
  }
}
