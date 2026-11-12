import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'log_policy.dart';

import 'package:flutter/widgets.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 统一日志写入器，所有日志通过此类写入同一个 JSONL 文件
///
/// 性能设计：
/// - init() 时解析一次目录并常驻 IOSink，写入路径上没有 platform channel、
///   也没有反复 open/close/fsync
/// - write() 只追加内存缓冲，由「错误级别 / 缓冲条数 / 定时器」三个条件触发批量落盘
/// - 文件超限采用 O(1) 轮换（rename 为 .1 文件），取代旧的全量读写截断
/// - 过期清理只在启动时按轮换文件 mtime 判断，不再全量解析 JSONL
class LogWriter {
  LogWriter._();

  static final LogWriter instance = LogWriter._();

  /// 单代文件上限 2MB（当前代 + 轮换代合计最多 4MB），测试可覆盖
  static int _maxFileSize = 2 * 1024 * 1024;

  static const int _defaultMaxFileSize = 2 * 1024 * 1024;

  /// 测试用：覆盖轮换阈值
  @visibleForTesting
  static set maxFileSizeForTesting(int value) => _maxFileSize = value;

  /// 缓冲条数达到该值立即落盘
  static const int _maxBufferedLines = 64;

  /// 定时落盘间隔
  static const Duration _flushInterval = Duration(seconds: 2);

  /// 日志保留天数，超期的文件在启动时直接删除
  static const int _expireDays = 14;

  /// 当前代日志文件名
  static const String _fileName = 'app_log.jsonl';

  /// 轮换代日志文件名
  static const String _rotatedFileName = 'app_log.1.jsonl';

  /// 旧日志文件名（用于一次性迁移）
  static const String _legacyFileName = 'app_error.jsonl';

  /// 缓存的应用版本号，初始化后自动注入到每条日志
  static String? _appVersion;

  /// 初始化完成标志。未初始化时 write() 只进缓冲：
  /// 不安排定时器、不触发任何文件 IO（widget 测试环境没有
  /// path_provider，且悬挂的 Timer 会让 testWidgets 失败）
  static bool _initialized = false;

  /// 未初始化时缓冲的最大条数，防止 init 失败后无限增长
  static const int _maxPendingLines = 500;

  /// debug 级日志是否落盘（跟随开发者模式，由 AppLogger.setVerbose 控制）
  static bool verboseEnabled = false;

  static File? _file;
  static File? _rotatedFile;

  IOSink? _sink;
  int _currentSize = 0;

  final List<String> _buffer = [];
  int _bufferBytes = 0;
  int _dropped = 0;
  Future<void>? _flushPending;
  static const _maxBufferBytes = 512 * 1024;
  final Map<String, Map<String, dynamic>> _repeats = {};

  void _append(Map<String, dynamic> entry) {
    final line = '${jsonEncode(entry)}\n';
    final bytes = utf8.encode(line).length;
    while (_buffer.isNotEmpty &&
        (_bufferBytes + bytes > _maxBufferBytes ||
            _buffer.length >= _maxPendingLines)) {
      _bufferBytes -= utf8.encode(_buffer.removeAt(0)).length;
      _dropped++;
    }
    _buffer.add(line);
    _bufferBytes += bytes;
  }

  void _flushRepeats() {
    for (final item in _repeats.values) {
      if ((item['suppressed'] as int) > 0) _append(LogPolicy.normalize(item));
    }
    _repeats.clear();
    if (_dropped > 0) {
      final count = _dropped;
      _dropped = 0;
      _append(
        LogPolicy.normalize({
          'level': 'warning',
          'event': 'log_overflow',
          'message': '日志缓冲超限，丢弃最旧记录',
          'dropped': count,
        }),
      );
    }
  }

  Timer? _flushTimer;

  /// 串行化所有文件操作（flush / 轮换 / 清空），避免交错
  Future<void> _io = Future.value();

  AppLifecycleListener? _lifecycleListener;

