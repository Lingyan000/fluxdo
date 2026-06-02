import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;

/// 把 [HttpClientAdapter] 包装成 [http.Client]，让基于 `package:http` 的 SDK
/// （langchain_dart / openai_core 等）复用应用的 dio 网络栈（代理、TLS 适配器等）。
///
/// 透传策略：
/// - 请求体走流式（不落内存），保留 SSE 等长连接场景
/// - 响应同样以流形式向上抛，不在桥接层缓冲
/// - 响应头多值用逗号合并，符合 RFC 7230 §3.2.2
///
/// 例外：`/v1/images/generations` 与 `/v1/images/edits` 的非流式 JSON 响应会
/// 被缓冲并补全 `usage` 内部的 int 字段。第三方 OpenAI 兼容代理（aihubmix /
/// new-api / one-api / aitohumanize 等）常返回 `usage.input_tokens_details: {}`
/// 这种空对象，触发 openai_dart 4.x `as int` 强转失败。SSE 流式响应不缓冲。
class DioBackedHttpClient extends http.BaseClient {
  DioBackedHttpClient(this._adapter);

  final HttpClientAdapter _adapter;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException(
        'DioBackedHttpClient has been closed.',
        request.url,
      );
    }

    final body = request.finalize();
    final requestStream = body.cast<Uint8List>();

    final options = RequestOptions(
      method: request.method,
      path: request.url.toString(),
      headers: <String, dynamic>{...request.headers},
      responseType: ResponseType.stream,
      followRedirects: request.followRedirects,
      maxRedirects: request.maxRedirects,
      // 让 dio 自己根据请求 body 推断 Content-Length；显式 null 表示不强制
      contentType: request.headers['content-type'] ??
          request.headers['Content-Type'],
    );

    final ResponseBody responseBody;
    try {
      responseBody = await _adapter.fetch(options, requestStream, null);
    } on DioException catch (e) {
      throw http.ClientException(
        e.message ?? e.toString(),
        request.url,
      );
    }

    final headers = _flattenHeaders(responseBody.headers);

    if (_shouldPatchImagesUsage(request, responseBody.statusCode, headers)) {
      final patched = await _readAndPatchImagesResponse(responseBody.stream);
      return http.StreamedResponse(
        Stream.value(patched),
        responseBody.statusCode,
        contentLength: patched.length,
        request: request,
        headers: headers,
        isRedirect: responseBody.isRedirect,
        reasonPhrase: responseBody.statusMessage,
      );
    }

    final contentLength = _parseContentLength(responseBody.headers);

    return http.StreamedResponse(
      responseBody.stream.cast<List<int>>(),
      responseBody.statusCode,
      contentLength: contentLength,
      request: request,
      headers: headers,
      isRedirect: responseBody.isRedirect,
      reasonPhrase: responseBody.statusMessage,
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _adapter.close(force: false);
  }

  /// 命中条件：200 + JSON + images/{generations,edits} 路径。
  /// SSE（text/event-stream）不缓冲，保持流式透传。
  static bool _shouldPatchImagesUsage(
    http.BaseRequest request,
    int? statusCode,
    Map<String, String> headers,
  ) {
    if (statusCode != 200) return false;
    final path = request.url.path.toLowerCase();
    if (!path.endsWith('/images/generations') &&
        !path.endsWith('/images/edits')) {
      return false;
    }
    final contentType = headers['content-type'] ?? '';
    return contentType.contains('json');
  }

  static Future<Uint8List> _readAndPatchImagesResponse(
    Stream<Uint8List> stream,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) {
        _patchImagesUsage(decoded['usage']);
        return Uint8List.fromList(utf8.encode(jsonEncode(decoded)));
      }
    } catch (_) {
      // 不是合法 JSON / UTF-8 → 透传原字节，让上层报真实错误
    }
    return bytes;
  }

  /// 给 usage 内部缺失的 int 字段补 0。
  ///
  /// openai_dart 4.x 要求 `usage.input_tokens_details.{text_tokens,image_tokens}`
  /// 是非空 int，但代理常返回空对象 `{}` 或省略字段。这里只补默认值，不覆盖
  /// 已有数据。
  static void _patchImagesUsage(Object? usage) {
    if (usage is! Map<String, dynamic>) return;
    usage['total_tokens'] ??= 0;
    usage['input_tokens'] ??= 0;
    usage['output_tokens'] ??= 0;

    final inputDetails = usage['input_tokens_details'];
    if (inputDetails == null) {
      usage['input_tokens_details'] = <String, dynamic>{
        'text_tokens': 0,
        'image_tokens': 0,
      };
    } else if (inputDetails is Map<String, dynamic>) {
      inputDetails['text_tokens'] ??= 0;
      inputDetails['image_tokens'] ??= 0;
    }

    final outputDetails = usage['output_tokens_details'];
    if (outputDetails is Map<String, dynamic>) {
      outputDetails['text_tokens'] ??= 0;
      outputDetails['image_tokens'] ??= 0;
    }
  }

  static Map<String, String> _flattenHeaders(
    Map<String, List<String>> headers,
  ) {
    return {
      for (final entry in headers.entries)
        entry.key.toLowerCase(): entry.value.join(', '),
    };
  }

  static int? _parseContentLength(Map<String, List<String>> headers) {
    final raw = headers['content-length']?.firstOrNull ??
        headers['Content-Length']?.firstOrNull;
    if (raw == null) return null;
    return int.tryParse(raw);
  }
}
