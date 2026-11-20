import 'package:dio/dio.dart' as dio;
import 'package:flutter/foundation.dart';

import 'app_logger.dart';
import 'avif_sequence_still.dart';
import 'blob_image_cache.dart';
import 'dio_http_client.dart';

/// 表情缩略图的取图来源。
///
/// 面板格子只显示约 160px,而市场里多数表情是 2000px 级的原图(静态 AVIF、
/// JPEG 中位约 200KB,GIF 可达 MB 级),下载体积才是慢的根源。按以下顺序
/// 取图,任一级失败落到下一级:
///
/// 1. 展示地址:条目的 `displayUrl` 与原图不同时用它(通常是压缩版);
/// 2. 缩放代理:按目标尺寸缩放后的 WebP,体积小一到两个数量级;
/// 3. 动画 AVIF 首帧:Range 只下载主图项,见 [AvifSequenceStill];
/// 4. 完整原图。
///
/// 只服务缩略图首帧;长按预览与发送仍用原图。缩略图解码后以 PNG 落盘,
/// 所以每张表情最多走一次这条链路。
class StickerThumbnailSource {
  StickerThumbnailSource._();

  /// 缩放代理开关(设置项),由 [StickerMarketService] 同步。
  static bool proxyEnabled = true;

  /// 公共缩放代理(开源项目 weserv/images 提供的免费服务,可自建)。
  /// 服务方按访问者 IP 限制未命中缓存的请求,超限封禁一小时。
  static const String proxyEndpoint = 'https://wsrv.nl/';

  /// 首次 Range 读取的长度:覆盖文件头,动画 AVIF 的首帧多数也在其中。
  static const int _probeLength = 64 * 1024;

  /// 本次运行内代理处理失败的地址(例如代理读不了动画 AVIF),不再重试。
  static final Set<String> _proxyFailedUrls = {};

  /// 代理整体不可用(限流、服务端错误、网络不通)时暂停到此刻。
  static DateTime? _proxyPausedUntil;
  static int _proxyServiceFailures = 0;

  static DioHttpClient? _testClient;
  static DioHttpClient get _client => _testClient ?? DioHttpClient();

  static Uri proxyUri(String url, int size) => Uri.parse(
    '$proxyEndpoint?url=${Uri.encodeComponent(url)}'
    '&w=$size&h=$size&fit=inside&we&output=webp',
  );

  /// 取缩略图源字节(可能是缩放后的小图、首帧静态图或完整原图)。
  static Future<Uint8List> fetch({
    required String bucket,
    required String url,
    String? displayUrl,
    required int targetSize,
    required DownloadPriority Function() priority,
  }) async => (await fetchWithSource(
    bucket: bucket,
    url: url,
    displayUrl: displayUrl,
    targetSize: targetSize,
    priority: priority,
  )).bytes;

  /// 同 [fetch],并给出字节来自哪一级(诊断日志用):
  /// `cache` / `proxy` / `avifRange` / `original`。
  static Future<({Uint8List bytes, String source})> fetchWithSource({
    required String bucket,
    required String url,
    String? displayUrl,
    required int targetSize,
    required DownloadPriority Function() priority,
  }) async {
    final source =
        (displayUrl != null && displayUrl.isNotEmpty && displayUrl != url)
        ? displayUrl
        : url;

    // 原图已在缓存里(例如长按预览过)就直接用,不再走网络。
    final cached = await BlobImageCache.read(bucket, source);
    if (cached != null) return (bytes: cached, source: 'cache');

    if (_proxyUsable(source)) {
      try {
        final bytes = await _client.fetchBytes(
          proxyUri(source, targetSize),
          channel: DownloadChannel.stickerThumb,
          priority: priority(),
          // 代理偶发整条请求卡住(实测约 1/60 卡满 30s),不能让它长时间占槽
          callTimeout: const Duration(seconds: 8),
        );
        _proxyServiceFailures = 0;
        if (_looksLikeWebp(bytes)) return (bytes: bytes, source: 'proxy');
        // 200 但不是图片(例如错误页):按单张失败处理,继续往下取
        _proxyFailedUrls.add(source);
      } catch (e) {
        _onProxyFailure(source, e);
      }
    }

    if (_isAvifUrl(source)) {
      final bytes = await _fetchAvifSmart(bucket, source, priority);
      if (bytes != null) return (bytes: bytes, source: 'avifRange');
    }
    return (
      bytes: await BlobImageCache.fetch(bucket, source, priority: priority()),
      source: 'original',
    );
  }

  /// 把排队中的取源请求提到前台(同一张图先被预览条以普通优先级请求、
  /// 随后在预览页里可见时用)。在途与未排队的请求不受影响。
  static void bump(String url, String? displayUrl, int targetSize) {
    final source =
        (displayUrl != null && displayUrl.isNotEmpty && displayUrl != url)
        ? displayUrl
        : url;
    DioHttpClient.bumpPending(
      DownloadChannel.stickerThumb,
      proxyUri(source, targetSize).toString(),
    );
    DioHttpClient.bumpPending(DownloadChannel.stickerThumb, source);
  }

  static bool _proxyUsable(String url) {
    if (!proxyEnabled) return false;
    if (!url.startsWith('https://') && !url.startsWith('http://')) return false;
    if (_proxyFailedUrls.contains(url)) return false;
    final pausedUntil = _proxyPausedUntil;
    if (pausedUntil != null && DateTime.now().isBefore(pausedUntil)) {
      return false;
    }
    return true;
  }

