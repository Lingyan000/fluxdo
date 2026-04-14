import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cross_file/cross_file.dart';

import '../l10n/s.dart';
import '../utils/share_utils.dart';

/// 认证日志服务 - 专门记录登录/登出相关事件
/// 支持文件日志持久化、开关控制和日志导出
class AuthLogService {
  static final AuthLogService _instance = AuthLogService._internal();
  factory AuthLogService() => _instance;
  AuthLogService._internal();

  static const String _enabledKey = 'auth_log_enabled';
  static const String _logFileName = 'auth_log.txt';
  
  Logger? _logger;
  File? _logFile;
  bool _enabled = true;
  bool _initialized = false;

  /// 初始化日志服务
  Future<void> initialize() async {
    if (_initialized) return;
    
    try {
      // 获取应用文档目录
      final directory = await getApplicationDocumentsDirectory();
      _logFile = File('${directory.path}/$_logFileName');
      
      // 创建文件输出
      final fileOutput = FileOutput(file: _logFile!);
      
      _logger = Logger(
        printer: SimplePrinter(printTime: true, colors: false),
        output: MultiOutput([
          if (kDebugMode) ConsoleOutput(),
          fileOutput,
        ]),
        filter: ProductionFilter(),
      );
      
      // 读取开关状态
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_enabledKey) ?? true;
      
      _initialized = true;
      debugPrint('[AuthLogService] 初始化完成，日志文件: ${_logFile!.path}');
    } catch (e) {
      debugPrint('[AuthLogService] 初始化失败: $e');
    }
  }

  /// 确保已初始化
  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await initialize();
    }
  }

  /// 设置开关状态
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    debugPrint('[AuthLogService] 开关状态: $enabled');
  }

  /// 获取开关状态
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? true;
    return _enabled;
  }

  /// 记录认证失效事件
  Future<void> logAuthInvalid({
    required String source,
    required String reason,
    Map<String, dynamic>? extra,
  }) async {
    await _ensureInitialized();
    if (!_enabled || _logger == null) return;
    
    final message = '[AUTH_INVALID] source=$source reason=$reason${extra != null ? ' extra=$extra' : ''}';
    _logger!.w(message);
  }

  /// 记录 WebView 验证事件
  Future<void> logWebViewVerify({
    required bool success,
    String? reason,
    Map<String, dynamic>? extra,
  }) async {
    await _ensureInitialized();
    if (!_enabled || _logger == null) return;
    
    final message = '[WEBVIEW_VERIFY] success=$success${reason != null ? ' reason=$reason' : ''}${extra != null ? ' extra=$extra' : ''}';
    if (success) {
      _logger!.i(message);
    } else {
      _logger!.w(message);
    }
  }

  /// 记录一般认证事件
  Future<void> log(String event, {Map<String, dynamic>? details}) async {
    await _ensureInitialized();
    if (!_enabled || _logger == null) return;
    
    final message = '[AUTH] $event${details != null ? ' details=$details' : ''}';
    _logger!.i(message);
  }

  /// 获取日志文件内容
  Future<String?> getLogContent() async {
    await _ensureInitialized();
    if (_logFile == null) return null;
    
    try {
      if (await _logFile!.exists()) {
        return await _logFile!.readAsString();
      }
    } catch (e) {
      debugPrint('[AuthLogService] 读取日志失败: $e');
    }
    return null;
  }

  /// 获取日志文件路径
  Future<String?> getLogFilePath() async {
    await _ensureInitialized();
    return _logFile?.path;
  }

  /// 分享日志文件
  Future<void> shareLogFile() async {
    await _ensureInitialized();
    if (_logFile == null) return;
    
    try {
      if (await _logFile!.exists()) {
        await ShareUtils.shareOrSaveFile(
          XFile(_logFile!.path),
          subject: S.current.auth_logSubject,
        );
      }
    } catch (e) {
      debugPrint('[AuthLogService] 分享日志失败: $e');
    }
  }

  /// 清除日志
  Future<void> clearLogs() async {
    await _ensureInitialized();
    if (_logFile == null) return;
    
    try {
      if (await _logFile!.exists()) {
        await _logFile!.writeAsString('');
        debugPrint('[AuthLogService] 日志已清除');
      }
    } catch (e) {
      debugPrint('[AuthLogService] 清除日志失败: $e');
    }
  }
}

/// 文件输出器
class FileOutput extends LogOutput {
  final File file;
  IOSink? _sink;

  FileOutput({required this.file});

  @override
  Future<void> init() async {
    _sink = file.openWrite(mode: FileMode.append);
  }

  @override
  void output(OutputEvent event) {
    _sink ??= file.openWrite(mode: FileMode.append);
    for (var line in event.lines) {
      _sink?.writeln(line);
    }
    _sink?.flush();
  }

  @override
  Future<void> destroy() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }
}
