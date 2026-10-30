import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// 按原生消息桥能力选择下载编码，并合并同一适配器的并发查询。
/// JS 支持 ArrayBuffer 不代表 AndroidX 消息桥支持，不能发送二进制试探。
class WebViewResponseTransport {
  WebViewResponseTransport({
    required bool isAndroid,
    required Future<bool> Function() supportsArrayBuffer,
    Duration queryTimeout = const Duration(seconds: 3),
  }) : _isAndroid = isAndroid,
       _supportsArrayBuffer = supportsArrayBuffer,
       _queryTimeout = queryTimeout;

  final bool _isAndroid;
  final Future<bool> Function() _supportsArrayBuffer;
  final Duration _queryTimeout;
  Future<bool>? _useBase64;

  Future<bool> usesBase64() => _useBase64 ??= _resolve();

  Future<bool> _resolve() async {
    if (!_isAndroid) return false;
    try {
      return !await _supportsArrayBuffer().timeout(_queryTimeout);
    } catch (_) {
      // 查询失败或超时不能冒险发送二进制；此实例继续使用安全编码。
      return true;
    }
  }
}

/// WebView 下载响应的数据编码，不改变 fetch、Cookie 或响应头处理。
abstract final class WebViewResponseCodec {
  /// 每条字符串消息最多携带 24 KiB 原始数据（Base64 为 32 KiB）。
  static const chunkSize = 24 * 1024;

  /// 返回实际注入页面的发送函数，供适配器与协议回归测试共同使用。
  static String buildSenderScript({required bool useBase64}) {
    if (!useBase64) {
      return '''
          const sendBuffer = function(buffer) {
            if (!buffer || buffer.byteLength === 0) return;
            try {
              responsePort.postMessage(buffer, [buffer]);
            } catch (_) {
              responsePort.postMessage(buffer);
            }
          };
''';
    }

    // 不对整张图片展开参数或编码，避免大图触发调用栈/消息尺寸限制。
    return '''
          const sendBuffer = function(buffer) {
            if (!buffer || buffer.byteLength === 0) return;
            const bytes = new Uint8Array(buffer);
            for (let offset = 0; offset < bytes.length; offset += $chunkSize) {
              const end = Math.min(offset + $chunkSize, bytes.length);
              let binary = '';
              for (let index = offset; index < end; index++) {
                binary += String.fromCharCode(bytes[index]);
              }
              responsePort.postMessage(JSON.stringify({
                kind: 'chunk',
                requestId: requestId,
                encoding: 'base64',
                data: btoa(binary)
              }));
            }
          };
''';
  }

  /// 非数据控制消息返回 null；损坏的数据消息交给请求错误处理，不能静默丢块。
  static Uint8List? decodeChunk(Map<dynamic, dynamic> message) {
    if (message['kind'] != 'chunk') return null;
    if (message['encoding'] != 'base64' || message['data'] is! String) {
      throw const FormatException('无效的 WebView 响应数据块');
    }
    final encoded = message['data'] as String;
    if (encoded.length > chunkSize ~/ 3 * 4) {
      throw const FormatException('WebView 响应数据块超出大小限制');
    }
    return base64Decode(encoded);
  }
}
