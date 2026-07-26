import 'package:flutter/material.dart';
import '../../../pages/image_viewer_page.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../utils/url_helper.dart';

/// 画廊信息类
/// 同时保存缩略图 URL（用于匹配）和原图 URL（用于显示）
///
/// 从 HTML 提取画廊信息请使用 [HtmlParseService.parseSync] 或
/// [HtmlParseService.parse] 拿到 ParsedHtml,再访问 `parsed.galleryInfo`。
/// 直接从图片列表构造请使用 [fromImages]。
class GalleryInfo {
  /// 原图 URL 列表（用于画廊显示）
  final List<String> originalUrls;

  /// 每张图片的文件名列表（来自 lightbox title，可能为 null）
  final List<String?> filenames;

  /// 缩略图 URL 到索引的映射（用于快速查找）
  final Map<String, int> _thumbnailToIndex;

  /// spoiler 内的图片 URL 集合（揭示前不在画廊中显示）
  final Set<String> _spoilerImageUrls;

  GalleryInfo._({
    required this.originalUrls,
    required Map<String, int> thumbnailToIndex,
    List<String?>? filenames,
    Set<String>? spoilerImageUrls,
  })  : _thumbnailToIndex = thumbnailToIndex,
        filenames = filenames ?? List.filled(originalUrls.length, null),
        _spoilerImageUrls = spoilerImageUrls ?? {};

  /// 获取指定索引的文件名
  String? getFilename(int index) {
    if (index >= 0 && index < filenames.length) return filenames[index];
    return null;
  }

  /// 获取可见图片的索引列表（排除未揭示 spoiler 中的图片）
  /// [revealedImageUrls] 为已揭示的 spoiler 图片 URL 集合
  List<int> getVisibleIndices(Set<String> revealedImageUrls) {
    if (_spoilerImageUrls.isEmpty) {
      return List.generate(originalUrls.length, (i) => i);
    }
    return [
      for (int i = 0; i < originalUrls.length; i++)
        if (!_spoilerImageUrls.contains(originalUrls[i]) ||
            revealedImageUrls.contains(originalUrls[i]))
          i,
    ];
  }

  /// 从已解析的画廊原始字段构造 GalleryInfo。
  ///
  /// 配合 [HtmlParseService]: isolate 内解析 DOM 抽出原始字段后,
  /// 主 isolate 用 [UrlHelper] 解析 URL 后调用此构造。
  static GalleryInfo fromParsedEntries({
    required List<String> originalUrls,
    required Map<String, int> thumbnailToIndex,
    required List<String?> filenames,
    required Set<String> spoilerImageUrls,
  }) {
    return GalleryInfo._(
      originalUrls: originalUrls,
      thumbnailToIndex: thumbnailToIndex,
      filenames: filenames,
      spoilerImageUrls: spoilerImageUrls,
    );
  }

  /// 从外部传入的图片列表构建 GalleryInfo
  /// [spoilerImageUrls] 可选，标记哪些图片在 spoiler 内
  static GalleryInfo fromImages(List<String> images, {Set<String>? spoilerImageUrls}) {
    final Map<String, int> thumbnailToIndex = {};

    for (var i = 0; i < images.length; i++) {
      final url = images[i];
      thumbnailToIndex[url] = i;
      // 同时添加原图 URL 作为 key
      final originalUrl = DiscourseImageUtils.getOriginalUrl(url);
      if (originalUrl != url) {
        thumbnailToIndex[originalUrl] = i;
      }
    }

    return GalleryInfo._(
      originalUrls: images,
      thumbnailToIndex: thumbnailToIndex,
      spoilerImageUrls: spoilerImageUrls,
    );
  }

