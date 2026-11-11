import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../network/discourse_dio.dart';
import 'font_archive.dart';
import 'font_catalog.dart';
import 'font_sources.dart';

/// 字体安装状态。
sealed class FontInstallState {
  const FontInstallState();
}

class FontNotInstalled extends FontInstallState {
  const FontNotInstalled();
}

class FontQueued extends FontInstallState {
  const FontQueued();
}

class FontDownloading extends FontInstallState {
  const FontDownloading({
    required this.received,
    required this.total,
    required this.source,
  });

  final int received;
  final int total;
  final FontSourceKind source;

  double get progress => total <= 0 ? 0 : (received / total).clamp(0, 1);
}

class FontVerifying extends FontInstallState {
  const FontVerifying();
}

class FontInstalled extends FontInstallState {
  const FontInstalled(this.path);
  final String path;
}

class FontFailed extends FontInstallState {
  const FontFailed(this.reason, {this.detail});
  final FontFailure reason;
  final String? detail;
}

/// 下载失败原因（界面据此给出文案与操作）。
enum FontFailure {
  /// 所有源的网络请求都失败
  network,

  /// 下载内容校验不通过（哈希不符、不是字体文件）
  corrupted,

  /// 用户取消
  cancelled,

  /// 自定义镜像模板无效
  invalidSource,

  /// 本地写入失败
  storage,
}

/// 一次 HTTP 响应（流式）。
class FontHttpResponse {
  const FontHttpResponse(this.statusCode, this.body);
  final int statusCode;
  final Stream<List<int>> body;
}

/// 发起 GET：[from] 非空时带 `Range: bytes=<from>-`。
typedef FontFetch =
    Future<FontHttpResponse> Function(
      String url, {
      int? from,
      CancelToken? cancelToken,
    });

/// 字体下载、校验、安装与引擎注册。
///
/// 安装位置：`<应用支持目录>/fonts/<id>/<sha256>.ttf`，文件名即内容哈希，
/// 目录里存在即视为已安装（安装前已完成全部校验）。字体可重新下载，
/// 不进入备份。
class FontDownloadService extends ChangeNotifier {
  FontDownloadService({
    FontFetch? fetch,
    Future<Directory> Function()? rootDir,
    this.probeOverride,
  }) : _fetch = fetch ?? _dioFetch,
       _rootDir = rootDir ?? _defaultRootDir;

  static FontDownloadService instance = FontDownloadService();

  static const String sourceKey = 'font_source';
  static const String customTemplateKey = 'font_source_custom';

  final FontFetch _fetch;
  final Future<Directory> Function() _rootDir;
  /// 测速实现（测试注入），缺省为真实网络探测。
  final Future<Duration?> Function(String url)? probeOverride;

  SharedPreferences? _prefs;
  final Map<String, FontInstallState> _states = {};
  final Map<String, CancelToken> _cancels = {};
  final Set<String> _registeredFamilies = {};
  final _installed = StreamController<FontEntry>.broadcast();
  Future<void> _queue = Future.value();

  /// 最近一次测速结果（null = 失败）。
  final Map<FontSourceKind, Duration?> latencies = {};

  /// 字体安装完成事件。
  Stream<FontEntry> get onInstalled => _installed.stream;

  FontSourceKind get sourceKind => FontSourceKind.values.asNameMap()[
          _prefs?.getString(sourceKey)] ??
      FontSourceKind.auto;

  String get customTemplate => _prefs?.getString(customTemplateKey) ?? '';

  FontInstallState stateOf(FontEntry entry) =>
      _states[entry.id] ?? const FontNotInstalled();

  bool isInstalled(FontEntry entry) => stateOf(entry) is FontInstalled;

  /// 扫描已安装字体。
  Future<void> initialize(SharedPreferences prefs) async {
    _prefs = prefs;
    final root = await _rootDir();
    for (final entry in FontCatalog.all) {
      final file = File(_installedPath(root, entry));
      if (file.existsSync() && file.lengthSync() == entry.size) {
        _states[entry.id] = FontInstalled(file.path);
      }
    }
    notifyListeners();
  }

  Future<void> setSource(FontSourceKind kind, {String? customTemplate}) async {
    await _prefs?.setString(sourceKey, kind.name);
    if (customTemplate != null) {
      await _prefs?.setString(customTemplateKey, customTemplate.trim());
    }
    notifyListeners();
  }

  /// 并发测速全部内置源（及已配置的自定义源），结果写入 [latencies]。
  Future<void> measureLatencies(FontEntry entry) async {
    final sources = [
      ...FontSource.builtins,
      if (FontSource.isValidTemplate(customTemplate))
        FontSource.custom(customTemplate),
    ];
    final results = await Future.wait(
      sources.map((s) => (probeOverride ?? _defaultProbe)(s.urlFor(entry))),
    );
    for (var i = 0; i < sources.length; i++) {
      latencies[sources[i].kind] = results[i];
    }
    notifyListeners();
  }

