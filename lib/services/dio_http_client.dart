import 'download_request_queue.dart';
export 'download_request_queue.dart' show DownloadPriority;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart' as dio;
import 'package:http/http.dart' as http;

import '../constants.dart';
import 'network/discourse_dio.dart';
import 'network/adapters/webview_http_adapter.dart';

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

  /// 图片下载并发通道(下载侧按内容域分队,与缓存 bucket 分池同思路)。
  ///
  /// 曾是单一全局 8 槽 FIFO —— cache_manager 时代每个 manager 自带 10
  /// 并发互相稀释,问题不显;全量走 blob 单一入口后,贴纸面板一开
  /// (30+ 张几百 KB~几 MB 动图 + 批量预取)就把 8 槽全占满,正文图
  /// 排在几十个大文件后面,表现为"贴纸一多正文图加载不出来"。
  ///
  /// 修法 = 按内容域分通道,物理隔离:
  /// - **small 12 槽**:emoji 等 KB 级小文件。耗时被 RTT 主导而非带宽,
  ///   高并发是纯赚(连接复用后无 TLS 风暴,浏览器 H2 加载 emoji 同为
  ///   几十路);6 槽跑 200 张 ≈ 200/6×RTT≈5s,12 槽砍半。
  /// - **content 6 槽**:正文/头像/原图/外部图(几十 KB~几 MB 混合,
  ///   带宽敏感,并发过高互相挤占)。
  /// - **sticker 3 槽**:贴纸原文件(面板预取型、单文件大),独立通道
  ///   防挤占内容；其中1槽仅供high前台请求，后台最多使用2槽。
  static final DownloadRequestQueue _smallSemaphore = DownloadRequestQueue(12);
  static final DownloadRequestQueue _contentSemaphore = DownloadRequestQueue(6);
  static final DownloadRequestQueue _stickerSemaphore = DownloadRequestQueue(
    3,
    reservedHighSlots: 1,
  );

  /// [send](http.BaseClient 接口,现无常驻调用方)沿用内容通道。
  static DownloadRequestQueue get _downloadSemaphore => _contentSemaphore;

  static DownloadRequestQueue _semaphoreOf(DownloadChannel channel) =>
      switch (channel) {
        DownloadChannel.small => _smallSemaphore,
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
  }) async {
    final semaphore = _semaphoreOf(channel);
    await semaphore.acquire(url.toString(), priority);
    try {
      final isMainDomain = _isMainDomain(url);
      final extra = <String, dynamic>{};
      if (isMainDomain) {
        extra[WebViewHttpAdapter.resourceKindExtraKey] =
            WebViewHttpAdapter.resourceKindImage;
        extra[WebViewHttpAdapter.cookieModeExtraKey] =
            WebViewHttpAdapter.cookieModeReadOnly;
      }
      final response = await _selectDio(url).get<dio.ResponseBody>(
        url.toString(),
        options: dio.Options(
          responseType: dio.ResponseType.stream,
          extra: extra,
          validateStatus: (status) => true,
        ),
      );
      if (response.statusCode != 200) {
        throw http.ClientException('HTTP ${response.statusCode} for $url', url);
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
          onProgress?.call(builder.length, total);
        }
      }
      return builder.takeBytes();
    } on dio.DioException catch (e) {
      throw http.ClientException('Dio error: ${e.message}', url);
    } finally {
      semaphore.release();
    }
  }
}

/// 图片下载并发通道(见 [DioHttpClient._smallSemaphore] 注释)。
enum DownloadChannel {
  /// KB 级小文件(emoji)—— RTT 主导,高并发纯赚。
  small,

  /// 正文/头像/原图/外部图 —— 带宽敏感的混合内容。
  content,

  /// 贴纸原文件 —— 面板预取型、单文件大,独立通道防挤占内容。
  sticker,
}