  /// 初始化：解析目录、迁移旧文件、清理过期文件、打开常驻 sink。
  /// 应用启动时调用一次；调用前的 write() 会先进缓冲，init 后随首次 flush 落盘。
  static Future<void> init() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      _appVersion = '${pkg.version}+${pkg.buildNumber}';
    } catch (_) {}

    try {
      await instance._setup();
    } catch (_) {
      // 初始化失败时静默降级：后续写入走 _ensureFiles 兜底
    }
  }

  /// 测试用：用指定目录初始化，绕过 path_provider 和生命周期监听
  @visibleForTesting
  static Future<void> initForTesting(
    Directory logDir, {
    String? appVersion,
  }) async {
    await resetForTesting();
    _appVersion = appVersion;
    if (!logDir.existsSync()) {
      await logDir.create(recursive: true);
    }
    _file = File('${logDir.path}/$_fileName');
    _rotatedFile = File('${logDir.path}/$_rotatedFileName');
    await instance._setupFiles();
    _initialized = true;
  }

  /// 测试用：关闭 sink 并重置全部状态
  @visibleForTesting
  static Future<void> resetForTesting() async {
    instance._flushTimer?.cancel();
    instance._flushTimer = null;
    instance._buffer.clear();
    instance._bufferBytes = 0;
    instance._dropped = 0;
    instance._repeats.clear();
    await instance._io.catchError((_) {});
    await instance._closeSink();
    _file = null;
    _rotatedFile = null;
    _appVersion = null;
    _initialized = false;
    verboseEnabled = false;
    _maxFileSize = _defaultMaxFileSize;
    instance._currentSize = 0;
  }

  Future<void> _setup() async {
    await _ensureFiles();
    await _setupFiles();
    _initialized = true;
    // 落盘 init 之前缓冲的早期日志
    if (_buffer.isNotEmpty) {
      await _enqueueFlush();
    }

    // 退后台 / 退出时落盘缓冲，避免丢日志
    _lifecycleListener ??= AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached) {
          flushNow();
        }
      },
    );
  }

  /// 过期清理 + 启动轮换检查 + 打开常驻 sink
  Future<void> _setupFiles() async {
    final file = _file;
    final rotatedFile = _rotatedFile;
    if (file == null || rotatedFile == null) return;

    final now = DateTime.now();

    // 过期清理：按文件 mtime 判断，O(1) 取代旧的全量 JSONL 解析
    for (final f in [rotatedFile, file]) {
      try {
        if (f.existsSync() &&
            now.difference(f.lastModifiedSync()).inDays >= _expireDays) {
          await f.delete();
        }
      } catch (_) {}
    }

    // 启动时当前文件已超限则先轮换，保证 sink 打开后有写入空间
    try {
      _currentSize = file.existsSync() ? await file.length() : 0;
    } catch (_) {
      _currentSize = 0;
    }
    if (_currentSize >= _maxFileSize) {
      await _rotate();
    } else {
      _openSink();
    }
  }

  /// 解析日志目录并完成旧文件一次性迁移
  static Future<void> _ensureFiles() async {
    if (_file != null) return;

    final dir = await getApplicationDocumentsDirectory();
    final logDir = Directory('${dir.path}/logs');
    if (!logDir.existsSync()) {
      await logDir.create(recursive: true);
    }

    final file = File('${logDir.path}/$_fileName');
    final legacyFile = File('${logDir.path}/$_legacyFileName');

    // 一次性迁移：旧文件存在且新文件不存在时，重命名
    if (legacyFile.existsSync() && !file.existsSync()) {
      await legacyFile.rename(file.path);
    } else if (legacyFile.existsSync() && file.existsSync()) {
      final oldContent = await readContentSafely(legacyFile);
      if (oldContent.trim().isNotEmpty) {
        await file.writeAsString(oldContent, mode: FileMode.append);
      }
      await legacyFile.delete();
    }

    _file = file;
    _rotatedFile = File('${logDir.path}/$_rotatedFileName');
  }

  void _openSink() {
    final file = _file;
    if (file == null) return;
    try {
      _sink = file.openWrite(mode: FileMode.append);
    } catch (_) {
      _sink = null;
    }
  }

  /// 写入一条日志条目，自动注入 appVersion。
  /// 同步 fire-and-forget：只追加内存缓冲，落盘由 flush 策略决定。
  void write(Map<String, dynamic> entry, {bool inheritPluginContext = true}) {
    final level = entry['level'];
    // debug 级日志仅在开发者模式下落盘
    if (level == 'debug' && !verboseEnabled) return;

    entry = LogPolicy.normalize({
      ...entry,
      if (inheritPluginContext) ...?PluginExecutionContext.current?.fields,
      if (_appVersion != null) 'appVersion': _appVersion,
    });
    // 仅合并没有请求身份的完全相同事件；请求/重试记录始终保留。
    if (entry['traceId'] == null &&
        entry['coreRequestId'] == null &&
        level != 'error') {
      final key = jsonEncode(
        {...entry}
          ..remove('timestamp')
          ..remove('seq'),
      );
      final previous = _repeats[key];
      if (previous != null) {
        previous['suppressed'] = (previous['suppressed'] as int) + 1;
        previous['lastTimestamp'] = entry['timestamp'];
        return;
      }
      if (_repeats.length >= 128) _flushRepeats();
      _repeats[key] = {
        ...entry,
        'event': 'repeat_summary',
        'type': entry['type'],
        'level': entry['level'],
        'message': entry['message'],
        'firstSeq': entry['seq'],
        'firstTimestamp': entry['timestamp'],
        'lastTimestamp': entry['timestamp'],
        'suppressed': 0,
      };
    }
    _append(entry);

    // 未初始化（应用启动早期 / 测试环境）：只缓冲，init 完成后统一落盘
    if (!_initialized) {
      if (_buffer.length > _maxPendingLines) {
        _buffer.removeRange(0, _buffer.length - _maxPendingLines);
      }
      return;
    }

    if (level == 'error' || _buffer.length >= _maxBufferedLines) {
      flushNow();
    } else {
      _flushTimer ??= Timer(_flushInterval, () {
        _flushTimer = null;
        unawaited(_enqueueFlush());
      });
    }
  }

  /// 立即落盘缓冲中的日志，返回完成 Future（崩溃处理 / 读取前调用）
  Future<void> flushNow() async {
    if (!_initialized) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    await _enqueueFlush();
    if (_buffer.isNotEmpty) await _enqueueFlush();
  }

  Future<void> _enqueueFlush() {
    if (_flushPending != null) return _flushPending!;
    _io = _io.then((_) => _flush()).catchError((_) {});
    return _flushPending = _io.whenComplete(() {
      _flushPending = null;
      if (_buffer.isNotEmpty && _initialized) {
        _flushTimer ??= Timer(_flushInterval, () {
          _flushTimer = null;
          unawaited(_enqueueFlush());
        });
      }
    });
  }

  Future<void> _flush() async {
    _flushRepeats();
    if (_buffer.isEmpty) return;

    if (_sink == null) _openSink();
    final sink = _sink;
    if (sink == null) return;

    final lines = _buffer.join();
    _buffer.clear();
    _bufferBytes = 0;
    try {
      final bytes = utf8.encode(lines);
      sink.add(bytes);
      await sink.flush();
      _currentSize += bytes.length;
    } catch (_) {
      // 写入失败时丢弃当前批次并重建 sink，避免日志拖垮应用
      await _closeSink();
      return;
    }

    if (_currentSize >= _maxFileSize) {
      await _rotate();
    }
  }

  /// O(1) 轮换：当前文件 rename 为 .1（覆盖旧轮换代），新开当前文件
  Future<void> _rotate() async {
    final file = _file;
    final rotatedFile = _rotatedFile;
    if (file == null || rotatedFile == null) return;

    await _closeSink();
    try {
      if (rotatedFile.existsSync()) {
        await rotatedFile.delete();
      }
      if (file.existsSync()) {
        await file.rename(rotatedFile.path);
      }
    } catch (_) {}
    _currentSize = 0;
    await file.create();
    _openSink();
  }

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.close();
      } catch (_) {}
    }
  }

  /// 清空全部日志（当前代 + 轮换代）
  Future<void> clearAll() {
    _repeats.clear();
    _dropped = 0;
    _buffer.clear();
    _bufferBytes = 0;
    _io = _io
        .then((_) async {
          await _closeSink();
          try {
            final file = _file;
            if (file != null && file.existsSync()) {
              await file.writeAsString('');
            }
            final rotatedFile = _rotatedFile;
            if (rotatedFile != null && rotatedFile.existsSync()) {
              await rotatedFile.delete();
            }
          } catch (_) {}
          _currentSize = 0;
          _openSink();
        })
        .catchError((_) {});
    return _io;
  }

  /// 清理插件在调用时刻之前的记录，新产生的记录仍可正常落盘。
  Future<void> clearPlugin(String pluginId) {
    final cutoff = LogPolicy.sequence;
    bool belongsToClearedScope(Map<dynamic, dynamic> row) =>
        row['pluginId'] == pluginId &&
        (row['sessionId'] != LogPolicy.sessionId ||
            (row['seq'] is int && (row['seq'] as int) <= cutoff));
    bool keep(String line) {
      try {
        final row = jsonDecode(line);
        return row is! Map || !belongsToClearedScope(row);
      } on FormatException {
        return true;
      }
    }

    _repeats.removeWhere((_, row) => belongsToClearedScope(row));
    _buffer.removeWhere((line) => !keep(line));
    _bufferBytes = _buffer.fold(0, (size, line) => size + utf8.encode(line).length);
    final operation = _io.then((_) async {
      await _closeSink();
      try {
        for (final file in [_rotatedFile, _file]) {
          if (file == null || !await file.exists()) continue;
          final content = await readContentSafely(file);
          final lines = const LineSplitter().convert(content).where(keep);
          final retained = lines.isEmpty ? '' : '${lines.join('\n')}\n';
          final temporary = File('${file.path}.clear');
          await temporary.writeAsString(retained, flush: true);
          await temporary.rename(file.path);
        }
      } finally {
        final file = _file;
        _currentSize = file != null && await file.exists() ? await file.length() : 0;
        _openSink();
      }
    });
    _io = operation.catchError((Object _) {});
    return operation;
  }

  static Future<String> readPluginContent(String pluginId) async {
    final content = await readAllContent();
    final result = StringBuffer();
    for (final line in const LineSplitter().convert(content)) {
      try {
        final row = jsonDecode(line);
        if (row is Map && row['pluginId'] == pluginId) result.writeln(line);
      } on FormatException {
        continue;
      }
    }
    return result.toString();
  }

  /// 获取当前代日志文件（读取前请先 flushNow）
  static Future<File> getLogFile() async {
    await _ensureFiles();
    return _file!;
  }

  /// 获取轮换代日志文件（可能不存在）
  static Future<File> getRotatedLogFile() async {
    await _ensureFiles();
    return _rotatedFile!;
  }

  /// 读取全部日志原文（轮换代在前、当前代在后，按时间正序），读取前自动落盘缓冲
  static Future<String> readAllContent() async {
    await instance.flushNow();
    final buf = StringBuffer();
    try {
      final rotatedFile = await getRotatedLogFile();
      if (rotatedFile.existsSync()) {
        buf.write(await readContentSafely(rotatedFile));
      }
      final file = await getLogFile();
      if (file.existsSync()) {
        buf.write(await readContentSafely(file));
      }
    } catch (_) {}
    return buf.toString();
  }

  /// 容错读取日志文件：非法 utf-8 字节替换为 U+FFFD，避免一个坏字节让整个页面打不开
  /// 写入中崩溃留下的半截行、并发轮换、外部工具污染都可能产生非法字节
  static Future<String> readContentSafely(File file) async {
    final bytes = await file.readAsBytes();
    return utf8.decode(bytes, allowMalformed: true);
  }
}