  /// 根据任意格式的图片 URL 查找索引
  /// 会尝试多种 URL 变体匹配
  int? findIndex(String imageUrl) {
    // 1. 直接查找
    if (_thumbnailToIndex.containsKey(imageUrl)) {
      return _thumbnailToIndex[imageUrl];
    }
    
    // 2. 尝试 resolveUrl 后查找（处理相对路径）
    final resolvedUrl = UrlHelper.resolveUrlWithCdn(imageUrl);
    if (_thumbnailToIndex.containsKey(resolvedUrl)) {
      return _thumbnailToIndex[resolvedUrl];
    }
    
    // 3. 尝试转换为原图 URL 后查找
    final originalUrl = DiscourseImageUtils.getOriginalUrl(imageUrl);
    if (_thumbnailToIndex.containsKey(originalUrl)) {
      return _thumbnailToIndex[originalUrl];
    }
    
    // 4. resolvedUrl 转换为原图后查找
    final resolvedOriginalUrl = DiscourseImageUtils.getOriginalUrl(resolvedUrl);
    if (_thumbnailToIndex.containsKey(resolvedOriginalUrl)) {
      return _thumbnailToIndex[resolvedOriginalUrl];
    }
    
    return null;
  }

  /// spoiler 内的图片 URL 集合（公开供传递）
  Set<String> get spoilerImageUrls => _spoilerImageUrls;

  /// 获取原图 URL 列表（用于传递给画廊查看器）
  List<String> get images => originalUrls;
  
  /// 生成画廊 Hero tags
  List<String> get heroTags => DiscourseImageUtils.generateGalleryHeroTags(originalUrls);
  
  /// 获取指定索引的原图 URL
  String? getOriginalUrl(int index) {
    if (index >= 0 && index < originalUrls.length) {
      return originalUrls[index];
    }
    return null;
  }
}

/// Discourse 图片工具类
/// 集中处理图片 URL 转换、原图查找、查看器打开等通用逻辑
class DiscourseImageUtils {
  DiscourseImageUtils._();

  /// upload:// 短链接解析缓存（全局共享，仅缓存成功结果；key 统一为
  /// `upload://<base62>(.ext)` 归一化形态，见 [_normalizeUploadUrl]）
  /// 临时性失败（速率限制、网络抖动）不缓存，可在下次 build 时重试；
  /// 服务端确认不存在的短链记入 [_missingUploads] 负缓存（见下）。
  static final Map<String, String> _uploadUrlCache = {};

  /// 负缓存：lookup-urls 请求成功但服务端未返回的短链（上传已删除/失效）。
  /// 会话内不再发起解析（对齐官方 upload-short-url.js 的 MISSING 语义），
  /// 否则失效短链在预览持续重建场景下每次都重发请求 → 429 连坐拖垮
  /// 同帖正常图片的解析。
  static final Set<String> _missingUploads = {};

  /// 进行中的解析请求（同一短链共享同一个 Future，避免并发解析互相覆盖结果）
  static final Map<String, Future<String?>> _inflightResolves = {};

  /// `/uploads/short-url/<base62>(.ext)` 短链路径段
  /// （与 Discourse Upload.sha1_from_short_path 同口径）
  static final RegExp _shortUrlPathRe =
      RegExp(r'/uploads/short-url/([a-zA-Z0-9]+(?:\.[a-zA-Z0-9.]+)?)');

  /// 检查是否是需要 lookup-urls 解析的上传短链：
  /// `upload://<base62>` 短链 scheme，或站内 `/uploads/short-url/<base62>` 路径。
  ///
  /// 后者是 Rails 动态路由（uploads#show_short，302 → 真实上传 URL），
  /// 不是静态资源：CDN 域名下不存在（404），源站直连又要求浏览器态
  /// cookie（匿名 403）。原生播放器/图片加载器都带不动，必须像 web 端
  /// resolveAllShortUrls 一样先经 lookup-urls 换成真实 URL（用户手写
  /// `<video><source src="/uploads/short-url/..">` 的帖子就是这形态）。
  static bool isUploadUrl(String url) =>
      url.startsWith('upload://') || _isShortUrlPath(url);

  /// 站内短链路径判定：相对路径一律算本站；绝对 URL 仅接管本站源站 / CDN
  /// 前缀（前缀由站点配置动态派生，外站同形路径不动）。
  static bool _isShortUrlPath(String url) {
    if (!url.contains('/uploads/short-url/')) return false;
    if (url.startsWith('/') && !url.startsWith('//')) return true;
    final absolute = url.startsWith('//') ? 'https:$url' : url;
    if (!absolute.startsWith('http://') && !absolute.startsWith('https://')) {
      return false;
    }
    return absolute.startsWith(UrlHelper.resolveUrl('/uploads/short-url/')) ||
        absolute.startsWith(UrlHelper.resolveUrlWithCdn('/uploads/short-url/'));
  }

