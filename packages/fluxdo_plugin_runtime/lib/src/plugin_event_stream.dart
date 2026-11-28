import 'dart:convert';

/// SSE 帧保持原始文本；JSON 与业务事件由插件解释。
class PluginServerEvent {
  const PluginServerEvent(this.event, this.data, this.lastEventId);
  final String event;
  final String data;
  final String lastEventId;
}

/// 按 SSE 行协议增量解析，限制未结束的帧，兼容分块 UTF-8、CR/LF 与 BOM。
Stream<PluginServerEvent> decodePluginEventStream(
  Stream<List<int>> source, {
  void Function(int milliseconds)? onRetry,
  int maxFrameLength = 64 * 1024,
  String lastEventId = '',
}) async* {
  var line = StringBuffer(), data = <String>[];
  var event = '', lastId = lastEventId;
  var frameLength = 0;
  var first = true, skipLf = false;
  PluginServerEvent? processLine() {
    final text = line.toString();
    line = StringBuffer();
    if (text.isEmpty) {
      final result = data.isEmpty
          ? null
          : PluginServerEvent(
              event.isEmpty ? 'message' : event,
              data.join('\n'),
              lastId,
            );
      event = '';
      data = [];
      frameLength = 0;
      return result;
    }
    if (text.startsWith(':')) return null;
    final colon = text.indexOf(':');
    final field = colon < 0 ? text : text.substring(0, colon);
    var value = colon < 0 ? '' : text.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'data':
        data.add(value);
      case 'event':
        event = value;
      case 'id':
        if (!value.contains('\u0000') && value.length <= 4096) lastId = value;
      case 'retry':
        if (RegExp(r'^\d{1,9}$').hasMatch(value)) {
          onRetry?.call(int.parse(value));
        }
    }
    return null;
  }

  await for (final chunk in source.cast<List<int>>().transform(utf8.decoder)) {
    for (final code in chunk.codeUnits) {
      if (first) {
        first = false;
        if (code == 0xfeff) continue;
      }
      if (skipLf && code == 10) {
        skipLf = false;
        continue;
      }
      skipLf = false;
      if (++frameLength > maxFrameLength) {
        throw const FormatException('stream_frame_too_large');
      }
      if (code == 13 || code == 10) {
        skipLf = code == 13;
        final frame = processLine();
        if (frame != null) yield frame;
      } else {
        line.writeCharCode(code);
      }
    }
  }
  // 没有空行结束的末帧不交付，避免把中断的响应当作完整消息。
}
