import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../constants.dart';
import '../network/adapters/cronet_fallback_service.dart';
import '../network/doh/network_settings_service.dart';
import '../network/health/network_health_controller.dart';
import '../network/proxy/proxy_settings_service.dart';
import '../../l10n/s.dart';
import 'log_writer.dart';

/// 日志文件管理工具
class LoggerUtils {
  LoggerUtils._();

  /// 获取日志文件
  static Future<File> getLogFile() => LogWriter.getLogFile();

  /// 生成带设备/APP 头信息的分享文件，返回临时文件路径
  static Future<String> getShareFilePath() async {
    // 分享前补一条网络健康快照:用户反馈网络问题时,日志里往往只有"某请求
    // 失败"的结果,没有引擎/降级/盾态/凭证这些状态,归因只能靠猜。
    NetworkHealthController.instance.dumpToLog('log_share');
    await LogWriter.instance.flushNow();

    final header = await _buildShareHeader();
    final logContent = await LogWriter.readAllContent();

    final logFile = await getLogFile();
    final dir = logFile.parent;
    final shareFile = File('${dir.path}/app_log_share.jsonl');
    await shareFile.writeAsString('$header$logContent');
    return shareFile.path;
  }

  /// 获取人类可读的设备和应用信息文本（用于复制）
  static Future<String> getDeviceInfoText() async {
    final buf = StringBuffer();

    try {
      final pkg = await PackageInfo.fromPlatform();
      buf.writeln('应用: ${pkg.appName}');
      buf.writeln('版本: ${pkg.version} (${pkg.buildNumber})');
      buf.writeln('包名: ${pkg.packageName}');
    } catch (_) {}

    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        buf.writeln('平台: Android ${info.version.release} (SDK ${info.version.sdkInt})');
        buf.writeln('设备: ${info.brand} ${info.model}');
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        buf.writeln('平台: iOS ${info.systemVersion}');
        buf.writeln('设备: ${info.utsname.machine}');
      } else if (Platform.isMacOS) {
        final info = await deviceInfo.macOsInfo;
        buf.writeln('平台: macOS ${info.majorVersion}.${info.minorVersion}.${info.patchVersion}');
        buf.writeln('设备: ${info.model} (${info.arch})');
      } else if (Platform.isLinux) {
        final info = await deviceInfo.linuxInfo;
        buf.writeln('平台: ${info.prettyName}');
      } else if (Platform.isWindows) {
        final info = await deviceInfo.windowsInfo;
        buf.writeln('平台: Windows (${info.buildNumber})');
        buf.writeln('设备: ${info.computerName}');
      }
    } catch (_) {}

    // WebView 版本
    final webViewVersion = _parseWebViewVersion();
    if (webViewVersion != null) {
      buf.writeln('WebView: $webViewVersion');
    }

    // 网络配置信息
    final networkConfig = _getNetworkConfigLines();
    for (final line in networkConfig) {
      buf.writeln(line);
    }

    return buf.toString().trimRight();
  }

  /// 构建分享文件头部的设备和应用信息（JSONL 格式）
  static Future<String> _buildShareHeader() async {
    final buf = StringBuffer();

    try {
      final pkg = await PackageInfo.fromPlatform();
      buf.writeln(jsonEncode({
        '_header': 'app_info',
        'appName': pkg.appName,
        'version': pkg.version,
        'buildNumber': pkg.buildNumber,
        'packageName': pkg.packageName,
      }));
    } catch (_) {}

    try {
      final deviceInfo = DeviceInfoPlugin();
      Map<String, dynamic> device;
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        device = {
          '_header': 'device_info',
          'platform': 'Android',
          'brand': info.brand,
          'model': info.model,
          'sdkInt': info.version.sdkInt,
          'release': info.version.release,
        };
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        device = {
          '_header': 'device_info',
          'platform': 'iOS',
          'model': info.utsname.machine,
          'systemVersion': info.systemVersion,
        };
      } else if (Platform.isMacOS) {
        final info = await deviceInfo.macOsInfo;
        device = {
          '_header': 'device_info',
          'platform': 'macOS',
          'model': info.model,
          'osVersion':
              '${info.majorVersion}.${info.minorVersion}.${info.patchVersion}',
          'arch': info.arch,
        };
      } else if (Platform.isLinux) {
        final info = await deviceInfo.linuxInfo;
        device = {
          '_header': 'device_info',
          'platform': 'Linux',
          'prettyName': info.prettyName,
        };
      } else if (Platform.isWindows) {
        final info = await deviceInfo.windowsInfo;
        device = {
          '_header': 'device_info',
          'platform': 'Windows',
          'computerName': info.computerName,
          'buildNumber': info.buildNumber,
        };
      } else {
        device = {'_header': 'device_info', 'platform': Platform.operatingSystem};
      }

      // User-Agent
      device['userAgent'] = AppConstants.userAgent;

      // WebView 版本
      final webViewVersion = _parseWebViewVersion();
      if (webViewVersion != null) {
        device['webViewVersion'] = webViewVersion;
      }

      // 网络配置信息
      device.addAll(_getNetworkConfigMap());

      buf.writeln(jsonEncode(device));
    } catch (_) {}

    return buf.toString();
  }

  /// 从缓存的 User-Agent 中解析 WebView/浏览器引擎版本
  static String? _parseWebViewVersion() {
    final ua = AppConstants.userAgent;
    // Chrome/xxx.x.x.x（Android WebView 和桌面端）
    final chromeMatch = RegExp(r'Chrome/([\d.]+)').firstMatch(ua);
    if (chromeMatch != null) return 'Chrome/${chromeMatch.group(1)}';
    // Safari/xxx（iOS WKWebView）
    final safariMatch = RegExp(r'Version/([\d.]+).*Safari').firstMatch(ua);
    if (safariMatch != null) return 'Safari/${safariMatch.group(1)}';
    return null;
  }

  /// 获取网络配置的可读文本行（用于复制设备信息）
  static List<String> _getNetworkConfigLines() {
    final lines = <String>[];

    // 适配器
    final cronet = CronetFallbackService.instance;
    lines.add('适配器: ${cronet.hasFallenBack ? 'Dart IO' : 'Cronet'}');

    // DOH 配置
    final doh = NetworkSettingsService.instance.current;
    if (doh.dohEnabled) {
      final serverName = _findDohServerName(doh.selectedServerUrl);
      final parts = <String>[serverName];
      if (doh.preferIPv6) parts.add('IPv6');
      lines.add('DOH: ${parts.join(', ')}');
    } else {
      lines.add(S.current.deviceInfo_dohOff);
    }

    // HTTP 代理
    final proxy = ProxySettingsService.instance.current;
    if (proxy.isValid) {
      lines.add('代理: ${proxy.host}:${proxy.port}');
    } else {
      lines.add(S.current.deviceInfo_proxyOff);
    }

    return lines;
  }

  /// 获取网络配置的 Map（用于分享日志头）
  static Map<String, dynamic> _getNetworkConfigMap() {
    final map = <String, dynamic>{};

    final cronet = CronetFallbackService.instance;
    map['adapter'] = cronet.hasFallenBack ? 'Dart IO' : 'Cronet';

    final doh = NetworkSettingsService.instance.current;
    map['dohEnabled'] = doh.dohEnabled;
    if (doh.dohEnabled) {
      map['dohServer'] = doh.selectedServerUrl;
      map['preferIPv6'] = doh.preferIPv6;
    }

    final proxy = ProxySettingsService.instance.current;
    map['proxyEnabled'] = proxy.isValid;
    if (proxy.isValid) {
      map['proxyHost'] = '${proxy.host}:${proxy.port}';
    }

    return map;
  }

  /// 根据 DOH 服务器 URL 查找名称
  static String _findDohServerName(String url) {
    final servers = NetworkSettingsService.instance.servers;
    for (final server in servers) {
      if (server.url == url) return server.name;
    }
    return url;
  }

  /// 读取并解析 JSONL，逆序返回（最新在前）。
  /// 解析放 isolate，避免数 MB JSONL 在主线程 jsonDecode 造成掉帧。
  /// 对旧格式条目（无 level/type 字段）默认当作 error + general
  static Future<List<Map<String, dynamic>>> readLogEntries() async {
    final content = await LogWriter.readAllContent();
    if (content.trim().isEmpty) return [];
    return compute(_parseLogEntries, content);
  }

  /// isolate 入口：JSONL 文本 → 条目列表（最新在前）
  static List<Map<String, dynamic>> _parseLogEntries(String content) {
    final lines = content.split('\n');
    final entries = <Map<String, dynamic>>[];

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        // 兼容旧格式
        json['level'] ??= 'error';
        json['type'] ??= 'general';
        // 旧格式的 message 在 customParameters.message 中
        if (json['message'] == null) {
          final customParams =
              json['customParameters'] as Map<String, dynamic>?;
          json['message'] = customParams?['message']?.toString() ??
              json['error']?.toString();
          // 同时提升 tag
          json['tag'] ??= customParams?['tag']?.toString();
        }
        entries.add(json);
      } catch (_) {
        // 跳过无法解析的行
      }
    }

    return entries.reversed.toList();
  }

  /// 读取原始文本（用于复制/分享）
  static Future<String> readLogContent() => LogWriter.readAllContent();

  /// 清空日志
  static Future<void> clearLogs() => LogWriter.instance.clearAll();
}