  static void _onProxyFailure(String url, Object error) {
    final status = error is HttpStatusException ? error.statusCode : null;
    // 4xx(429 除外)是这张图本身代理不了,其它失败说明代理整体不可用。
    if (status != null && status >= 400 && status < 500 && status != 429) {
      _proxyFailedUrls.add(url);
      return;
    }
    final Duration pause;
    if (status == 429) {
      pause = const Duration(hours: 1);
    } else if (++_proxyServiceFailures >= 3) {
      pause = const Duration(minutes: 5);
    } else {
      return;
    }
    _proxyServiceFailures = 0;
    _proxyPausedUntil = DateTime.now().add(pause);
    AppLogger.warning(
      '表情缩略图代理暂停使用',
      tag: 'StickerThumb',
      fields: {
        'status': status,
        'pauseMinutes': pause.inMinutes,
        'error': error.toString(),
      },
    );
  }

  static bool _looksLikeWebp(Uint8List bytes) =>
      bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP';

  static bool _isAvifUrl(String url) {
    try {
      return Uri.parse(url).path.toLowerCase().endsWith('.avif');
    } catch (_) {
      return false;
    }
  }

  /// AVIF 按 Range 分段取:动画只下载首帧;静态图把剩余部分补齐成完整
  /// 文件(顺带写入原图缓存,探测的那一段不浪费)。服务端不支持 Range
  /// 或任何一步对不上都返回 null,由调用方完整下载。
  static Future<Uint8List?> _fetchAvifSmart(
    String bucket,
    String url,
    DownloadPriority Function() priority,
  ) async {
    try {
      final head = await _fetchRange(url, 0, _probeLength - 1, priority);
      if (head == null) return null;
      if (!head.partial) {
        // 服务端忽略 Range,返回的就是完整文件
        await BlobImageCache.write(bucket, url, head.bytes);
        return head.bytes;
      }
      final total = head.total;
      if (total == null || head.start != 0) return null;
      var bytes = head.bytes;
      if (bytes.length >= total) {
        await BlobImageCache.write(bucket, url, bytes);
        return bytes;
      }

      final needed = AvifSequenceStill.requiredLength(bytes);
      if (needed != null && needed <= total) {
        if (needed > bytes.length) {
          final rest = await _fetchRange(
            url,
            bytes.length,
            needed - 1,
            priority,
          );
          if (rest == null || rest.start != bytes.length) return null;
          bytes = _concat(bytes, rest.bytes);
        }
        final still = AvifSequenceStill.toStill(bytes);
        if (still != null) return still;
      }

      // 静态 AVIF(或结构不认识):补齐剩余部分
      final rest = await _fetchRange(
        url,
        bytes.length,
        total - 1,
        priority,
        channel: DownloadChannel.sticker,
      );
      if (rest == null || rest.start != bytes.length) return null;
      final full = _concat(bytes, rest.bytes);
      if (full.length != total) return null;
      await BlobImageCache.write(bucket, url, full);
      return full;
    } catch (e) {
      debugPrint('[StickerThumbnailSource] Range 取图失败 $url: $e');
      return null;
    }
  }

  static Future<_RangeResult?> _fetchRange(
    String url,
    int start,
    int end,
    DownloadPriority Function() priority, {
    DownloadChannel channel = DownloadChannel.stickerThumb,
  }) async {
    var status = 0;
    String? contentRange;
    final bytes = await _client.fetchBytes(
      Uri.parse(url),
      channel: channel,
      priority: priority(),
      headers: {'Range': 'bytes=$start-$end', 'Accept-Encoding': 'identity'},
      onHead: (code, dio.Headers headers) {
        status = code;
        contentRange = headers.value('content-range');
      },
    );
    if (status == 200) {
      return _RangeResult(bytes, partial: false, start: 0, total: bytes.length);
    }
    final parsed = parseContentRange(contentRange);
    if (parsed == null) return null;
    final (rangeStart, rangeEnd, total) = parsed;
    if (rangeEnd - rangeStart + 1 != bytes.length) return null;
    return _RangeResult(bytes, partial: true, start: rangeStart, total: total);
  }

  /// 解析 `bytes start-end/total`;total 为 `*` 时返回 null 的 total。
  @visibleForTesting
  static (int, int, int?)? parseContentRange(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$')
        .firstMatch(value.trim());
    if (match == null) return null;
    return (
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.tryParse(match.group(3)!),
    );
  }

  static Uint8List _concat(Uint8List a, Uint8List b) {
    final out = Uint8List(a.length + b.length);
    out.setRange(0, a.length, a);
    out.setRange(a.length, out.length, b);
    return out;
  }

  @visibleForTesting
  static void resetForTesting({DioHttpClient? client}) {
    _testClient = client;
    proxyEnabled = true;
    _proxyFailedUrls.clear();
    _proxyPausedUntil = null;
    _proxyServiceFailures = 0;
  }
}

class _RangeResult {
  const _RangeResult(
    this.bytes, {
    required this.partial,
    required this.start,
    required this.total,
  });

  final Uint8List bytes;
  final bool partial;
  final int start;
  final int? total;
}
