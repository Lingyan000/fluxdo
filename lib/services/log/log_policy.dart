import 'dart:convert';
import 'dart:math';

/// 落盘与导出共用的边界：稳定字段、敏感值过滤、单条容量。
class LogPolicy {
  static final String sessionId =
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(1 << 32).toRadixString(36)}';
  static int _sequence = 0;
  static String newTraceId() => '$sessionId-${++_sequence}';
  static final _secret = RegExp(
    r'^(authorization|proxy-authorization|cookie|set-cookie|password|token|access_token|refresh_token|api_key|apikey|secret|tls_session_cache_key|x-csrf-token)$',
    caseSensitive: false,
  );
  static final _url = RegExp(r'https?://[^\s<>"\x27]+');
  // 自定义解析地址可能把密钥放在路径中；设备名称与代理地址也不属于公开诊断信息。
  static final _privateField = RegExp(
    r'^(computer_?name|user_?name|proxy_?(host|address|url)|doh_?(server(_?ech)?|url))$',
    caseSensitive: false,
  );
  static String cleanText(String text) {
    final bounded = text.length > 8192 ? text.substring(0, 8192) : text;
    // 兼容历史版本已经写入消息正文的配置摘要。
    var value = bounded.replaceAllMapped(
      RegExp(r'(\bRequest\s+[A-Z]+)\s+(?:https?://|/)[^\s]+'),
      (m) => '${m[1]} [redacted]',
    ).replaceAllMapped(
      RegExp(
        r'(Invalid DOH URL|Unsupported DOH URL scheme|Missing host in DOH URL|Missing URL scheme)[^\r\n]*',
        caseSensitive: false,
      ),
      (m) => '${m[1]}: [redacted]',
    ).replaceAllMapped(
      RegExp(r'\bDoH\s+https?://[^\s，,）)]+', caseSensitive: false),
      (_) => 'DoH [redacted]',
    ).replaceAllMapped(
      RegExp(
        r'((?:应用|系统)?代理|\bproxy)\s+(?:(?:https?|socks5?h?|ss)://)?(?:[^\s，,）)]+@)?(?:\[[0-9a-f:]+\]|[a-z0-9_.:-]+):\d+',
        caseSensitive: false,
      ),
      (m) => '${m[1]} [redacted]',
    );
    value = value.replaceAllMapped(_url, (m) {
      final uri = Uri.tryParse(m[0]!);
      if (uri == null) return '[invalid-url]';
      return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}${uri.path}';
    });
    // 同时覆盖完整 URL、相对路径及历史消息；保留接口后缀便于定位请求。
    value = value.replaceAllMapped(
      RegExp(r'(/u/)[^/\s?#<>"\x27]+', caseSensitive: false),
      (m) => '${m[1]}[user]${m[0]!.endsWith('.json') ? '.json' : ''}',
    ).replaceAllMapped(
      RegExp(r'(/user_avatar/[^/\s]+/)[^/\s?#<>"\x27]+', caseSensitive: false),
      (m) => '${m[1]}[user]',
    );
    value = value.replaceAll(
      RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
      'Bearer [redacted]',
    );
    value = value.replaceAllMapped(
      RegExp(
        r'(authorization|cookie|set-cookie|password|token|api_key|x-csrf-token)\s*[:=]\s*[^\r\n]+',
        caseSensitive: false,
      ),
      (m) => '${m[1]}=[redacted]',
    );
    return value.length > 4096
        ? '${value.substring(0, 4096)}…[truncated]'
        : value;
  }

  static Object? sanitize(Object? value) {
    var remaining = 256;
    Object? walk(Object? item, int depth) {
      if (--remaining < 0) return '[node-limit]';
      if (depth > 6) return '[depth-limit]';
      if (item is Map) {
        return {
          for (final e in item.entries.take(64))
            cleanText(e.key.toString()): (_secret.hasMatch(e.key.toString()) ||
                    _privateField.hasMatch(e.key.toString()))
                ? '[redacted]'
                : walk(e.value, depth + 1),
        };
      }
      if (item is Iterable) {
        return item.take(64).map((v) => walk(v, depth + 1)).toList();
      }
      if (item == null || item is num || item is bool) return item;
      return cleanText(item.toString());
    }

    return walk(value, 0);
  }

  static Map<String, dynamic> normalize(Map<String, dynamic> source) {
    final entry = Map<String, dynamic>.from(sanitize(source) as Map);
    entry.addAll({
      'schemaVersion': 2,
      'sessionId': sessionId,
      'seq': ++_sequence,
      'timestamp': source['timestamp'] ?? DateTime.now().toIso8601String(),
      'level': source['level'] == 'warn'
          ? 'warning'
          : source['level'] ?? 'info',
      'type': source['type'] ?? 'general',
      'event': source['event'] ?? source['type'] ?? 'message',
    });
    if (utf8.encode(jsonEncode(entry)).length > 16 * 1024) {
      final retained = <String, dynamic>{
        for (final key in [
          'schemaVersion',
          'sessionId',
          'seq',
          'timestamp',
          'level',
          'type',
          'event',
          'message',
          'traceId',
          'attemptId',
          'coreRequestId',
          'errorType',
        ])
          if (entry.containsKey(key)) key: entry[key],
      };
      retained['truncated'] = true;
      return retained;
    }
    return entry;
  }

  /// 默认导出仍在本地保留的历史；需要当前启动时显式传 fullHistory: false。
  static String export(
    String content, {
    bool fullHistory = true,
    Iterable<Map<String, dynamic>> headers = const [],
  }) {
    final rows = <Map<String, dynamic>>[];
    var invalid = 0;
    for (final line in const LineSplitter().convert(content)) {
      try {
        final row = jsonDecode(line) as Map<String, dynamic>;
        if (fullHistory || row['sessionId'] == sessionId) {
          rows.add(Map<String, dynamic>.from(sanitize(row) as Map));
        }
      } catch (_) {
        invalid++;
      }
    }
    final levels = <String, int>{};
    final events = <String, int>{};
    for (final row in rows) {
      levels.update('${row['level']}', (n) => n + 1, ifAbsent: () => 1);
      events.update(
        '${row['event'] ?? row['type']}',
        (n) => n + 1,
        ifAbsent: () => 1,
      );
    }
    final prefix = headers.map((header) => '${jsonEncode(sanitize(header))}\n').join();
    return '$prefix${jsonEncode({'_header': 'diagnostic_summary', 'schemaVersion': 2, 'sessionId': sessionId, 'scope': fullHistory ? 'retained_history' : 'current_session', 'entries': rows.length, 'levels': levels, 'events': events, 'invalidLines': invalid})}\n${rows.map(jsonEncode).join('\n')}\n';
  }
}
