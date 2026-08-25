part of 'discourse_service.dart';

class ResolvedUploadUrl {
  final String url;
  final String? shortPath;

  const ResolvedUploadUrl({required this.url, this.shortPath});

  /// 负缓存哨兵:lookup-urls 请求**成功**但服务端未返回此短链(上传已
  /// 删除/失效)。对齐官方 upload-short-url.js 的 MISSING 语义 —— 会话内
  /// 不再重试。否则失效短链每次 build 都 cache miss 重发请求,编辑预览
  /// 持续刷新时演变成请求风暴 → 429 速率限制连坐拖垮同帖正常图片的解析。
  static const missing = ResolvedUploadUrl(url: '');

  bool get isMissing => url.isEmpty;

  String mediaUrl() {
    if (url.contains('secure-media-uploads') ||
        url.contains('secure-uploads')) {
      return UrlHelper.resolveUrl(url);
    }

    return UrlHelper.resolveUrlWithCdn(url);
  }

  String linkUrl({required bool secureUploads}) {
    if (secureUploads &&
        (url.contains('secure-media-uploads') ||
            url.contains('secure-uploads'))) {
      return url;
    }

    return shortPath ?? url;
  }
}

/// 上传结果
class UploadResult {
  /// 上传记录主键。发帖走 Markdown 短链引用不需要它;Chat 插件发消息
  /// 走 `upload_ids` 数组关联附件,只能靠这个 id,不认短链。
  final int? id;
  final String shortUrl;
  final String? url;
  final String originalFilename;
  final int? width;
  final int? height;
  final int? thumbnailWidth;
  final int? thumbnailHeight;
  final int? filesize;
  final String? humanFilesize;
  final String? extension;

  UploadResult({
    this.id,
    required this.shortUrl,
    this.url,
    required this.originalFilename,
    this.width,
    this.height,
    this.thumbnailWidth,
    this.thumbnailHeight,
    this.filesize,
    this.humanFilesize,
    this.extension,
  });

  static final _imageExts = RegExp(
    r'\.(png|webp|jpe?g|gif|svg|ico|heic|heif|avif)$',
    caseSensitive: false,
  );
  static final _videoExts = RegExp(
    r'\.(mov|mp4|webm|m4v|3gp|ogv|avi|mpeg)$',
    caseSensitive: false,
  );
  static final _audioExts = RegExp(
    r'\.(mp3|og[ga]|opus|wav|m4[abpr]|aac|flac)$',
    caseSensitive: false,
  );

  bool get isImage => _imageExts.hasMatch(originalFilename);
  bool get isVideo => _videoExts.hasMatch(originalFilename);
  bool get isAudio => _audioExts.hasMatch(originalFilename);

  /// 生成 Discourse 格式的 Markdown 图片语法
  /// 格式: ![alt|widthxheight](url)
  String toMarkdown({String? alt}) {
    final displayAlt = alt ?? originalFilename;
    // 优先使用缩略图尺寸，否则使用原图尺寸
    final w = thumbnailWidth ?? width;
    final h = thumbnailHeight ?? height;

    if (w != null && h != null) {
      return '![$displayAlt|${w}x$h]($shortUrl)';
    }
    return '![$displayAlt]($shortUrl)';
  }

  /// 根据文件类型自动生成正确的 Markdown
  String toAutoMarkdown({String? alt}) {
    if (isImage) return toMarkdown(alt: alt);
    final name = alt ?? originalFilename;
    if (isVideo) return '![$name|video]($shortUrl)';
    if (isAudio) return '![$name|audio]($shortUrl)';
    // 附件格式: [filename|attachment](short_url) (human_filesize)
    final sizeStr = filesize != null ? formatFileSize(filesize!) : '';
    return '[$originalFilename|attachment]($shortUrl)${sizeStr.isNotEmpty ? ' ($sizeStr)' : ''}';
  }

  /// 客户端本地化文件大小格式化（对齐 Discourse i18n）
  static String formatFileSize(int bytes) {
    if (bytes < 1024) {
      return S.current.common_sizeBytes(bytes.toString());
    }
    if (bytes < 1024 * 1024) {
      final kb = bytes / 1024;
      final str = kb == kb.roundToDouble()
          ? kb.toInt().toString()
          : kb.toStringAsFixed(1);
      return S.current.common_sizeKB(str);
    }
    if (bytes < 1024 * 1024 * 1024) {
      final mb = bytes / (1024 * 1024);
      final str = mb == mb.roundToDouble()
          ? mb.toInt().toString()
          : mb.toStringAsFixed(1);
      return S.current.common_sizeMB(str);
    }
    final gb = bytes / (1024 * 1024 * 1024);
    final str = gb == gb.roundToDouble()
        ? gb.toInt().toString()
        : gb.toStringAsFixed(1);
    return S.current.common_sizeGB(str);
  }
}

