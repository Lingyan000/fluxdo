import 'package:dio/dio.dart';

import '../log/log_writer.dart';

/// 仅写入明确选择的诊断字段，不序列化异常、文件或签名地址。
class UploadTrace {
  UploadTrace()
    : id = 'upload-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  static int _sequence = 0;
  final String id;

  void event(
    String event, {
    Map<String, Object?> fields = const {},
    Object? error,
  }) {
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'type': 'upload',
      'level': error == null ? 'info' : 'warning',
      'message': event,
      'event': event,
      'uploadTraceId': id,
      ...fields,
      if (error != null)
        'errorType': error is DioException
            ? error.type.name
            : error.runtimeType.toString(),
      if (error is DioException) 'statusCode': error.response?.statusCode,
    });
  }
}
