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

/// 图片的内容寻址文件缓存(Telegram ImageLoader 形态)。
///
/// ## 为什么不用 flutter_cache_manager
///
/// cache_manager 每张图的热路径 = sqlite SELECT(url→相对路径)→
/// File.exists → 读文件,还要 touch 回写维护 LRU。表情面板 200 张同屏
/// = 200 次串行查询,这层索引本身就是延迟来源(为此已被迫做过
/// ThrottledCacheObjectProvider 节流补丁);正文图侧 500 条 LRU 上限
/// 让两三个图密话题就互相挤兑重下。
///
/// Telegram 的收敛形态(源码实证)是**零数据库**:
/// - 寻址:HTTP 图 = `MD5(url)` 确定性文件名,给定 URL 纯函数算路径
///   (ImageLoader.getHttpFilePath);FilePathDatabase 只是"文件被移出
///   缓存目录"的例外覆盖表,图片显示热路径不查库;
/// - 淘汰:每 24h 节流扫描 listFiles + stat 时间戳,按保留期删旧
///   (AutoDeleteMediaTask);容量上限 = 按时间戳排序从旧裁剪
///   (cache_limit),无 per-file LRU 记录。
/// **文件系统本身就是索引,时间戳本身就是 LRU。**
///
/// ## 覆盖面(2026-07 起全量,flutter_cache_manager 退役)
///
/// 小图(emoji/头像/贴纸缩略)与大图(正文/原图/贴纸原文件/外部图)
/// 全部走这里,按 bucket 分池:保留期各异 + 大图 bucket 另设字节上限,
/// 查看器原图(多 MB)不再与正文图挤兑。下载进度经 [fetch] 的
/// onProgress 上报(替代 cache_manager 的 DownloadProgress 流)。
class BlobImageCache {
  BlobImageCache._();

  /// 根目录名(Temporary 下),也是数据管理页统计/清理的口径。
  static const String dirName = 'blobImageCache';

  /// bucket → 保留期。沿用被替换的各 cache manager 的 stalePeriod 语义。
  static const Map<String, Duration> buckets = {
    emojiBucket: Duration(days: 90),
    avatarBucket: Duration(days: 30),
    stickerThumbBucket: Duration(days: 90),
    contentBucket: Duration(days: 7),
    originalBucket: Duration(days: 7),
    stickerOriginalBucket: Duration(days: 90),
    externalBucket: Duration(days: 30),
  };

  /// 大图 bucket 的字节上限(TG cache_limit 式:sweep 时按 mtime 从旧
  /// 裁剪到上限内)。小图 bucket 域有界(emoji ~3k×5KB)不设上限。
  static const Map<String, int> bucketByteLimits = {
    contentBucket: 1 << 30, // 1 GB
    originalBucket: 512 << 20, // 512 MB
    stickerOriginalBucket: 1 << 30, // 1 GB
    externalBucket: 256 << 20, // 256 MB
  };

  static const String emojiBucket = 'emoji';
  static const String avatarBucket = 'avatar';
  static const String stickerThumbBucket = 'stickerThumb';

  /// 正文 optimized 图(cooked src / srcset 选档结果)。
  static const String contentBucket = 'content';

  /// 查看器原图(lightbox href)。与 content 分池:多 MB 原图的容量
  /// 压力不波及正文图。
  static const String originalBucket = 'original';

  /// 贴纸原文件(Rust 解码管线的 bytes 来源)。
  static const String stickerOriginalBucket = 'stickerOriginal';

