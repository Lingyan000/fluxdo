import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dio_http_client.dart';

/// 小图专用的内容寻址文件缓存(Telegram ImageLoader 形态)。
///
/// ## 为什么不用 flutter_cache_manager
///
/// cache_manager 每张图的热路径 = sqlite SELECT(url→相对路径)→
/// File.exists → 读文件,还要 touch 回写维护 LRU。表情面板 200 张同屏
/// = 200 次串行查询,这层索引本身就是延迟来源(为此已被迫做过
/// ThrottledCacheObjectProvider 节流补丁)。
///
/// Telegram 的收敛形态(源码实证)是**零数据库**:
/// - 寻址:HTTP 图 = `MD5(url)` 确定性文件名,给定 URL 纯函数算路径
///   (ImageLoader.getHttpFilePath);FilePathDatabase 只是"文件被移出
///   缓存目录"的例外覆盖表,图片显示热路径不查库;
/// - 淘汰:每 24h 节流扫描 listFiles + stat 时间戳,按保留期删旧
///   (AutoDeleteMediaTask),无 per-file LRU 记录。
/// **文件系统本身就是索引,时间戳本身就是 LRU。**
///
/// ## 适用边界
///
/// 只服务"小而多、URL 稳定、不需下载进度"的图:emoji / 头像 / 贴纸
/// 缩略图。正文大图仍走 DiscourseCacheManager —— 那里需要下载进度、
/// secure-uploads、部分下载语义,且单屏数量少,索引开销无感;与
/// Telegram"大媒体走 FileLoader 全套、小图 MD5 直寻址"的分层一致。
class BlobImageCache {
  BlobImageCache._();

  /// 根目录名(Temporary 下),也是数据管理页统计/清理的口径。
  static const String dirName = 'blobImageCache';

  /// bucket → 保留期。沿用被替换的各 cache manager 的 stalePeriod 语义。
  static const Map<String, Duration> buckets = {
    emojiBucket: Duration(days: 90),
    avatarBucket: Duration(days: 30),
    stickerThumbBucket: Duration(days: 90),
  };

  static const String emojiBucket = 'emoji';
  static const String avatarBucket = 'avatar';
  static const String stickerThumbBucket = 'stickerThumb';

  static Directory? _root;
  static Future<Directory>? _rootFuture;

  /// 同 key 在途下载去重。
  static final Map<String, Future<Uint8List>> _inflight = {};

  /// 本会话已 touch 过的文件,每 key 只 touch 一次(给淘汰扫描供
  /// 时间戳;mtime 精度要求是"天"级,会话内重复 touch 纯浪费 IO)。
  static final Set<String> _touched = {};

  static Future<Directory> _ensureRoot() =>
      _rootFuture ??= (() async {
        final tmp = await getTemporaryDirectory();
        final dir = Directory('${tmp.path}/$dirName');
        await dir.create(recursive: true);
        _root = dir;
        return dir;
      })();

  /// 确定性寻址:bucket 目录 + md5(key)。无扩展名 —— Flutter codec 按
  /// magic bytes 嗅探格式,SVG 探测也读文件头,都不依赖后缀。
  static Future<File> _fileFor(String bucket, String key) async {
    final root = _root ?? await _ensureRoot();
    return File('${root.path}/$bucket/${md5.convert(utf8.encode(key))}');
  }

  /// 只读缓存:命中返回字节,miss 返回 null。不做 exists 预检 ——
  /// 直接读,读失败即 miss(省一次 stat)。
  static Future<Uint8List?> read(String bucket, String key) async {
    final file = await _fileFor(bucket, key);
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      _touch(file);
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  /// 写入缓存:临时文件 + 原子 rename(Telegram `_temp` 同款),
  /// 半截文件永远不会出现在正式路径上。
  static Future<void> write(String bucket, String key, Uint8List bytes) async {
    final file = await _fileFor(bucket, key);
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[BlobImageCache] write 失败 $bucket/$key: $e');
    }
  }

  /// 读缓存,miss 则下载并落盘。同 key 并发调用共享同一个下载 future。
  ///
  /// 下载走 [DioHttpClient](主域带 cookie / CDN 不带的双 dio 语义 +
  /// 全局 8 并发信号量,与 cache_manager 时代同一条网络路径)。
  static Future<Uint8List> fetch(String bucket, String url) async {
    final cached = await read(bucket, url);
    if (cached != null) return cached;

    final inflightKey = '$bucket|$url';
    return _inflight[inflightKey] ??= _download(bucket, url).whenComplete(() {
      _inflight.remove(inflightKey);
    });
  }

