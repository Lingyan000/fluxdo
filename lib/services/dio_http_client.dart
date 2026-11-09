import 'log/log_policy.dart';
import 'request_cancellation.dart';
import 'download_request_queue.dart';
export 'download_request_queue.dart' show DownloadPriority;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart' as dio;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../constants.dart';
import 'app_logger.dart';
import 'network/core/net_core_http_adapter.dart';
import 'network/interceptors/redirect_interceptor.dart';
import 'network/discourse_dio.dart';
import 'network/deadline_dio.dart';
import 'network/adapters/webview_http_adapter.dart';

/// [DioHttpClient.fetchBytes] 的非 200 响应。
///
/// 继承 [http.ClientException] 保持既有 catch 语义不变;需要按状态码
/// 分流的调用方(如 emoji 表情集缺图 404 回退)据 [statusCode] 判定,
/// 不必解析消息文本。
class HttpStatusException extends http.ClientException {
  HttpStatusException(this.statusCode, Uri url)
    : super('HTTP $statusCode for $url', url);

  final int? statusCode;
}

/// 包装 Dio 的 http.BaseClient 实现,给 flutter_cache_manager / image 下载用。
///
/// **双 dio 策略**(按 request URL host 选)
/// - **主域** (`linux.do` 及其子域):用 `_mainDomainDio`,带 cookie。
///   原因:`/uploads/secure-uploads/*` 私密图、user_avatar 在某些配置下需要
///   session cookie 才能访问。关掉 cookie 会让这些图 403。
///   但仍关掉 CfChallenge / Retry(图片自动 CF 验证 / 重试意义不大)。
///
/// - **第三方 CDN** (`s.pwsh.us.kg` / `cdn.ldstatic.com` / 其它):用 `_cdnDio`,
///   **完全不带 cookie**。CDN 根本不读 cookie header,带过去也无效;反而每张
///   图都触发 cookie jar 磁盘读写,30 张同屏 = 60 次磁盘 IO + cookie jar 锁
///   争用,这是"PNG 等半天"的根因。
class DioHttpClient extends http.BaseClient {
  static DioHttpClient? _instance;

  final dio.Dio _mainDomainDio;
  final dio.Dio _cdnDio;

  factory DioHttpClient() {
    _instance ??= DioHttpClient._internal();
    return _instance!;
  }

  @visibleForTesting
  DioHttpClient.withClients(this._mainDomainDio, this._cdnDio);

  DioHttpClient._internal()
    : _mainDomainDio = DiscourseDio.create(
        defaultHeaders: _imageHeaders,
        maxConcurrent: null,
        enableCookies: true, // 主域需要 cookie 走 secure-uploads
        enableCfChallenge: false,
        enableRetry: false,
        enableNetworkLog: false, // 几百张图都 log 占主线程
      ),
      _cdnDio = DiscourseDio.create(
        defaultHeaders: _imageHeaders,
        maxConcurrent: null,
        enableCookies: false, // CDN 完全不需要 cookie
        enableCfChallenge: false,
        enableRetry: false,
        enableNetworkLog: false,
      );

  static const Map<String, String> _imageHeaders = {
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
  };

  /// 头像与 emoji 共享 12 槽小图池；静态头像最多 6 个、可能的动图
  /// 头像最多 2 个，组间公平轮转，避免大动图阻塞静态头像。
  /// 没有头像时 emoji 仍可使用原有 12 槽，不因固定分配而降低吞吐。
  /// 正文/原图等 6 槽、贴纸原文件 3 槽各自独立，总上限仍为 21。
  /// 槽位覆盖响应体消费及写盘背压，不随域名数量扩容；任务数约束
  /// 不等同于字节预算或进程总内存上限，动图头像也受头像组上限约束。
  static final DownloadRequestQueue _smallSemaphore = DownloadRequestQueue(
    12,
    groupLimits: {'small': 12, 'avatar': 6, 'avatarAnimation': 2},
  );
  static final DownloadRequestQueue _contentSemaphore = DownloadRequestQueue(
    6,
    reservedHighSlots: 1,
  );
  static final DownloadRequestQueue _stickerSemaphore = DownloadRequestQueue(
    3,
    reservedHighSlots: 1,
  );