  /// 排队下载并安装 [entry]；已安装或进行中时忽略。
  Future<void> install(FontEntry entry) {
    final state = stateOf(entry);
    if (state is FontInstalled ||
        state is FontQueued ||
        state is FontDownloading ||
        state is FontVerifying) {
      return _queue;
    }
    _setState(entry, const FontQueued());
    final cancel = CancelToken();
    _cancels[entry.id] = cancel;
    // 串行执行：大文件并发下载只会互相抢带宽
    return _queue = _queue.then((_) => _run(entry, cancel));
  }

  void cancel(FontEntry entry) {
    _cancels.remove(entry.id)?.cancel();
    final state = stateOf(entry);
    if (state is FontQueued) {
      _setState(entry, const FontFailed(FontFailure.cancelled));
    }
  }

  Future<void> uninstall(FontEntry entry) async {
    cancel(entry);
    final dir = Directory('${(await _rootDir()).path}/${entry.id}');
    if (dir.existsSync()) await dir.delete(recursive: true);
    _setState(entry, const FontNotInstalled());
  }

  /// 已安装时把字体注册给引擎（同一字族只注册一次）。返回是否可用。
  Future<bool> register(FontEntry entry) async {
    if (_registeredFamilies.contains(entry.family)) return true;
    final state = stateOf(entry);
    if (state is! FontInstalled) return false;
    try {
      final bytes = await File(state.path).readAsBytes();
      final loader = FontLoader(entry.family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _registeredFamilies.add(entry.family);
      return true;
    } catch (e) {
      debugPrint('[Fonts] 注册 ${entry.id} 失败: $e');
      return false;
    }
  }

  bool isRegistered(FontEntry entry) =>
      _registeredFamilies.contains(entry.family);

  Future<void> _run(FontEntry entry, CancelToken cancel) async {
    if (cancel.isCancelled) return;
    final root = await _rootDir();
    final dir = Directory('${root.path}/${entry.id}')
      ..createSync(recursive: true);

    final List<FontSource> sources;
    switch (sourceKind) {
      case FontSourceKind.auto:
        sources = await _rankedBuiltins(entry);
      case FontSourceKind.custom:
        if (!FontSource.isValidTemplate(customTemplate)) {
          _setState(entry, const FontFailed(FontFailure.invalidSource));
          return;
        }
        sources = [FontSource.custom(customTemplate)];
      case final kind:
        final pinned = FontSource.builtin(kind)!;
        // 指定源提供不了这个文件（超出单文件上限）时按自动顺序换源
        sources = pinned.supports(entry)
            ? [pinned]
            : await _rankedBuiltins(entry);
    }

    FontFailed? lastFailure;
    for (final source in sources) {
      if (cancel.isCancelled) break;
      try {
        await _downloadFrom(entry, source, dir, cancel);
        final path = _installedPath(root, entry);
        _setState(entry, FontInstalled(path));
        _cancels.remove(entry.id);
        _installed.add(entry);
        return;
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) break;
        lastFailure = FontFailed(FontFailure.network, detail: '${source.kind.name}: ${e.message ?? e.type.name}');
      } on _CorruptedDownload catch (e) {
        lastFailure = FontFailed(FontFailure.corrupted, detail: '${source.kind.name}: ${e.message}');
      } on FileSystemException catch (e) {
        lastFailure = FontFailed(FontFailure.storage, detail: e.message);
        break;
      } catch (e) {
        lastFailure = FontFailed(FontFailure.network, detail: '${source.kind.name}: $e');
      }
      debugPrint('[Fonts] ${entry.id} 下载失败 ${lastFailure.detail}');
    }
    _cancels.remove(entry.id);
    _setState(
      entry,
      cancel.isCancelled
          ? const FontFailed(FontFailure.cancelled)
          : lastFailure ?? const FontFailed(FontFailure.network),
    );
  }

  Future<List<FontSource>> _rankedBuiltins(FontEntry entry) async {
    await measureLatencies(entry);
    final sources = [
      for (final source in FontSource.builtins)
        if (source.supports(entry)) source,
    ];
    // 测速失败的源排到最后但仍会尝试（测速请求本身也可能被偶发干扰）
    sources.sort((a, b) {
      final la = latencies[a.kind];
      final lb = latencies[b.kind];
      if (la == null && lb == null) return 0;
      if (la == null) return 1;
      if (lb == null) return -1;
      return la.compareTo(lb);
    });
    return sources;
  }

