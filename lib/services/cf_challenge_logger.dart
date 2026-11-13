import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'log/log_writer.dart';
import 'network/doh/network_settings_service.dart';
import 'network/proxy/proxy_settings_service.dart';
import 'network/vpn_auto_toggle_service.dart';

/// CF 验证日志服务
///
/// 记录 Cloudflare 验证相关的详细信息，便于诊断问题。
/// 输出到统一 JSONL（type: cf_challenge），在应用日志页按「CF 验证」筛选查看。
/// 仅开发者模式启用（logAccessIps 会发起网络探测，必须保持门控）。
class CfChallengeLogger {
  CfChallengeLogger._();

  static bool _enabled = false;
  static const Duration _ipLogCooldown = Duration(minutes: 2);
  static final Map<String, DateTime> _lastIpLogAt = {};

  /// 初始化日志
  static void init() {
    setEnabled(true);
  }

  /// 设置启用状态
  static void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (_enabled) {
      log('=== CF Challenge Log Started ===');
    }
  }

  static bool get isEnabled => _enabled;

  /// 仅读取已有内存状态，常规挑战日志也可调用，不触发网络或平台查询。
  /// VPN 检测可能漏报；这些字段描述检测/配置状态，实际出口需对齐服务端记录。
  static Map<String, dynamic> networkContext() {
    final settings = NetworkSettingsService.instance;
    final core = settings.coreService.status;
    final vpn = VpnAutoToggleService.instance;
    return {
      'networkSettingsVersion': settings.version,
      'dohConfigured': settings.current.dohEnabled,
      'appProxyConfigured': ProxySettingsService.instance.current.isValid,
      'systemProxyConfigured': core.systemProxy,
      'coreRunning': core.running,
      'coreWebViewMitmEnabled': core.webViewMitm,
      'webViewProxyOverrideRegistered': settings.webViewProxyOverrideRegistered,
      'vpnDetectionReportedActive': vpn.vpnActive,
      'vpnDetectionMode': vpn.detectionMode.name,
    };
  }

  /// 写入一条 CF 验证日志
  static void log(
    String message, {
    String level = 'info',
    Map<String, dynamic>? fields,
  }) {
    if (!_enabled) return;
    debugPrint('[CF] $message');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': 'cf_challenge',
      'message': message,
      ...?fields,
    });
  }

  /// 记录 Cookie 同步详情
  static void logCookieSync({
    required String direction,
    required List<CookieLogEntry> cookies,
  }) {
    if (!_enabled) return;
    log(
      '[COOKIE] $direction - ${cookies.length} cookies',
      fields: {
        'direction': direction,
        'cookies': [
          for (final c in cookies)
            {
              'name': c.name,
              'domain': c.domain,
              'path': c.path,
              'expires': c.expires?.toIso8601String(),
              'valueLength': c.valueLength,
            },
        ],
      },
    );
  }

  /// 记录验证开始
  static void logVerifyStart(String url) {
    log('[VERIFY] Start manual verify, url=$url');
  }

  /// 记录客户端/服务端 IP（用于 CF 验证诊断）
  static Future<void> logAccessIps({
    required String url,
    String? context,
  }) async {
    if (!_enabled) return;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      log('[IP]${_formatContext(context)} host=unknown');
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

    log('[IP]${_formatContext(context)} host=$host client=$clientText server=$serverText');
  }

  /// 记录验证检查
  static void logVerifyCheck({
    required int checkCount,
    required bool isChallenge,
    String? cfClearance,
    bool clearanceChanged = false,
  }) {
    log('[VERIFY] Check #$checkCount: isChallenge=$isChallenge, hasClearance=${cfClearance != null}, clearanceChanged=$clearanceChanged');
  }

  /// 记录验证结果
  static void logVerifyResult({
    required bool success,
    String? reason,
  }) {
    if (success) {
      log('[VERIFY] Result: SUCCESS${reason != null ? ' ($reason)' : ''}');
    } else {
      log(
        '[VERIFY] Result: FAILED${reason != null ? ' ($reason)' : ''}',
        level: 'warning',
      );
    }
  }

  /// 记录拦截器检测到 CF 验证
  static void logInterceptorDetected({
    required String url,
    required int statusCode,
  }) {
    log('[INTERCEPTOR] CF challenge detected: $statusCode $url');
  }

  /// 记录拦截器重试
  static void logInterceptorRetry({
    required String url,
    required bool success,
    int? statusCode,
    String? error,
  }) {
    if (success) {
      log('[INTERCEPTOR] Retry success: $statusCode $url');
    } else {
      log('[INTERCEPTOR] Retry failed: $url, error=$error', level: 'warning');
    }
  }

  /// 记录冷却期状态
  static void logCooldown({
    required bool entering,
    DateTime? until,
  }) {
    if (entering) {
      log('[COOLDOWN] Entering cooldown until $until', level: 'warning');
    } else {
      log('[COOLDOWN] Cooldown reset');
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
    } catch (_) {}

    try {
      final addresses = await InternetAddress.lookup(host);
      return addresses.map((a) => a.address).toList();
    } catch (_) {
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