  static Future<Uint8List> _download(String bucket, String url) async {
    final response = await DioHttpClient().get(Uri.parse(url));
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      throw HttpException(
        'BlobImageCache: HTTP ${response.statusCode} for $url',
        uri: Uri.parse(url),
      );
    }
    final bytes = response.bodyBytes;
    await write(bucket, url, bytes);
    return bytes;
  }

  /// 节流 touch:更新 mtime 供 [sweep] 判活。fire-and-forget,失败无害
  /// (最坏情况 = 常用文件被当旧文件删掉,下次重新下载)。
  static void _touch(File file) {
    if (!_touched.add(file.path)) return;
    unawaited(
      file.setLastModified(DateTime.now()).catchError((Object _) {}),
    );
  }

  /// 淘汰扫描:按 bucket 保留期删除 mtime 过期文件(Telegram
  /// AutoDeleteMediaTask 同款)。prefs 时间戳节流每 24h 一次;调用方
  /// 应在首帧后空闲时机触发。扫描/删除整体放 [Isolate.run],主 isolate
  /// 零负担。
  static Future<void> sweep(SharedPreferences prefs) async {
    const stampKey = 'blob_image_cache_last_sweep';
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = prefs.getInt(stampKey) ?? 0;
    if (now - last < const Duration(hours: 24).inMilliseconds) return;
    await prefs.setInt(stampKey, now);

    final root = await _ensureRoot();
    final rootPath = root.path;
    // buckets 是 const,复制成局部量传进 isolate。
    final retention = Map<String, Duration>.of(buckets);
    try {
      final deleted = await Isolate.run(() async {
        var count = 0;
        final nowTime = DateTime.now();
        for (final entry in retention.entries) {
          final dir = Directory('$rootPath/${entry.key}');
          if (!dir.existsSync()) continue;
          for (final f in dir.listSync()) {
            if (f is! File) continue;
            try {
              final stat = f.statSync();
              final age = nowTime.difference(stat.modified);
              // .tmp 残骸(写一半被杀)超过 1 天也一并清。
              final isTmp = f.path.endsWith('.tmp');
              if (age > entry.value || (isTmp && age > const Duration(days: 1))) {
                f.deleteSync();
                count++;
              }
            } catch (_) {}
          }
        }
        return count;
      });
      if (deleted > 0) {
        debugPrint('[BlobImageCache] sweep 删除 $deleted 个过期文件');
      }
    } catch (e) {
      debugPrint('[BlobImageCache] sweep 失败: $e');
    }
  }

  /// 清空单个 bucket(数据管理页分类清理)。
  static Future<void> clearBucket(String bucket) async {
    final root = await _ensureRoot();
    final dir = Directory('${root.path}/$bucket');
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('[BlobImageCache] clearBucket $bucket 失败: $e');
    }
    _touched.removeWhere((p) => p.startsWith(dir.path));
  }

  /// 清空全部 blob 缓存(清缓存入口)。
  static Future<void> clearAll() async {
    final root = await _ensureRoot();
    try {
      if (await root.exists()) await root.delete(recursive: true);
      await root.create(recursive: true);
    } catch (e) {
      debugPrint('[BlobImageCache] clearAll 失败: $e');
    }
    _touched.clear();
  }
}

/// [BlobImageCache] 的 ImageProvider 门面。
///
/// 解码走 [PaintingBinding.instantiateImageCodecWithSize] 标准回调 →
/// 自动纳入解码闸门的尺寸分档(小图旁路 / 大图过闸)。
@immutable
class BlobImageProvider extends ImageProvider<BlobImageProvider> {
  const BlobImageProvider(this.url, {required this.bucket, this.scale = 1.0});

  final String url;
  final String bucket;
  final double scale;

  @override
  Future<BlobImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<BlobImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    BlobImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: 'BlobImageProvider(${key.url})',
      informationCollector: () => [
        DiagnosticsProperty<String>('URL', key.url),
        DiagnosticsProperty<String>('Bucket', key.bucket),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    BlobImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    try {
      final bytes = await BlobImageCache.fetch(key.bucket, key.url);
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return await decode(buffer);
    } catch (e) {
      // 失败结果不能留在 ImageCache,否则同 key 后续 Image 永久裂图
      // (与 cached_image.dart 的 evict 兜底同语义)。
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is BlobImageProvider &&
        other.url == url &&
        other.bucket == bucket &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(url, bucket, scale);

  @override
  String toString() => 'BlobImageProvider("$url", bucket: $bucket)';
}
