import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../network/flux_request_spec.dart';
import 'upload_trace.dart';
import 'upload_progress.dart';

/// 控制请求沿用站点客户端，签名 PUT 使用无站点凭据的独立客户端。
class S3MultipartUpload {
  S3MultipartUpload(this.control, {Dio? storage, UploadTrace? trace})
    : trace = trace ?? UploadTrace(),
      storage =
          storage ??
          Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));

  final UploadTrace trace;
  final Dio control;
  final Dio storage;

  static int chunkSize(int size) => size >= 500 * 1024 * 1024
      ? 20 * 1024 * 1024
      : size >= 100 * 1024 * 1024
      ? 10 * 1024 * 1024
      : 5 * 1024 * 1024;

  Future<Map<String, dynamic>> _post(
    String action,
    Map<String, dynamic> data, {
    CancelToken? cancelToken,
  }) async {
    checkUploadCancelled(cancelToken);
    final watch = Stopwatch()..start();
    trace.event('multipart_control_start', fields: {'action': action});
    try {
      final response = await control.post<dynamic>(
        '/uploads/$action.json',
        data: data,
        cancelToken: cancelToken,
        options: Options(
          contentType: Headers.jsonContentType,
          receiveTimeout: const Duration(minutes: 2),
          followRedirects: false,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 300,
          extra: {
            '_networkLogFields': {'uploadTraceId': trace.id},
            FluxRequestKeys.noRecovery: true,
            FluxRequestKeys.skipRedirect: true,
          },
        ),
      );
      if (response.data is! Map) throw const FormatException('无效的分片上传响应');
      trace.event(
        'multipart_control_complete',
        fields: {
          'action': action,
          'durationMs': watch.elapsedMilliseconds,
          'statusCode': response.statusCode,
        },
      );
      return Map<String, dynamic>.from(response.data as Map);
    } catch (error) {
      trace.event(
        'multipart_control_failed',
        fields: {'action': action, 'durationMs': watch.elapsedMilliseconds},
        error: error,
      );
      rethrow;
    }
  }

  static String _requiredString(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('缺少上传字段: $key');
    }
    return value;
  }

  Future<Map<String, dynamic>> upload(
    File file,
    String filename, {
    CancelToken? cancelToken,
    UploadProgressCallback? onProgress,
  }) async {
    final watch = Stopwatch()..start();
    String? externalId;
    RandomAccessFile? input;
    try {
      checkUploadCancelled(cancelToken);
      onProgress?.call(const UploadProgress(phase: UploadPhase.preparing));
      input = await file.open();
      final size = await input.length();
      checkUploadCancelled(cancelToken);
      var completedBytes = 0;
      final bytesPerPart = chunkSize(size);
      final count = (size / bytesPerPart).ceil();
      if (count < 1 || count > 10000) {
        throw const FormatException('文件大小不适合分片上传');
      }
      trace.event(
        'multipart_start',
        fields: {
          'fileBytes': size,
          'partBytes': bytesPerPart,
          'partCount': count,
        },
      );
      final created = await _post('create-multipart', {
        'file_name': filename,
        'file_size': size,
        'upload_type': 'composer',
      }, cancelToken: cancelToken);
      externalId = _requiredString(created, 'external_upload_identifier');
      final identifier = _requiredString(created, 'unique_identifier');
      final parts = <Map<String, dynamic>>[];
      for (var start = 1; start <= count; start += 5) {
        final numbers = [
          for (var n = start; n < start + 5 && n <= count; n++) n,
        ];
        final signed = await _post('batch-presign-multipart-parts', {
          'unique_identifier': identifier,
          'part_numbers': numbers,
        }, cancelToken: cancelToken);
        final urls = signed['presigned_urls'];
        if (urls is! Map) throw const FormatException('缺少分片签名');
        for (final number in numbers) {
          final url = urls['$number'];
          final uri = url is String ? Uri.tryParse(url) : null;
          if (uri == null ||
              uri.scheme != 'https' ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              uri.hasFragment) {
            throw const FormatException('无效的分片上传地址');
          }
          final remaining = size - (number - 1) * bytesPerPart;
          final expected = remaining < bytesPerPart ? remaining : bytesPerPart;
          checkUploadCancelled(cancelToken);
          final bytes = await input.read(expected);
          if (bytes.length != expected) {
            throw const FileSystemException('上传文件已变化');
          }
          var partHighWater = 0;
          final etag = await _put(
            uri,
            bytes,
            number,
            cancelToken: cancelToken,
            onSendProgress: (sent, _) {
              // 同一分片重试只更新高水位，避免累计重复字节或进度倒退。
              final current = sent.clamp(0, expected);
              if (current > partHighWater) partHighWater = current;
              onProgress?.call(
                UploadProgress(
                  phase: UploadPhase.uploading,
                  sentBytes: completedBytes + partHighWater,
                  totalBytes: size,
                ),
              );
            },
          );
          completedBytes += expected;
          onProgress?.call(
            UploadProgress(
              phase: UploadPhase.uploading,
              sentBytes: completedBytes,
              totalBytes: size,
            ),
          );
          parts.add({'part_number': number, 'etag': etag});
        }
      }
      onProgress?.call(
        UploadProgress(
          phase: UploadPhase.processing,
          sentBytes: size,
          totalBytes: size,
        ),
      );
      final result = await _post('complete-multipart', {
        'unique_identifier': identifier,
        'parts': parts,
      }, cancelToken: cancelToken);
      trace.event(
        'multipart_complete',
        fields: {'durationMs': watch.elapsedMilliseconds},
      );
      return result;
    } catch (error) {
      trace.event(
        'multipart_failed',
        fields: {'durationMs': watch.elapsedMilliseconds},
        error: error,
      );
      if (externalId != null) {
        final cleanupToken = CancelToken();
        try {
          await _post('abort-multipart', {
            'external_upload_identifier': externalId,
          }, cancelToken: cleanupToken).timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              cleanupToken.cancel('清理请求超时');
              throw const FileSystemException('清理请求超时');
            },
          );
        } catch (cleanupError) {
          trace.event('multipart_cleanup_failed', error: cleanupError);
          // 清理失败不覆盖原始上传错误，也不自动重新创建上传。
        }
      }
      rethrow;
    } finally {
      await input?.close();
      storage.close(force: true);
    }
  }

  Future<String> _put(
    Uri uri,
    Uint8List bytes,
    int partNumber, {
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
  }) async {
    for (var attempt = 0; ; attempt++) {
      checkUploadCancelled(cancelToken);
      final watch = Stopwatch()..start();
      final fields = <String, Object?>{
        'partNumber': partNumber,
        'attempt': attempt + 1,
        'bytes': bytes.length,
      };
      trace.event('multipart_part_start', fields: fields);
      try {
        final response = await storage.putUri<dynamic>(
          uri,
          data: Stream.value(bytes),
          cancelToken: cancelToken,
          onSendProgress: onSendProgress,
          options: Options(
            headers: {Headers.contentLengthHeader: bytes.length},
            contentType: 'application/octet-stream',
            responseType: ResponseType.plain,
            followRedirects: false,
            maxRedirects: 0,
            sendTimeout: const Duration(minutes: 2),
            receiveTimeout: const Duration(minutes: 2),
            validateStatus: (s) => s != null && s >= 200 && s < 300,
          ),
        );
        final etag = response.headers.value('etag');
        if (etag == null || etag.isEmpty) {
          throw const FormatException('分片响应缺少 ETag');
        }
        trace.event(
          'multipart_part_complete',
          fields: {
            ...fields,
            'durationMs': watch.elapsedMilliseconds,
            'statusCode': response.statusCode,
          },
        );
        return etag;
      } catch (error) {
        trace.event(
          'multipart_part_failed',
          fields: {...fields, 'durationMs': watch.elapsedMilliseconds},
          error: error,
        );
        checkUploadCancelled(cancelToken);
        if (error is! DioException || CancelToken.isCancel(error)) rethrow;
        final status = error.response?.statusCode;
        final retryable =
            error.type == DioExceptionType.connectionError ||
            error.type == DioExceptionType.connectionTimeout ||
            error.type == DioExceptionType.sendTimeout ||
            error.type == DioExceptionType.receiveTimeout ||
            status == 429 ||
            (status != null && status >= 500);
        if (!retryable || attempt >= 2) rethrow;
        trace.event(
          'multipart_part_retry',
          fields: {...fields, 'delayMs': (attempt + 1) * 1000},
        );
        await waitForUpload(
          Future<void>.delayed(Duration(seconds: attempt + 1)),
          cancelToken,
        );
      }
    }
  }
}
