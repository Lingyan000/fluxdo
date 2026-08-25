import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// 透明模式背景图的文件管理。
///
/// 用户选图后**复制**进应用私有目录，绝不引用相册原始 URI——
/// iOS 的 ph:// 与 Android 的 content:// 授权都会失效，重启后图就丢了。
/// 文件不做转码压缩，显示侧用 cacheWidth 限制解码尺寸（见
/// app_background_layer.dart），省去引入图片压缩依赖。
class AppBackgroundService {
  AppBackgroundService._();

  static const _dirName = 'backgrounds';
  static const _filePrefix = 'app_background_';

  static Future<Directory> _backgroundDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/$_dirName');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 拉起相册选图并复制进私有目录，返回新文件路径；用户取消返回 null。
  ///
  /// 文件名带时间戳：同路径替换会被 ImageCache 旧条目命中，
  /// 唯一文件名是最简单的缓存规避。
  static Future<String?> importFromGallery() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return null;

    final dir = await _backgroundDir();
    final ext = picked.path.contains('.')
        ? picked.path.substring(picked.path.lastIndexOf('.'))
        : '.jpg';
    final target = File(
      '${dir.path}/$_filePrefix${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    await File(picked.path).copy(target.path);
    return target.path;
  }

  /// 删除旧背景文件（换新图后调用；文件已不存在时静默跳过）。
  static Future<void> delete(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
      }
    } on FileSystemException {
      // 删除失败不影响主流程，残留文件随清缓存自然淘汰
    }
  }
}