/// 上传相关
mixin _UploadsMixin on _DiscourseServiceBase {
  /// 获取图片请求头
  Future<Map<String, String>> getHeaders() async {
    final headers = <String, String>{'User-Agent': AppConstants.userAgent};

    final cookies = await _cookieJar.getCookieHeader();
    if (cookies != null && cookies.isNotEmpty) {
      headers['Cookie'] = cookies;
    }

    return headers;
  }

  /// 下载图片
  Future<Uint8List?> downloadImage(String url) async {
    try {
      final isAppHost = CookieJarService.matchesAppHost(Uri.parse(url).host);
      final extra = <String, dynamic>{'skipCsrf': true, 'skipAuthCheck': true};
      if (isAppHost) {
        extra[WebViewHttpAdapter.resourceKindExtraKey] =
            WebViewHttpAdapter.resourceKindImage;
        extra[WebViewHttpAdapter.cookieModeExtraKey] =
            WebViewHttpAdapter.cookieModeReadOnly;
      }

      final response = await _dio.get(
        url,
        options: Options(responseType: ResponseType.bytes, extra: extra),
      );

      if (response.data is! List<int>) {
        debugPrint(
          '[DiscourseService] Invalid response data type for image: $url',
        );
        return null;
      }

      final bytes = Uint8List.fromList(response.data);

      if (bytes.isEmpty) {
        debugPrint('[DiscourseService] Empty image data: $url');
        return null;
      }

      final contentType = response.headers.value('content-type')?.toLowerCase();
      if (contentType != null && !contentType.startsWith('image/')) {
        debugPrint(
          '[DiscourseService] Invalid content-type for image: $contentType, url: $url',
        );
        return null;
      }

      if (!_isValidImageData(bytes)) {
        debugPrint(
          '[DiscourseService] Invalid image data (magic bytes check failed): $url',
        );
        return null;
      }

      return bytes;
    } catch (e) {
      debugPrint('[DiscourseService] Download image failed: $e, url: $url');
      return null;
    }
  }

  /// 验证图片数据是否有效
  bool _isValidImageData(Uint8List bytes) {
    if (bytes.length < 4) return false;

    // PNG
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }

    // JPEG
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true;
    }

    // GIF
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return true;
    }

    // WebP
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }

    // BMP
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return true;
    }

    // ICO
    if (bytes[0] == 0x00 &&
        bytes[1] == 0x00 &&
        bytes[2] == 0x01 &&
        bytes[3] == 0x00) {
      return true;
    }

    return false;
  }

  /// 上传文件（内置速率限制重试，支持图片和附件）。
  /// [filenameOverride]/[contentTypeOverride]:媒体改名上传用(见
  /// [uploadMediaAsXz]),不影响常规路径。
  ///
  /// **为什么这里手写重试而不交给恢复层**:dio 的 [FormData] 是一次性的,
  /// `finalize()` 之后二次使用会抛
  /// `StateError('The FormData has already been finalized')`。恢复层重放的是
  /// 同一个 RequestOptions,请求体已被消费,重放必然炸——那会把一个本可恢复
  /// 的 429 变成硬失败,还丢掉错误类型。
  ///
  /// 所以重试必须由调用方做:**循环体内每轮重建 FormData**。恢复层那侧有
  /// 对应护栏(RecoveryCoordinator._canReplayBody 直接不认领 FormData/Stream
  /// 请求体),契约见 test/services/network/recovery/non_replayable_body_test.dart。
  Future<UploadResult> uploadFile(
    String filePath, {
    String? filenameOverride,
    DioMediaType? contentTypeOverride,
  }) async {
    const maxRetries = 3;

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final fileName = filenameOverride ?? filePath.split('/').last;

        final formData = FormData.fromMap({
          'upload_type': 'composer',
          'synchronous': true,
          'file': await MultipartFile.fromFile(
            filePath,
            filename: fileName,
            contentType: contentTypeOverride,
          ),
        });

        final response = await _dio.post(
          '/uploads.json',
          queryParameters: {'client_id': MessageBusService().clientId},
          data: formData,
          options: Options(
            extra: {
              'showErrorToast': attempt >= maxRetries,
              WebViewHttpAdapter.resourceKindExtraKey:
                  WebViewHttpAdapter.resourceKindUpload,
            },
          ), // 仅最后一次尝试才弹 toast
        );

        final data = response.data;
        if (data is Map) {
          final shortUrl = data['short_url'] as String?;
          if (shortUrl != null) {
            return UploadResult(
              id: data['id'] as int?,
              shortUrl: shortUrl,
              url: data['url'] as String?,
              originalFilename:
                  data['original_filename'] as String? ?? fileName,
              width: data['width'] as int?,
              height: data['height'] as int?,
              thumbnailWidth: data['thumbnail_width'] as int?,
              thumbnailHeight: data['thumbnail_height'] as int?,
              filesize: data['filesize'] as int?,
              humanFilesize: data['human_filesize'] as String?,
              extension: data['extension'] as String?,
            );
          }
          // 兜底：使用完整 URL
          final url = data['url'] as String?;
          if (url != null) {
            return UploadResult(
              id: data['id'] as int?,
              shortUrl: url,
              url: url,
              originalFilename:
                  data['original_filename'] as String? ?? fileName,
              width: data['width'] as int?,
              height: data['height'] as int?,
              thumbnailWidth: data['thumbnail_width'] as int?,
              thumbnailHeight: data['thumbnail_height'] as int?,
              filesize: data['filesize'] as int?,
              humanFilesize: data['human_filesize'] as String?,
              extension: data['extension'] as String?,
            );
          }
        }

        throw Exception(S.current.error_uploadNoUrl);
      } on DioException catch (e) {
        debugPrint('[DiscourseService] Upload image failed: $e');

        // ErrorInterceptor 把 429 转成 DioException.error = RateLimitException
        // (response 保留),这里按类型判定重试
        final innerError = e.error;
        if (innerError is RateLimitException && attempt < maxRetries) {
          final waitSeconds = innerError.retryAfterSeconds ?? 10;
          debugPrint(
            '[DiscourseService] 速率限制，等待 ${waitSeconds}s 后重试 '
            '(${attempt + 1}/$maxRetries)',
          );
          await Future.delayed(Duration(seconds: waitSeconds));
          continue;
        }

        if (e.response?.statusCode == 413) {
          throw Exception(S.current.error_imageTooBig);
        }
        if (e.response?.statusCode == 422) {
          final data = e.response?.data;
          if (data is Map && data['errors'] != null) {
            throw Exception((data['errors'] as List).join('\n'));
          }
          throw Exception(S.current.error_imageFormatUnsupported);
        }
        rethrow;
      } catch (e) {
        debugPrint('[DiscourseService] Upload image failed: $e');
        rethrow;
      }
    }

    // 不可达，但编译器需要
    throw Exception(S.current.error_uploadNoUrl);
  }

  /// 上传图片（uploadFile 的别名，保持向后兼容）
  Future<UploadResult> uploadImage(String filePath) => uploadFile(filePath);

  /// 媒体上传的站点体积上限(linux.do 4MB;超限服务端 413)。
  static const int maxMediaUploadBytes = 4 * 1024 * 1024;

  /// 音视频改名上传(与社区「媒体上传」脚本同 hack):站点扩展名白名单
  /// 不含音视频,把文件名换 `.xz`(application/x-xz)绕过 —— 播放端
  /// (本 app MediaCompatService 嗅探 / 网页原生 audio·video 标签)不受
  /// 扩展名影响。4MB 前置检查,超限直接抛(不做压缩,调用方提示)。
  Future<UploadResult> uploadMediaAsXz(String filePath) async {
    final size = await File(filePath).length();
    if (size >= maxMediaUploadBytes) {
      throw Exception(
        '媒体文件须小于 4MB,当前 ${UploadResult.formatFileSize(size)};'
        '请先压缩后再上传',
      );
    }
    final base = filePath.split('/').last;
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final xzName = '$stem.xz';
    return uploadFile(
      filePath,
      filenameOverride: xzName,
      contentTypeOverride: DioMediaType('application', 'x-xz'),
    );
  }

  /// 批量解析 short_url。
  ///
  /// 限流重试交给恢复层(RateLimitPolicy 按 Retry-After 等待后重放):这个
  /// 请求的体是普通 Map,可以安全重放 —— 与 [uploadFile] 的 FormData 不同,
  /// 那边必须自己循环重建请求体。
  ///
  /// 曾经这里也有一份手写的 maxRetries=3 循环,与恢复层职责重叠:同一个 429
  /// 先被恢复层退避重试、失败后再进本循环等 5 秒重试,最坏叠成十几次尝试。
  Future<List<Map<String, dynamic>>> lookupUrls(List<String> shortUrls) async {
    final missingUrls = shortUrls
        .where((url) => !_urlCache.containsKey(url))
        .toList();

    if (missingUrls.isEmpty) return [];

    try {
      final response = await _dio.post(
        '/uploads/lookup-urls',
        data: {'short_urls': missingUrls},
      );

      final List<dynamic> uploads = response.data;
      final result = <Map<String, dynamic>>[];

      for (final item in uploads) {
        if (item is Map<String, dynamic>) {
          result.add(item);
          final shortUrl = item['short_url'] as String?;
          final url = item['url'] as String?;
          if (shortUrl != null && url != null) {
            _urlCache[shortUrl] = ResolvedUploadUrl(
              url: url,
              shortPath: item['short_path'] as String?,
            );
          }
        }
      }
      // 请求成功但未返回的短链 = 上传不存在(已删除/失效),写负缓存
      // 会话内不再重试(对齐官方 MISSING);网络失败(catch 分支)不写,
      // 临时性失败下次仍可重试。
      for (final url in missingUrls) {
        _urlCache.putIfAbsent(url, () => ResolvedUploadUrl.missing);
      }
      return result;
    } catch (e) {
      // 解析失败不影响正文渲染:返回空表让调用方走原始 URL 兜底。
      debugPrint('[DiscourseService] lookupUrls failed: $e');
      return [];
    }
  }

  /// 微批量合并窗口内待解析的 short_url（与 _pendingLookupCompleter 同生命周期）
  List<String>? _pendingLookupBatch;
  Completer<void>? _pendingLookupCompleter;

  /// 进行中的解析请求（同一 short_url 共享同一个 Future，避免重复请求）
  final Map<String, Future<void>> _inflightLookups = {};

  /// 将单条解析请求合并进微批量窗口：
  /// 同一帧/短时间内多张图片各自触发的解析会合并为一次 lookup-urls 请求，
  /// 避免上传多张图后瞬时并发多个 POST 触发速率限制
  Future<void> _lookupBatched(String shortUrl) {
    final inflight = _inflightLookups[shortUrl];
    if (inflight != null) return inflight;

    if (_pendingLookupBatch == null) {
      final batch = <String>[];
      final completer = Completer<void>();
      _pendingLookupBatch = batch;
      _pendingLookupCompleter = completer;

      Future.delayed(const Duration(milliseconds: 50), () async {
        // 关闭收集窗口，后续请求进入下一批
        _pendingLookupBatch = null;
        _pendingLookupCompleter = null;
        try {
          await lookupUrls(batch);
        } finally {
          for (final url in batch) {
            _inflightLookups.remove(url);
          }
          completer.complete();
        }
      });
    }

    _pendingLookupBatch!.add(shortUrl);
    final future = _pendingLookupCompleter!.future;
    _inflightLookups[shortUrl] = future;
    return future;
  }

  /// 解析单个 short_url。返回 null = 网络失败(可重试);
  /// [ResolvedUploadUrl.missing] = 服务端确认不存在(调用方按裂图处理)。
  Future<ResolvedUploadUrl?> resolveShortUpload(String shortUrl) async {
    if (!shortUrl.startsWith('upload://')) {
      return ResolvedUploadUrl(url: shortUrl, shortPath: shortUrl);
    }

    if (_urlCache.containsKey(shortUrl)) {
      return _urlCache[shortUrl];
    }

    await _lookupBatched(shortUrl);
    return _urlCache[shortUrl];
  }

  Future<String?> resolveShortUrl(String shortUrl) async {
    if (!shortUrl.startsWith('upload://')) return shortUrl;

    final resolved = await resolveShortUpload(shortUrl);
    if (resolved == null || resolved.isMissing) return null;
    return resolved.mediaUrl();
  }

  Future<String?> resolveShortUrlForLink(String shortUrl) async {
    if (!shortUrl.startsWith('upload://')) return shortUrl;

    final resolved = await resolveShortUpload(shortUrl);
    if (resolved == null || resolved.isMissing) return null;

    final secureUploads =
        PreloadedDataService().siteSettingsSync?['secure_uploads'] == true;
    return resolved.linkUrl(secureUploads: secureUploads);
  }
}