  /// 把 `/uploads/short-url/<base62>(.ext)` 归一化为 `upload://<base62>(.ext)`
  /// （lookup-urls 的标准入参 / 统一缓存 key）；upload:// 及其他 URL 原样返回。
  static String _normalizeUploadUrl(String url) {
    if (url.startsWith('upload://')) return url;
    final match = _shortUrlPathRe.firstMatch(url);
    return match == null ? url : 'upload://${match[1]}';
  }

  /// 从缓存中获取已解析的 URL
  /// 返回 null 表示未缓存，需要异步解析
  static String? getCachedUploadUrl(String shortUrl) {
    if (!isUploadUrl(shortUrl)) return shortUrl;
    return _uploadUrlCache[_normalizeUploadUrl(shortUrl)];
  }

  /// 预置短链解析结果（上传成功时响应里已带完整 URL，
  /// 直接 seed 缓存让编辑器预览零请求显示新图）
  static void seedUploadUrl(String shortUrl, String resolvedUrl) {
    if (!isUploadUrl(shortUrl) || resolvedUrl.isEmpty) return;
    _uploadUrlCache[_normalizeUploadUrl(shortUrl)] = resolvedUrl;
  }

  /// 异步解析上传短链并缓存结果。
  /// 返回 null = 不可用(missing 负缓存命中 / 服务端确认不存在 / 网络失败,
  /// 前两者不再重试,后者下次 build 重试)。
  static Future<String?> resolveUploadUrl(String shortUrl) {
    if (!isUploadUrl(shortUrl)) return Future.value(shortUrl);

    final key = _normalizeUploadUrl(shortUrl);
    final cached = _uploadUrlCache[key];
    if (cached != null) return Future.value(cached);
    if (_missingUploads.contains(key)) return Future.value(null);

    return _inflightResolves[key] ??= _doResolveUploadUrl(key);
  }

  static Future<String?> _doResolveUploadUrl(String shortUrl) async {
    try {
      final resolved = await DiscourseService().resolveShortUpload(shortUrl);
      if (resolved == null) return null; // 网络失败,可重试
      if (resolved.isMissing) {
        _missingUploads.add(shortUrl);
        return null;
      }
      final url = resolved.mediaUrl();
      _uploadUrlCache[shortUrl] = url;
      return url;
    } catch (e) {
      debugPrint('[DiscourseImageUtils] Failed to resolve upload url: $shortUrl, error: $e');
      return null;
    } finally {
      _inflightResolves.remove(shortUrl);
    }
  }

  /// 将优化图 URL 转换为原图 URL
  ///
  /// Discourse 优化图路径: .../uploads/default/optimized/4X/7/5/c/75c...dc_2_690x270.png
  /// 原图路径:            .../uploads/default/original/4X/7/5/c/75c...dc.png
  static String getOriginalUrl(String optimizedUrl) {
    if (!optimizedUrl.contains('/optimized/')) {
      return optimizedUrl;
    }

    try {
      // 1. 替换路径段
      var original = optimizedUrl.replaceFirst('/optimized/', '/original/');

      // 2. 移除分辨率后缀 (e.g. _2_690x270)
      final regex = RegExp(r'_\d+_\d+x\d+(?=\.[a-zA-Z0-9]+$)');
      if (regex.hasMatch(original)) {
        original = original.replaceAll(regex, '');
      }

      return original;
    } catch (e) {
      debugPrint('Error converting to original url: $e');
      return optimizedUrl;
    }
  }

