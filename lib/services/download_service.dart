import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'network/discourse_dio.dart';

/// 文件下载服务（单例）
///
/// 使用 DiscourseDio.create() 创建 Dio 实例，
/// 自动继承代理/DOH/rhttp/Cookie 等所有网络设置。
class DownloadService {
  DownloadService._();
  static final DownloadService instance = DownloadService._();
  factory DownloadService() => instance;

  static final RegExp _invalidFileNameCharacters = RegExp(r'[<>:"/\\|?*]');
  static final RegExp _windowsReservedFileName = RegExp(
    r'^(?:con|prn|aux|nul|com[1-9]|lpt[1-9]|conin\$|conout\$)(?:\..*)?$',
    caseSensitive: false,
  );

  late final Dio _dio;

  /// 初始化下载专用 Dio 实例
  void initialize() {
    _dio = DiscourseDio.create(
      receiveTimeout: const Duration(minutes: 30),
      maxConcurrent: null, // 下载不受并发限制
      enableCfChallenge: false, // 下载不需要 CF 验证
    );
    debugPrint('[DownloadService] 初始化完成');
  }

  /// 下载文件到本地
  Future<void> download({
    required String url,
    required String savePath,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    await _dio.download(
      url,
      savePath,
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
      options: Options(extra: {'skipCsrf': true, 'skipAuthCheck': true}),
    );
  }

  /// 通过 HEAD 请求从 Content-Disposition 获取原始文件名
  Future<String?> fetchFileNameFromHeader(String url) async {
    try {
      final response = await _dio.head<void>(
        url,
        options: Options(
          extra: {'skipCsrf': true, 'skipAuthCheck': true},
          followRedirects: true,
        ),
      );
      final disposition = response.headers.value('content-disposition');
      if (disposition != null) {
        return parseContentDisposition(disposition);
      }
    } catch (e) {
      debugPrint('[DownloadService] HEAD 请求获取文件名失败: $e');
    }
    return null;
  }

  /// 解析 Content-Disposition header 中的文件名
  ///
  /// 优先使用 filename*=UTF-8''xxx（支持非 ASCII），
  /// 回退到 filename="xxx"
  static String? parseContentDisposition(String header) {
    // 优先匹配 filename*=UTF-8''encoded_name
    final starMatch = RegExp(
      r"""filename\*\s*=\s*UTF-8''(.+?)(?:;|$)""",
      caseSensitive: false,
    ).firstMatch(header);
    if (starMatch != null) {
      final encoded = starMatch.group(1)!.trim();
      try {
        return Uri.decodeComponent(encoded);
      } catch (_) {}
    }
    // 回退：filename="name" 或 filename=name
    final match = RegExp(
      r'filename\s*=\s*"?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(header);
    if (match != null) {
      return match.group(1)!.trim();
    }
    return null;
  }

  /// 将远端提供的文件名收敛为单个安全的路径组件。
  ///
  /// 下载名可能来自页面文本、WebView、URL 或响应头，因此同时按 POSIX 和
  /// Windows 规则检查，避免跨平台分隔符、绝对路径、盘符和设备名绕过。
  static String? sanitizeFileName(String? rawFileName) {
    if (rawFileName == null) return null;

    final fileName = rawFileName.trim();
    if (fileName.isEmpty || fileName == '.' || fileName == '..') return null;
    if (fileName.endsWith('.') || fileName.endsWith(' ')) return null;
    if (_invalidFileNameCharacters.hasMatch(fileName)) return null;
    if (fileName.runes.any((rune) => rune <= 0x1f || rune == 0x7f)) {
      return null;
    }
    if (p.posix.isAbsolute(fileName) || p.windows.isAbsolute(fileName)) {
      return null;
    }
    if (p.posix.basename(fileName) != fileName ||
        p.windows.basename(fileName) != fileName) {
      return null;
    }
    if (_windowsReservedFileName.hasMatch(fileName)) return null;

    return fileName;
  }

  /// 从 URL / suggestedFilename 解析文件名
  static String resolveFileName(String url, {String? suggestedFilename}) {
    // 优先使用建议文件名
    final safeSuggestedName = sanitizeFileName(suggestedFilename);
    if (safeSuggestedName != null) return safeSuggestedName;

    // 从 URL 路径解析
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      if (segments.isNotEmpty) {
        final last = segments.last;
        if (last.isNotEmpty && last.contains('.')) {
          final safeUrlName = sanitizeFileName(Uri.decodeComponent(last));
          if (safeUrlName != null) return safeUrlName;
        }
      }
    } catch (_) {}
    // 兜底：用时间戳
    return 'download_${DateTime.now().millisecondsSinceEpoch}';
  }

  /// 在下载目录中生成不重名且不会逃逸目录的目标路径。
  ///
  /// [directory] 必须已经存在。先解析其真实路径，再要求最终目标的父目录与
  /// 该目录完全相同；碰到已有文件、目录或符号链接时生成编号副本。
  static String resolveAvailableSavePath({
    required Directory directory,
    required String fileName,
  }) {
    final safeFileName = sanitizeFileName(fileName);
    if (safeFileName == null) {
      throw ArgumentError.value(fileName, 'fileName', '不是安全的下载文件名');
    }

    final canonicalDirectory = p.normalize(
      directory.resolveSymbolicLinksSync(),
    );

    String directChildPath(String name) {
      final candidate = p.normalize(p.join(canonicalDirectory, name));
      if (!p.isWithin(canonicalDirectory, candidate) ||
          !p.equals(p.dirname(candidate), canonicalDirectory)) {
        throw StateError('下载路径必须是下载目录的直接子项');
      }
      return candidate;
    }

    bool pathExists(String path) =>
        FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound;

    var path = directChildPath(safeFileName);
    if (!pathExists(path)) return path;

    final dot = safeFileName.lastIndexOf('.');
    final name = dot > 0 ? safeFileName.substring(0, dot) : safeFileName;
    final extension = dot > 0 ? safeFileName.substring(dot) : '';
    var index = 1;
    do {
      path = directChildPath('$name ($index)$extension');
      index++;
    } while (pathExists(path));
    return path;
  }
}
