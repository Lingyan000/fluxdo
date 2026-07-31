import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../discourse_cache_manager.dart';

/// 图片缓存分类(Telegram Storage Usage 式明细的口径)。
///
/// 每类聚合一个或多个磁盘目录;`other` 兜底迁移 `.trash` 待删区与
/// 已废弃的 legacy 目录。
enum ImageCacheCategory {
  content,
  emoji,
  avatar,
  sticker,
  external,
  other,
}

/// 缓存大小计算服务
class CacheSizeService {
  /// 统计/删除口径:blob 缓存根目录 + legacy cache_manager 残留目录
  /// (v9 迁移后为空,防被杀断残留)。都在 `getTemporaryDirectory()` 下。
  static const _cacheKeys = [
    BlobImageCache.dirName,
    ...kLegacyImageCacheKeys,
  ];

  /// 计算图片缓存大小（遍历三个 CacheManager 的磁盘目录）
  ///
  /// flutter_cache_manager 将缓存存储在 `getTemporaryDirectory()/{key}` 下。
  /// 迁移产生的 `*.trash` 待删目录也计入 —— 后台清扫前的窗口期里它们
  /// 仍占磁盘,不算进来会出现"明明占几百 MB 却显示无缓存"。
  static Future<int> getImageCacheSize() async {
    final tempDir = await getTemporaryDirectory();
    int totalSize = 0;
    for (final key in _cacheKeys) {
      totalSize += await _getDirectorySize(Directory('${tempDir.path}/$key'));
    }
    for (final dir in await _trashDirs(tempDir)) {
      totalSize += await _getDirectorySize(dir);
    }
    return totalSize;
  }

  /// 按分类统计图片缓存大小(六类并行)。
  static Future<Map<ImageCacheCategory, int>> getImageCacheBreakdown() async {
    final tempDir = await getTemporaryDirectory();
    final t = tempDir.path;
    const blob = BlobImageCache.dirName;

    Future<int> dirsSize(List<String> paths) async {
      var total = 0;
      for (final p in paths) {
        total += await _getDirectorySize(Directory(p));
      }
      return total;
    }

    Future<int> otherSize() async {
      var total = 0;
      for (final key in kLegacyImageCacheKeys) {
        total += await _getDirectorySize(Directory('$t/$key'));
      }
      for (final dir in await _trashDirs(tempDir)) {
        total += await _getDirectorySize(dir);
      }
      return total;
    }

    final results = await Future.wait([
      dirsSize([
        '$t/$blob/${BlobImageCache.contentBucket}',
        '$t/$blob/${BlobImageCache.originalBucket}',
      ]),
      dirsSize(['$t/$blob/${BlobImageCache.emojiBucket}']),
      dirsSize(['$t/$blob/${BlobImageCache.avatarBucket}']),
      dirsSize([
        '$t/$blob/${BlobImageCache.stickerOriginalBucket}',
        '$t/$blob/${BlobImageCache.stickerThumbBucket}',
      ]),
      dirsSize(['$t/$blob/${BlobImageCache.externalBucket}']),
      otherSize(),
    ]);
    return {
      ImageCacheCategory.content: results[0],
      ImageCacheCategory.emoji: results[1],
      ImageCacheCategory.avatar: results[2],
      ImageCacheCategory.sticker: results[3],
      ImageCacheCategory.external: results[4],
      ImageCacheCategory.other: results[5],
    };
  }

  /// 按分类清除图片缓存。
  static Future<void> clearImageCacheCategory(
    ImageCacheCategory category,
  ) async {
    final tempDir = await getTemporaryDirectory();

    Future<void> deleteDir(String key) async {
      final dir = Directory('${tempDir.path}/$key');
      if (await dir.exists()) await dir.delete(recursive: true);
    }

    switch (category) {
      case ImageCacheCategory.content:
        await BlobImageCache.clearBucket(BlobImageCache.contentBucket);
        await BlobImageCache.clearBucket(BlobImageCache.originalBucket);
      case ImageCacheCategory.emoji:
        await BlobImageCache.clearBucket(BlobImageCache.emojiBucket);
      case ImageCacheCategory.avatar:
        await BlobImageCache.clearBucket(BlobImageCache.avatarBucket);
      case ImageCacheCategory.sticker:
        await BlobImageCache.clearBucket(BlobImageCache.stickerOriginalBucket);
        await BlobImageCache.clearBucket(BlobImageCache.stickerThumbBucket);
      case ImageCacheCategory.external:
        await BlobImageCache.clearBucket(BlobImageCache.externalBucket);
      case ImageCacheCategory.other:
        for (final key in kLegacyImageCacheKeys) {
          await deleteDir(key);
        }
        for (final dir in await _trashDirs(tempDir)) {
          try {
            await dir.delete(recursive: true);
          } catch (_) {}
        }
    }
  }

  /// 计算 AI 聊天数据大小（SharedPreferences 中 ai_chat_ 开头的 key）
  static Future<int> getAiChatDataSize(SharedPreferences prefs) async {
    int totalSize = 0;
    for (final key in prefs.getKeys()) {
      if (key.startsWith('ai_chat_')) {
        final value = prefs.get(key);
        if (value is String) {
          totalSize += value.length * 2; // UTF-16 编码估算
        } else if (value is List<String>) {
          for (final item in value) {
            totalSize += item.length * 2;
          }
        }
      }
    }
    return totalSize;
  }

  /// 计算 Cookie 缓存大小（.cookies 目录）
  static Future<int> getCookieCacheSize() async {
    final docDir = await getApplicationDocumentsDirectory();
    return _getDirectorySize(Directory('${docDir.path}/.cookies'));
  }

  /// 递归计算目录大小
  static Future<int> _getDirectorySize(Directory dir) async {
    if (!await dir.exists()) return 0;
    int totalSize = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        totalSize += await entity.length();
      }
    }
    return totalSize;
  }

  /// 删除图片缓存目录
  ///
  /// emptyCache() 只清除了 CacheManager 追踪的条目，
  /// 磁盘上的文件可能残留，需要直接删除整个目录来彻底清理。
  /// 迁移遗留的 `*.trash` 待删目录一并删(用户主动清缓存 = 立即释放,
  /// 不等后台清扫)。
  static Future<void> deleteImageCacheDirs() async {
    final tempDir = await getTemporaryDirectory();
    for (final key in _cacheKeys) {
      final dir = Directory('${tempDir.path}/$key');
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
    for (final dir in await _trashDirs(tempDir)) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Temporary 下迁移产生的 `*.trash` 待删目录。
  static Future<List<Directory>> _trashDirs(Directory tempDir) async {
    final result = <Directory>[];
    try {
      await for (final e in tempDir.list()) {
        if (e is Directory && e.path.endsWith('.trash')) {
          result.add(e);
        }
      }
    } catch (_) {}
    return result;
  }

  /// 格式化字节为可读字符串
  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
