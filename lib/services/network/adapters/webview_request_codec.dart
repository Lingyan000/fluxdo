import 'dart:async';
import 'dart:convert';
import 'webview_operation_guard.dart';
import 'dart:typed_data';

/// 上传消息编码。协议在读取一次性请求流之前选定，不在失败后重读流。
abstract final class WebViewRequestCodec {
  static const chunkSize = 24 * 1024;

  /// 逐块等待原生发送完成；不把整个 multipart 请求编码成大字符串。
  static Future<void> pipe(
    Stream<Uint8List> stream, {
    required bool useBase64,
    required Future<void> Function(Object payload) send,
    WebViewOperationGuard? guard,
  }) async {
    final limit = useBase64 ? chunkSize : 64 * 1024;
    final iterator = StreamIterator<Uint8List>(stream);
    try {
      while (await (guard == null
          ? iterator.moveNext()
          : guard.run(iterator.moveNext))) {
        final chunk = iterator.current;
        for (var offset = 0; offset < chunk.length; offset += limit) {
          final end = (offset + limit < chunk.length)
              ? offset + limit
              : chunk.length;
          final bytes = Uint8List.sublistView(chunk, offset, end);
          Future<void> sendChunk() => send(
            useBase64
                ? jsonEncode({
                    'kind': 'chunk',
                    'encoding': 'base64',
                    'data': base64Encode(bytes),
                  })
                : bytes,
          );
          await (guard == null ? sendChunk() : guard.run(sendChunk));
        }
      }
    } finally {
      // 取消订阅不等待可能卡住的上游清理。
      unawaited(iterator.cancel().catchError((Object _) {}));
    }
  }

  /// 与生产桥共用的解码分支；控制消息继续由原桥处理。
  static const receiverScript =
      '''
                    case 'chunk':
                      if (message.encoding !== 'base64' ||
                          typeof message.data !== 'string' ||
                          message.data.length > ${chunkSize ~/ 3 * 4}) {
                        throw new Error('Invalid request body chunk');
                      }
                      var binary = atob(message.data);
                      var bytes = new Uint8Array(binary.length);
                      for (var i = 0; i < binary.length; i++) {
                        bytes[i] = binary.charCodeAt(i);
                      }
                      state.chunks.push(bytes);
                      break;
''';
}