  /// [send](http.BaseClient 接口,现无常驻调用方)沿用内容通道。
  static DownloadRequestQueue get _downloadSemaphore => _contentSemaphore;

  static DownloadRequestQueue _semaphoreOf(DownloadChannel channel) =>
      switch (channel) {
        DownloadChannel.small => _smallSemaphore,
        DownloadChannel.avatar => _smallSemaphore,
        DownloadChannel.avatarAnimation => _smallSemaphore,
        DownloadChannel.content => _contentSemaphore,
        DownloadChannel.sticker => _stickerSemaphore,
      };

  /// 把仍在 [channel] 等待队列中的 [url] 提到高优先级(滚入视野)。
  /// 在途/未排队/已完成均为无操作 —— 幂等,调用方无需判断状态。
  static void bumpPending(DownloadChannel channel, String url) =>
      _semaphoreOf(channel).bump(url);

  /// 把仍在 [channel] 等待队列中的 [url] 沉到低优先级队尾(滚出视野)。
  static void sinkPending(DownloadChannel channel, String url) =>
      _semaphoreOf(channel).sink(url);

  static void Function() retainForeground(
    DownloadChannel channel,
    String url,
  ) => _semaphoreOf(channel).retainForeground(url);

  /// 提取 [AppConstants.baseUrl] 的 host(例如 `linux.do`),用于判断主域。
  /// 注意是 host 比对而不是 URL prefix 比对 —— 子域(`auth.linux.do` 等)
  /// 也算主域,会走带 cookie 的 dio。
  static final String _mainHost = Uri.parse(AppConstants.baseUrl).host;

  bool _isMainDomain(Uri url) {
    final host = url.host;
    if (host.isEmpty) return false;
    // 主域精确匹配 或 是主域的子域(*.linux.do)
    return host == _mainHost || host.endsWith('.$_mainHost');
  }

