import 'dart:convert';
import 'dart:io';

import 'network/doh/network_settings_service.dart';
import 'package:path_provider/path_provider.dart';

/// CF 验证日志服务
/// 记录 Cloudflare 验证相关的详细信息，便于诊断问题
class CfChallengeLogger {
  static CfChallengeLogger? _instance;
  static File? _logFile;
  static bool _initialized = false;
  static bool _enabled = false;
  static const int _maxLogBytes = 1024 * 1024;
  static const Duration _ipLogCooldown = Duration(minutes: 2);
  static final Map<String, DateTime> _lastIpLogAt = {};

  factory CfChallengeLogger() {
    _instance ??= CfChallengeLogger._();
    return _instance!;
  }

  CfChallengeLogger._();

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      _logFile = File('${logDir.path}/cf_challenge.log');
      if (await _logFile!.exists()) {
        final stat = await _logFile!.stat();
        if (stat.size > _maxLogBytes) {
          await _logFile!.writeAsString('');
        }
      }
      _initialized = true;
    } catch (e) {
      // 忽略初始化错误
    }
  }

  static Future<void> _appendLine(String line) async {
    if (_logFile == null) return;
    try {
      if (await _logFile!.exists()) {
        final size = await _logFile!.length();
        if (size > _maxLogBytes) {
          await _logFile!.writeAsString('');
        }
      }
      await _logFile!.writeAsString(
        '$line\n',
        mode: FileMode.append,
      );
    } catch (e) {
      // 忽略写入错误
    }
  }

  /// 初始化日志文件
  static Future<void> init() async {
    await setEnabled(true);
  }

  /// 设置启用状态
  static Future<void> setEnabled(bool enabled) async {
    if (_enabled == enabled) {
      if (enabled && !_initialized) {
        await _ensureInitialized();
        await log('=== CF Challenge Log Started ===');
      }
      return;
    }
    _enabled = enabled;
    if (_enabled) {
      await _ensureInitialized();
      await log('=== CF Challenge Log Started ===');
    }
  }

  static bool get isEnabled => _enabled;

  /// 写入日志
  static Future<void> log(String message) async {
    if (!_enabled) return;
    if (!_initialized) {
      await _ensureInitialized();
    }
    if (_logFile == null) return;
    try {
      final timestamp = DateTime.now().toIso8601String();
      await _appendLine('[$timestamp] $message');
    } catch (e) {
      // 忽略写入错误
    }
  }

  /// 记录 Cookie 同步详情
  static Future<void> logCookieSync({
    required String direction,
    required List<CookieLogEntry> cookies,
  }) async {
    if (!_enabled) return;
    if (!_initialized) {
      await _ensureInitialized();
    }
    if (_logFile == null) return;
    final timestamp = DateTime.now().toIso8601String();
    final buffer = StringBuffer();
    buffer.write('[$timestamp] [COOKIE] $direction - ${cookies.length} cookies');
    for (final cookie in cookies) {
      buffer.write(
          '\n[$timestamp]   - ${cookie.name}: domain=${cookie.domain}, path=${cookie.path}, expires=${cookie.expires}, valueLen=${cookie.valueLength}');
    }
    await _appendLine(buffer.toString());
  }

  /// 记录验证开始
  static Future<void> logVerifyStart(String url) async {
    await log('[VERIFY] Start manual verify, url=$url');
  }

  /// 记录客户端/服务端 IP（用于 CF 验证诊断）
  static Future<void> logAccessIps({
    required String url,
    String? context,
  }) async {
    if (!_enabled) return;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      await log('[IP]${_formatContext(context)} host=unknown');
      return;
    }

    final host = uri.host;
    final lastLog = _lastIpLogAt[host];
    final now = DateTime.now();
    if (lastLog != null && now.difference(lastLog) < _ipLogCooldown) {
      return;
    }
    _lastIpLogAt[host] = now;

    final clientIp = await _fetchClientIp(uri);
    final serverIps = await _resolveServerIps(host);
    final clientText = (clientIp == null || clientIp.isEmpty) ? 'unknown' : clientIp;
    final serverText = serverIps.isEmpty ? 'unknown' : serverIps.join(', ');

    await log('[IP]${_formatContext(context)} host=$host client=$clientText server=$serverText');
  }

  /// 记录验证检查
  static Future<void> logVerifyCheck({
    required int checkCount,
    required bool isChallenge,
    String? cfClearance,
    bool clearanceChanged = false,
  }) async {
    await log('[VERIFY] Check #$checkCount: isChallenge=$isChallenge, hasClearance=${cfClearance != null}, clearanceChanged=$clearanceChanged');
  }

  /// 记录验证结果
  static Future<void> logVerifyResult({
    required bool success,
    String? reason,
  }) async {
    if (success) {
      await log('[VERIFY] Result: SUCCESS${reason != null ? ' ($reason)' : ''}');
    } else {
      await log('[VERIFY] Result: FAILED${reason != null ? ' ($reason)' : ''}');
    }
  }

  /// 记录拦截器检测到 CF 验证
  static Future<void> logInterceptorDetected({
    required String url,
    required int statusCode,
  }) async {
    await log('[INTERCEPTOR] CF challenge detected: $statusCode $url');
  }

  /// 记录拦截器重试
  static Future<void> logInterceptorRetry({
    required String url,
    required bool success,
    int? statusCode,
    String? error,
  }) async {
    if (success) {
      await log('[INTERCEPTOR] Retry success: $statusCode $url');
    } else {
      await log('[INTERCEPTOR] Retry failed: $url, error=$error');
    }
  }

  /// 记录冷却期状态
  static Future<void> logCooldown({
    required bool entering,
    DateTime? until,
  }) async {
    if (entering) {
      await log('[COOLDOWN] Entering cooldown until $until');
    } else {
      await log('[COOLDOWN] Cooldown reset');
    }
  }

  /// 获取日志文件路径
  static Future<String?> getLogPath() async {
    if (!_initialized) {
      await _ensureInitialized();
    }
    if (_logFile == null) return null;
    return _logFile!.path;
  }

  /// 读取日志内容
  static Future<String?> readLogs() async {
    if (!_initialized) {
      await _ensureInitialized();
    }
    if (_logFile == null || !await _logFile!.exists()) return null;
    return _logFile!.readAsString();
  }

  /// 清除日志
  static Future<void> clear() async {
    if (!_initialized) {
      await _ensureInitialized();
    }
    if (_logFile == null) return;
    try {
      if (await _logFile!.exists()) {
        await _logFile!.writeAsString('');
      }
      await log('=== CF Challenge Log Cleared ===');
    } catch (e) {
      // 忽略清除错误
    }
  }

  static String _formatContext(String? context) {
    if (context == null || context.isEmpty) return '';
    return ' $context';
  }

  static Future<List<String>> _resolveServerIps(String host) async {
    if (host.isEmpty) return const [];
    final parsed = InternetAddress.tryParse(host);
    if (parsed != null) return [parsed.address];

    try {
      final resolver = NetworkSettingsService.instance.resolver;
      final addresses = await resolver.resolveAll(host);
      if (addresses.isNotEmpty) {
        return addresses.map((a) => a.address).toList();
      }
    } catch (e) {
      // Primary resolver failed, falling through to system DNS
    }

    try {
      final addresses = await InternetAddress.lookup(host);
      return addresses.map((a) => a.address).toList();
    } catch (e) {
      stderr.writeln('[CfChallengeLogger] DNS resolve failed for $host: $e');
      return const [];
    }
  }

  static Future<String?> _fetchClientIp(Uri baseUri) async {
    final traceUri = baseUri.replace(path: '/cdn-cgi/trace', query: '');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(traceUri);
      request.followRedirects = true;
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final body = await utf8.decodeStream(response);
      for (final line in body.split('\n')) {
        if (line.startsWith('ip=')) {
          return line.substring(3).trim();
        }
      }
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
    return null;
  }
}

/// Cookie 日志条目
class CookieLogEntry {
  final String name;
  final String? domain;
  final String? path;
  final DateTime? expires;
  final int valueLength;

  CookieLogEntry({
    required this.name,
    this.domain,
    this.path,
    this.expires,
    required this.valueLength,
  });
}