  Future<void> _downloadFrom(
    FontEntry entry,
    FontSource source,
    Directory dir,
    CancelToken cancel,
  ) async {
    final total = source.tarball ? entry.tarballSize : entry.size;
    final part = File('${dir.path}/.part-${source.kind.name}');
    var offset = 0;
    if (source.rangeSafe && part.existsSync()) {
      offset = part.lengthSync();
      if (offset >= total) {
        part.deleteSync();
        offset = 0;
      }
    } else if (part.existsSync()) {
      part.deleteSync();
    }

    _setState(
      entry,
      FontDownloading(received: offset, total: total, source: source.kind),
    );
    final response = await _fetch(
      source.urlFor(entry),
      from: offset > 0 ? offset : null,
      cancelToken: cancel,
    );
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw DioException(
        requestOptions: RequestOptions(path: source.urlFor(entry)),
        message: 'HTTP ${response.statusCode}',
      );
    }
    if (offset > 0 && response.statusCode != 206) offset = 0; // 不支持续传
    final sink = part.openWrite(
      mode: offset > 0 ? FileMode.writeOnlyAppend : FileMode.writeOnly,
    );
    var received = offset;
    var lastEmit = DateTime.now();
    try {
      await for (final chunk in response.body) {
        sink.add(chunk);
        received += chunk.length;
        if (received > total) {
          throw _CorruptedDownload('大小超出 $received/$total');
        }
        final now = DateTime.now();
        if (now.difference(lastEmit).inMilliseconds >= 100) {
          lastEmit = now;
          _setState(
            entry,
            FontDownloading(received: received, total: total, source: source.kind),
          );
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    _setState(entry, const FontVerifying());
    final extracted = File('${dir.path}/.extract');
    try {
      if (part.lengthSync() != total) {
        throw _CorruptedDownload('大小不符 ${part.lengthSync()}/$total');
      }
      if (source.tarball) {
        if (!await FontArchive.matchesIntegrity(part.path, entry.tarballIntegrity)) {
          throw _CorruptedDownload('整包完整性校验失败');
        }
        await FontArchive.extractMember(
          part.path,
          'package/${entry.file}',
          extracted.path,
        );
      } else {
        part.renameSync(extracted.path);
      }
      if (!await FontArchive.isFontFile(extracted.path)) {
        throw _CorruptedDownload('不是字体文件');
      }
      if (await FontArchive.sha256Of(extracted.path) != entry.sha256) {
        throw _CorruptedDownload('字体哈希不符');
      }
      extracted.renameSync('${dir.path}/${entry.sha256}.ttf');
    } catch (_) {
      // 校验不过的内容不可续传，删掉重来
      if (part.existsSync()) part.deleteSync();
      if (extracted.existsSync()) extracted.deleteSync();
      rethrow;
    }
    if (part.existsSync()) part.deleteSync();
  }

  void _setState(FontEntry entry, FontInstallState state) {
    _states[entry.id] = state;
    notifyListeners();
  }

  static String _installedPath(Directory root, FontEntry entry) =>
      '${root.path}/${entry.id}/${entry.sha256}.ttf';

  static Future<Directory> _defaultRootDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/fonts');

  static Dio? _dio;

  /// 外部 CDN 下载走应用网络栈（代理 / DoH 生效），但不带站点 Cookie、
  /// 不过 CF 验证、不做总时限（大文件），只保留单次读取超时。
  static Dio get _downloadDio => _dio ??= DiscourseDio.create(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    callTimeout: null,
    maxConcurrent: null,
    enableRetry: false,
    enableCfChallenge: false,
    enableCookies: false,
    enableNetworkLog: false,
  );

  static Future<FontHttpResponse> _dioFetch(
    String url, {
    int? from,
    CancelToken? cancelToken,
  }) async {
    final response = await _downloadDio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        // 显式要原始字节：避免 CDN 返回压缩体导致续传切片错位
        headers: {
          'Accept-Encoding': 'identity',
          'Range': ?(from == null ? null : 'bytes=$from-'),
        },
        validateStatus: (s) => s != null && s < 400,
      ),
    );
    return FontHttpResponse(
      response.statusCode ?? 0,
      response.data!.stream,
    );
  }

  /// 测速：取首个 1KB 的首字节延迟，6 秒内无响应视为失败。
  static Future<Duration?> _defaultProbe(String url) async {
    final watch = Stopwatch()..start();
    final cancel = CancelToken();
    try {
      final response = await _downloadDio
          .get<ResponseBody>(
            url,
            cancelToken: cancel,
            options: Options(
              responseType: ResponseType.stream,
              headers: {'Accept-Encoding': 'identity', 'Range': 'bytes=0-1023'},
              validateStatus: (s) => s != null && s < 400,
            ),
          )
          .timeout(const Duration(seconds: 6));
      await response.data!.stream.first.timeout(const Duration(seconds: 6));
      return watch.elapsed;
    } catch (_) {
      return null;
    } finally {
      cancel.cancel();
    }
  }
}

class _CorruptedDownload implements Exception {
  const _CorruptedDownload(this.message);
  final String message;
  @override
  String toString() => message;
}