  /// 第三方图(mermaid.ink / GitHub 等,无 Discourse 鉴权语义)。
  static const String externalBucket = 'external';

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
  ///
  /// [onProgress] 下载字节进度(received, total;total 可能为 null ——
  /// 无 content-length)。缓存命中不回调;同 key 并发时**只有首个调用
  /// 方的回调生效**(共享同一下载,进度语义按首发方)。
  static Future<Uint8List> fetch(
    String bucket,
    String url, {
    DownloadPriority priority = DownloadPriority.normal,
    void Function(int received, int? total)? onProgress,
  }) async {
    final cached = await read(bucket, url);
    if (cached != null) return cached;

    final inflightKey = '$bucket|$url';
    return _inflight[inflightKey] ??=
        _download(bucket, url, priority, onProgress).whenComplete(() {
      _inflight.remove(inflightKey);
    });
  }

  /// 按 bucket 选下载通道:emoji(KB 级,RTT 主导)走 12 槽 small
  /// 高并发;贴纸原文件(面板预取型大动图)独立 3 槽防饿死内容;
  /// 其余(正文/头像/原图/外部)走 6 槽 content。
  static DownloadChannel _channelOf(String bucket) => switch (bucket) {
        emojiBucket => DownloadChannel.small,
        stickerOriginalBucket => DownloadChannel.sticker,
        _ => DownloadChannel.content,
      };

  /// 视野优先级信号(Telegram bumpPriority 同款语义):
  /// [bump] = 图片首帧 paint(真进视口)→ 排队中的请求插到高优队列;
  /// [sink] = widget dispose(滚出视口)→ 沉回低优队尾给新视野让路。
  /// 在途 HTTP 不动 —— 下完写盘即缓存,取消是白扔投资。两者幂等。
  static void bump(String bucket, String url) =>
      DioHttpClient.bumpPending(_channelOf(bucket), url);

  static void sink(String bucket, String url) =>
      DioHttpClient.sinkPending(_channelOf(bucket), url);

  static Future<Uint8List> _download(
    String bucket,
    String url,
    DownloadPriority priority,
    void Function(int received, int? total)? onProgress,
  ) async {
    final bytes = await DioHttpClient().fetchBytes(
      Uri.parse(url),
      channel: _channelOf(bucket),
      priority: priority,
      onProgress: onProgress,
    );
    if (bytes.isEmpty) {
      throw HttpException('BlobImageCache: empty body for $url',
          uri: Uri.parse(url));
    }
    await write(bucket, url, bytes);
    return bytes;
  }

  /// 读缓存,miss 则下载,返回**缓存文件**(需要 File 语义的调用方:
  /// 贴纸 Rust 管线、保存/分享)。文件由 fetch 落盘,路径确定性。
  static Future<File> getFile(
    String bucket,
    String url, {
    void Function(int received, int? total)? onProgress,
  }) async {
    await fetch(bucket, url, onProgress: onProgress);
    return _fileFor(bucket, url);
  }

  /// 仅查缓存是否已存在(不下载)。预取跳过判断用。
  static Future<bool> contains(String bucket, String url) async {
    final file = await _fileFor(bucket, url);
    return file.exists();
  }

  /// 预取:已缓存/在途则跳过,否则下载落盘。错误静默(预取尽力而为)。
  static Future<void> precache(String bucket, String url) async {
    try {
      if (_inflight.containsKey('$bucket|$url')) return;
      if (await contains(bucket, url)) return;
      await fetch(bucket, url);
    } catch (e) {
      debugPrint('[BlobImageCache] precache 失败 $url: $e');
    }
  }

  /// 节流 touch:更新 mtime 供 [sweep] 判活。fire-and-forget,失败无害
  /// (最坏情况 = 常用文件被当旧文件删掉,下次重新下载)。
  static void _touch(File file) {
    if (!_touched.add(file.path)) return;
    unawaited(
      file.setLastModified(DateTime.now()).catchError((Object _) {}),
    );
  }

