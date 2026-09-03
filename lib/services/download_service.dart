import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  /// 下载到同目录的随机临时文件，成功后再原子替换已预留的目标文件。
  ///
  /// 最终路径由 [reserveAvailableDownload] 以 exclusive 方式预留，避免并发
  /// 下载选中同一个名称。网络数据不会直接按远端可影响的最终路径打开，避免
  /// 预留后目标被替换为符号链接时跟随链接写入目录外。
  Future<void> download({
    required String url,
    required DownloadReservation reservation,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      await _dio.download(
        url,
        reservation.temporaryPath,
        onReceiveProgress: onProgress,
        cancelToken: cancelToken,
        options: Options(extra: {'skipCsrf': true, 'skipAuthCheck': true}),
      );
      await reservation.commit();
    } catch (error, stackTrace) {
      try {
        await reservation.release();
      } catch (cleanupError) {
        debugPrint('[DownloadService] 清理失败: $cleanupError');
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
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

  /// 解析本机的「下载目录」，目录不存在时创建。
  ///
  /// 各平台落点差异很大，注意这里**不保证对用户可见**：
  /// - 桌面 → `~/Downloads`（可见）；
  /// - Android → 应用外部下载目录 `Android/data/<pkg>/files/Download`
  ///   （11+ 的系统文件管理器不允许浏览，只能在应用内取用）；
  /// - iOS → 沙盒 `Library/Downloads`（对外完全不可见）。
  ///
  /// 要落到用户能找到的位置，走 `ShareUtils.saveFile` / `saveFileAs`。
  /// path_provider 在部分平台会对下载目录抛 [UnsupportedError]，统一回退到
  /// 应用文档目录，避免调用方各自兜底。
  static Future<Directory> resolveDownloadDirectory() async {
    Directory? downloadsDir;
    try {
      downloadsDir = await getDownloadsDirectory();
    } catch (e) {
      debugPrint('[DownloadService] 系统下载目录不可用: $e');
    }
    if (downloadsDir != null) {
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      return downloadsDir;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final fallbackDir = Directory(p.join(appDir.path, 'Downloads'));
    if (!await fallbackDir.exists()) {
      await fallbackDir.create(recursive: true);
    }
    return fallbackDir;
  }

  /// 原子预留一个不重名的最终路径，并在同目录创建不可预测的临时文件。
  ///
  /// [directory] 必须已经存在。目标名和临时名都用 exclusive 创建，既不会
  /// 覆盖文件、目录或符号链接，也不会让两个并发下载取得同一路径。
  static DownloadReservation reserveAvailableDownload({
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

    final dot = safeFileName.lastIndexOf('.');
    final name = dot > 0 ? safeFileName.substring(0, dot) : safeFileName;
    final extension = dot > 0 ? safeFileName.substring(dot) : '';

    File? reservedFile;
    String? reservationMarker;
    for (var index = 0; reservedFile == null; index++) {
      final candidateName = index == 0
          ? safeFileName
          : '$name ($index)$extension';
      final candidate = File(directChildPath(candidateName));
      try {
        candidate.createSync(exclusive: true);
        reservationMarker = 'fluxdo-reservation-${_randomToken()}';
        candidate.writeAsStringSync(reservationMarker, flush: true);
        reservedFile = candidate;
      } on FileSystemException {
        if (FileSystemEntity.typeSync(candidate.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }

    File? temporaryFile;
    try {
      for (var attempt = 0; temporaryFile == null; attempt++) {
        if (attempt >= 100) {
          throw FileSystemException('无法创建下载临时文件', canonicalDirectory);
        }
        final token = _randomToken();
        final candidate = File(directChildPath('.fluxdo-download-$token.part'));
        try {
          candidate.createSync(exclusive: true);
          temporaryFile = candidate;
        } on FileSystemException {
          if (FileSystemEntity.typeSync(candidate.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
            rethrow;
          }
        }
      }
    } catch (_) {
      reservedFile.deleteSync();
      rethrow;
    }

    return DownloadReservation._(
      requestedFileName: safeFileName,
      reservationMarker: reservationMarker!,
      reservedFile: reservedFile,
      temporaryFile: temporaryFile,
    );
  }

  static String _randomToken() {
    final random = Random.secure();
    return List.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
  }
}

/// 一次下载独占的最终路径和临时路径。
class DownloadReservation {
  DownloadReservation._({
    required this.requestedFileName,
    required String reservationMarker,
    required File reservedFile,
    required File temporaryFile,
  }) : _reservationMarker = reservationMarker,
       _reservedFile = reservedFile,
       _temporaryFile = temporaryFile;

  /// 预留时传入的安全文件名，不包含自动追加的重名序号。
  final String requestedFileName;
  final String _reservationMarker;
  final File _reservedFile;
  final File _temporaryFile;
  bool _finished = false;

  String get savePath => _reservedFile.path;
  String get temporaryPath => _temporaryFile.path;

  /// 通过同文件系统 rename 直接替换占位项，不暴露目标路径为空的窗口。
  Future<void> commit() async {
    if (_finished) return;
    await _temporaryFile.rename(_reservedFile.path);
    _finished = true;
  }

  /// 下载失败或放弃名称时，尽力清理临时文件和仍属于本次预留的占位文件。
  Future<void> release() async {
    if (_finished) return;
    Object? firstError;
    StackTrace? firstStackTrace;

    try {
      await _deleteIfPresent(_temporaryFile);
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      await _deleteOwnedPlaceholder();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
    _finished = true;
  }

  Future<void> _deleteOwnedPlaceholder() async {
    if (FileSystemEntity.typeSync(_reservedFile.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return;
    }
    if (await _reservedFile.readAsString() == _reservationMarker) {
      await _reservedFile.delete();
    }
  }

  static Future<void> _deleteIfPresent(File file) async {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await file.delete();
    }
  }
}