  dio.Dio _selectDio(Uri url) => _isMainDomain(url) ? _mainDomainDio : _cdnDio;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await _downloadSemaphore.acquire(
      request.url.toString(),
      DownloadPriority.normal,
    );
    try {
      // 转换 headers
      final headers = <String, dynamic>{};
      request.headers.forEach((key, value) {
        headers[key] = value;
      });

      // 获取请求体
      Uint8List? bodyBytes;
      if (request is http.Request && request.bodyBytes.isNotEmpty) {
        bodyBytes = request.bodyBytes;
      } else if (request is http.MultipartRequest) {
        // MultipartRequest 需要特殊处理
        final stream = request.finalize();
        final bytes = await stream.toBytes();
        bodyBytes = Uint8List.fromList(bytes);
      }

      // 按 host 选 dio:主域用 _mainDomainDio(带 cookie),CDN 用 _cdnDio(lean)
      final isMainDomain = _isMainDomain(request.url);
      final extra = <String, dynamic>{};
      if (isMainDomain) {
        extra[WebViewHttpAdapter.resourceKindExtraKey] =
            WebViewHttpAdapter.resourceKindImage;
        extra[WebViewHttpAdapter.cookieModeExtraKey] =
            WebViewHttpAdapter.cookieModeReadOnly;
      }
      final response = await _selectDio(request.url).request<dio.ResponseBody>(
        request.url.toString(),
        options: dio.Options(
          method: request.method,
          headers: headers,
          responseType: dio.ResponseType.stream,
          extra: extra,
          // 接受所有状态码，让调用方处理
          validateStatus: (status) => true,
        ),
        data: bodyBytes != null ? Stream.fromIterable([bodyBytes]) : null,
      );

      // 转换响应 headers
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name] = values.join(', ');
      });

      // 在并发槽内读完整个 body(见 _downloadSemaphore 注释)
      final builder = BytesBuilder(copy: false);
      final responseBody = response.data;
      if (responseBody != null) {
        await for (final chunk in responseBody.stream) {
          builder.add(chunk);
        }
      }
      final bodyData = builder.takeBytes();

      return http.StreamedResponse(
        Stream.value(bodyData),
        response.statusCode ?? 200,
        headers: responseHeaders,
        // 用实际字节数而不是 content-length header:gzip 解压后两者可能不一致
        contentLength: bodyData.length,
        request: request,
        reasonPhrase: response.statusMessage,
      );
    } on dio.DioException catch (e) {
      // 将 DioException 转换为 http 包可以理解的异常
      if (e.type == dio.DioExceptionType.connectionTimeout ||
          e.type == dio.DioExceptionType.receiveTimeout) {
        throw http.ClientException(
          'Request timeout: ${e.message}',
          request.url,
        );
      }
      throw http.ClientException('Dio error: ${e.message}', request.url);
    } finally {
      _downloadSemaphore.release();
    }
  }

  @override
  void close() {
    // 不关闭共享的 Dio 实例
  }

  /// 直接拉取 URL 的完整字节(BlobImageCache 专用):按 [channel] 选
  /// 并发通道、同一套双 dio 分流,流式读 body 逐 chunk 上报进度。
  ///
  /// 非 200 抛 [http.ClientException];[onProgress] 的 total 在响应无
  /// content-length(或 gzip)时为 null。
  Future<Uint8List> fetchBytes(
    Uri url, {
    DownloadChannel channel = DownloadChannel.content,
    DownloadPriority priority = DownloadPriority.normal,
    void Function(int received, int? total)? onProgress,
    Future<void> Function(Uint8List bytes)? onBytesReady,
    dio.CancelToken? cancellation,
    Duration callTimeout = const Duration(minutes: 2),
  }) async {
    try {
      return await DeadlineDio.withDeadline(
        dio.RequestOptions(path: url.toString(), cancelToken: cancellation),
        callTimeout,
        (request) => _fetchBytes(
          url,
          channel: channel,
          priority: priority,
          onProgress: onProgress,
          onBytesReady: onBytesReady,
          cancellation: request.cancelToken,
          requestExtra: request.extra,
        ),
      );
    } on dio.DioException catch (error) {
      throw http.ClientException('Dio error: ${error.message}', url);
    }
  }

  Future<Uint8List> _fetchBytes(
    Uri url, {
    required DownloadChannel channel,
    required DownloadPriority priority,
    required void Function(int received, int? total)? onProgress,
    required Future<void> Function(Uint8List bytes)? onBytesReady,
    required dio.CancelToken? cancellation,
    required Map<String, dynamic> requestExtra,
  }) async {
    final elapsed = Stopwatch()..start();
    final semaphore = _semaphoreOf(channel);
    final group = switch (channel) {
      DownloadChannel.small ||
      DownloadChannel.avatar ||
      DownloadChannel.avatarAnimation => channel.name,
      _ => null,
    };
    final cancelToken = cancellation ?? dio.CancelToken();
    cancelToken.throwIfCancellationRequested();
    await semaphore.acquire(
      url.toString(),
      priority,
      cancelled: cancelToken.whenCancel.then((_) {}),
      group: group,
    );
    final queueMs = elapsed.elapsedMilliseconds;
    final foregroundAtStart =
        priority == DownloadPriority.high ||
        semaphore.isForeground(url.toString());
    var completed = false;
    int? headMs;
    int? bodyMs;
    int? status;
    String? protocol;
    Map<String, dynamic>? connection;
    var receivedBytes = 0;
    final diagnosticExtra = <String, dynamic>{
      ...requestExtra,
      'traceId': LogPolicy.newTraceId(),
    };
    try {
      cancelToken.throwIfCancellationRequested();
      final isMainDomain = _isMainDomain(url);
      final extra = diagnosticExtra;
      if (isMainDomain) {
        extra[WebViewHttpAdapter.resourceKindExtraKey] =
            WebViewHttpAdapter.resourceKindImage;
        extra[WebViewHttpAdapter.cookieModeExtraKey] =
            WebViewHttpAdapter.cookieModeReadOnly;
      }
      final response = await _selectDio(url).get<dio.ResponseBody>(
        url.toString(),
        cancelToken: cancelToken,
        options: dio.Options(
          responseType: dio.ResponseType.stream,
          extra: extra,
          validateStatus: (status) => true,
        ),
      );
      diagnosticExtra.addAll(response.requestOptions.extra);
      headMs = elapsed.elapsedMilliseconds - queueMs;
      status = response.statusCode;
      protocol =
          response.extra[dio.HttpClientAdapter.extraKeyHttpVersion] as String?;
      final coreConnection = response.extra[netCoreConnectionExtraKey];
      if (coreConnection is Map) {
        connection = {
          for (final key in [
            'connectionId',
            'reused',
            'tlsResumed',
            'echApplied',
            'echAccepted',
            'connectMs',
            'ttfbMs',
          ])
            if (coreConnection.containsKey(key)) key: coreConnection[key],
        };
      }
      if (response.statusCode != 200) {
        throw HttpStatusException(response.statusCode, url);
      }
      final contentLength = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      final total = (contentLength != null && contentLength > 0)
          ? contentLength
          : null;

      final builder = BytesBuilder(copy: false);
      final body = response.data;
      if (body != null) {
        await for (final chunk in body.stream) {
          builder.add(chunk);
          receivedBytes += chunk.length;
          onProgress?.call(builder.length, total);
        }
      }
      final bytes = builder.takeBytes();
      bodyMs = elapsed.elapsedMilliseconds - queueMs - headMs;
      completed = true;
      // 落盘预算不足时保留下载槽进行背压；预算充足时回调只提交后台任务。
      await onBytesReady?.call(bytes);
      return bytes;
    } on dio.DioException catch (e) {
      diagnosticExtra.addAll(e.requestOptions.extra);
      throw http.ClientException('Dio error: ${e.message}', url);
    } finally {
      // 非 200、进度回调抛错等都可能早于响应 EOF；取消整个请求，
      // 不依赖 Dio 包装流的订阅取消能否继续传递到适配器。
      if (!completed) cancelToken.cancel('Image download abandoned');
      semaphore.release(group: group);
      elapsed.stop();
      final totalMs = elapsed.elapsedMilliseconds;
      // 快速成功不逐图落盘；慢请求/失败才记录阶段耗时，详细日志模式可看全量。
      // 只记域名和数值，不记录图片路径、查询参数、Cookie 或令牌。
      if (!completed || totalMs >= 1500 || AppLogger.verboseNotifier.value) {
        AppLogger.info(
          '图片下载阶段耗时',
          tag: 'ImageDownload',
          fields: {
            'type': 'network',
            'event': 'image_download_timing',
            'traceId': diagnosticExtra['traceId'],
            'attemptId': diagnosticExtra['attemptId'],
            'coreRequestId': diagnosticExtra['coreRequestId'],
            'host': url.host,
            'channel': channel.name,
            'foregroundAtStart': foregroundAtStart,
            'queueMs': queueMs,
            'headMs': headMs,
            'redirectHops': diagnosticExtra[RedirectInterceptor.hopsKey],
            'bodyMs':
                bodyMs ?? (headMs == null ? null : totalMs - queueMs - headMs),
            'consumerMs': bodyMs == null
                ? null
                : totalMs - queueMs - headMs! - bodyMs,
            'totalMs': totalMs,
            'bytes': receivedBytes,
            'status': status,
            'completed': completed,
            'httpVersion': protocol,
            'connection': connection,
          },
        );
      }
    }
  }
}

/// 图片下载并发通道(见 [DioHttpClient._smallSemaphore] 注释)。
enum DownloadChannel {
  /// emoji 小文件。
  small,

  /// 静态头像；与 emoji 共享小图池，单独限制组内并发。
  avatar,

  /// 可能的动图头像（含待嗅探的 WebP）；限制大文件同时下载数量。
  avatarAnimation,

  /// 正文/原图/外部图/贴纸缩略 —— 带宽敏感的混合内容。
  content,

  /// 贴纸原文件 —— 面板预取型、单文件大,独立通道防挤占内容。
  sticker,
}