  /// 淘汰扫描:按 bucket 保留期删 mtime 过期文件 + 大图 bucket 超出
  /// 字节上限时按 mtime 从旧裁剪(Telegram AutoDeleteMediaTask +
  /// cache_limit 同款)。prefs 时间戳节流每 24h 一次;调用方应在首帧后
  /// 空闲时机触发。扫描/删除整体放 [Isolate.run],主 isolate 零负担。
  static Future<void> sweep(SharedPreferences prefs) async {
    const stampKey = 'blob_image_cache_last_sweep';
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = prefs.getInt(stampKey) ?? 0;
    if (now - last < const Duration(hours: 24).inMilliseconds) return;
    await prefs.setInt(stampKey, now);

    final root = await _ensureRoot();
    final rootPath = root.path;
    // const map 复制成局部量传进 isolate。
    final retention = Map<String, Duration>.of(buckets);
    final byteLimits = Map<String, int>.of(bucketByteLimits);
    try {
      final deleted = await Isolate.run(() async {
        var count = 0;
        final nowTime = DateTime.now();
        for (final entry in retention.entries) {
          final dir = Directory('$rootPath/${entry.key}');
          if (!dir.existsSync()) continue;

          // Pass 1: 按保留期删过期 + 清 .tmp 残骸;顺带收集存活文件。
          final alive = <({String path, DateTime mtime, int size})>[];
          for (final f in dir.listSync()) {
            if (f is! File) continue;
            try {
              final stat = f.statSync();
              final age = nowTime.difference(stat.modified);
              final isTmp = f.path.endsWith('.tmp');
              if (age > entry.value ||
                  (isTmp && age > const Duration(days: 1))) {
                f.deleteSync();
                count++;
              } else if (!isTmp) {
                alive.add(
                    (path: f.path, mtime: stat.modified, size: stat.size));
              }
            } catch (_) {}
          }

          // Pass 2: 字节上限裁剪(从旧到新删,直到落回上限内)。
          final limit = byteLimits[entry.key];
          if (limit == null) continue;
          var total = alive.fold<int>(0, (a, f) => a + f.size);
          if (total <= limit) continue;
          alive.sort((a, b) => a.mtime.compareTo(b.mtime));
          for (final f in alive) {
            if (total <= limit) break;
            try {
              File(f.path).deleteSync();
              total -= f.size;
              count++;
            } catch (_) {}
          }
        }
        return count;
      });
      if (deleted > 0) {
        debugPrint('[BlobImageCache] sweep 删除 $deleted 个过期/超限文件');
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
  const BlobImageProvider(
    this.url, {
    required this.bucket,
    this.scale = 1.0,
    this.priority = DownloadPriority.normal,
  });

  final String url;
  final String bucket;
  final double scale;

  /// 初始下载优先级(用户主动打开的查看器传 high;正文/面板图默认
  /// normal,靠首帧 paint 的 [BlobImageCache.bump] 动态提级)。
  /// **刻意不参与 == / hashCode**:优先级是调度提示,不是图片身份,
  /// 参与相等性会让同 URL 的 high/normal 各解码一份。
  final DownloadPriority priority;

  @override
  Future<BlobImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<BlobImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    BlobImageProvider key,
    ImageDecoderCallback decode,
  ) {
    // chunkEvents 驱动 Image.loadingBuilder / LazyImage 的确定值进度环
    // (与 CachedNetworkImageProvider 的 DownloadProgress 流同语义)。
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode, chunkEvents),
      chunkEvents: chunkEvents.stream,
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
    StreamController<ImageChunkEvent> chunkEvents,
  ) async {
    try {
      final bytes = await BlobImageCache.fetch(
        key.bucket,
        key.url,
        priority: key.priority,
        onProgress: (received, total) {
          if (chunkEvents.isClosed) return;
          chunkEvents.add(ImageChunkEvent(
            cumulativeBytesLoaded: received,
            expectedTotalBytes: total,
          ));
        },
      );
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return await decode(buffer);
    } catch (e) {
      // 失败结果不能留在 ImageCache,否则同 key 后续 Image 永久裂图
      // (与 cached_image.dart 的 evict 兜底同语义)。
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      unawaited(chunkEvents.close());
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