  /// 从 DOM 元素中查找原图 URL
  /// 向上遍历 DOM 树，查找 lightbox 链接
  static String? findOriginalImageUrl(dynamic img) {
    dynamic current = img;

    // 向上遍历最多 5 层
    for (int i = 0; i < 5 && current != null; i++) {
      // 检查当前元素是否是 a 标签
      if (current.localName == 'a') {
        final href = current.attributes['href'] as String?;
        if (href != null && href.isNotEmpty) {
          // 检查是否是 lightbox 链接（通常指向原图）
          final classes = (current.classes as Iterable<String>?)?.toList() ?? [];
          if (classes.contains('lightbox') || href.contains('/original/')) {
            return href;
          }
          // 如果 href 指向图片文件，也返回
          if (isImageUrl(href)) {
            return href;
          }
        }
      }

      // 检查是否在 lightbox-wrapper 内
      if (current.localName == 'div' || current.localName == 'span') {
        final classes = (current.classes as Iterable<String>?)?.toList() ?? [];
        if (classes.contains('lightbox-wrapper')) {
          // 在 lightbox-wrapper 内查找 a.lightbox
          final anchors = current.getElementsByTagName('a');
          for (final a in anchors) {
            final aClasses = (a.classes as Iterable<String>?)?.toList() ?? [];
            if (aClasses.contains('lightbox')) {
              final href = a.attributes['href'] as String?;
              if (href != null && href.isNotEmpty) {
                return href;
              }
            }
          }
        }
      }

      current = current.parent;
    }

    return null;
  }

  /// 检查 URL 是否指向图片
  static bool isImageUrl(String url) {
    final lowerUrl = url.toLowerCase();
    return lowerUrl.endsWith('.jpg') ||
        lowerUrl.endsWith('.jpeg') ||
        lowerUrl.endsWith('.png') ||
        lowerUrl.endsWith('.gif') ||
        lowerUrl.endsWith('.webp') ||
        lowerUrl.endsWith('.avif') ||
        lowerUrl.contains('/uploads/') ||
        lowerUrl.contains('/original/');
  }


  /// 打开图片查看器（过滤不可见的 spoiler 图片）
  /// 根据 [revealedImageUrls] 过滤画廊，只显示非 spoiler 图片和已揭示的 spoiler 图片
  static void openViewerFiltered({
    required BuildContext context,
    required GalleryInfo galleryInfo,
    required Set<String> revealedImageUrls,
    required String imageUrl,
    required String heroTag,
    required int fullGalleryIndex,
    String? thumbnailUrl,
  }) {
    final allImages = galleryInfo.images;
    final allHeroTags = galleryInfo.heroTags;
    final visibleIndices = galleryInfo.getVisibleIndices(revealedImageUrls);
    final visibleIndex = visibleIndices.indexOf(fullGalleryIndex);

    openViewer(
      context: context,
      imageUrl: getOriginalUrl(imageUrl),
      heroTag: heroTag,
      galleryImages: visibleIndices.map((i) => getOriginalUrl(allImages[i])).toList(),
      heroTags: visibleIndices.map((i) => allHeroTags[i]).toList(),
      initialIndex: visibleIndex >= 0 ? visibleIndex : 0,
      thumbnailUrl: thumbnailUrl ?? imageUrl,
      thumbnailUrls: visibleIndices.map((i) => allImages[i]).toList(),
      filenames: visibleIndices.map((i) => galleryInfo.filenames[i]).toList(),
    );
  }

  /// 打开图片查看器。返回 Future 在关闭时完成(恢复浮层等用)。
  static Future<void> openViewer({
    required BuildContext context,
    required String imageUrl,
    required String heroTag,
    String? thumbnailUrl,
    List<String>? galleryImages,
    List<String>? thumbnailUrls,
    List<String>? heroTags,
    int initialIndex = 0,
    bool enableShare = true,
    List<String?>? filenames,
    BoxFit? heroSourceFit,
    double heroSourceRadius = 0,
  }) {
    return ImageViewerPage.open(
      context,
      imageUrl,
      heroTag: heroTag,
      galleryImages: galleryImages,
      heroTags: heroTags,
      initialIndex: initialIndex,
      enableShare: enableShare,
      thumbnailUrl: thumbnailUrl,
      thumbnailUrls: thumbnailUrls,
      filenames: filenames,
      heroSourceFit: heroSourceFit,
      heroSourceRadius: heroSourceRadius,
    );
  }

  /// 生成画廊 Hero Tag
  static String generateGalleryHeroTag(List<String> galleryImages, int index) {
    final galleryHash = Object.hashAll(galleryImages);
    return "gallery_${galleryHash}_$index";
  }

  /// 生成画廊所有 Hero Tags
  static List<String> generateGalleryHeroTags(List<String> galleryImages) {
    final galleryHash = Object.hashAll(galleryImages);
    return List.generate(
      galleryImages.length,
      (i) => "gallery_${galleryHash}_$i",
    );
  }
}

