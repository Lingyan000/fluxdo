import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../constants.dart';
import '../app_logger.dart';
import '../network/flux_request_spec.dart';
import '../translation_service.dart';

extension on CancelToken {
  void throwIfCancellationRequested() {
    if (isCancelled) throw cancelError!;
  }
}

class OcrModelFile {
  const OcrModelFile(this.name, this.member, this.size, this.sha256Hex);
  final String name;
  final String member;
  final int size;
  final String sha256Hex;
}

class OcrModelBundle {
  const OcrModelBundle({
    required this.baseUrl,
    required this.archiveName,
    required this.archiveSize,
    required this.archiveSha,
    required this.files,
    this.archiveBaseUrl = '',
  });
  final String baseUrl;
  final String archiveBaseUrl;
  final String archiveName;
  final int archiveSize;
  final String archiveSha;
  final List<OcrModelFile> files;

  String url(OcrModelFile file) => _resolve(baseUrl, file.member);
  String? get archiveUrl => archiveBaseUrl.isEmpty
      ? null
      : _resolve(archiveBaseUrl, '$archiveName.tar');

  static String _resolve(String base, String member) {
    final uri = Uri.tryParse(base);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw StateError('请配置项目自己的 FLUXDO_OCR_MODEL_BASE_URL（HTTPS）');
    }
    return Uri.parse(base.endsWith('/') ? base : '$base/')
        .resolve(member)
        .toString();
  }
}

typedef OcrModelPaths = ({String detector, String recognizer, String config});

class OcrModelStore {
  OcrModelStore({
    Dio? dio,
    Future<Directory> Function()? directory,
    Future<Directory> Function()? paragraphDirectory,
    this.bundles = defaultBundles,
    this.paragraphModelUrl = defaultParagraphModelUrl,
    this.paragraphModelFile = defaultParagraphModelFile,
  }) : _dio = dio ?? TranslationService.createClient(),
       _directory = directory ?? _defaultDirectory,
       _paragraphDirectory =
           paragraphDirectory ??
           (directory == null ? _defaultParagraphDirectory : null);

  // 从飞桨官方 PP-OCRv6 small 转换；转换与发布契约见 packages/fluxdo_ocr/README.md。
  // 只发布固定摘要的 FP16 权重，输入输出仍是 float32。运行库随包，模型按需下载。
  static const modelVersion = 'ppocr-v6-small-litert-1';
  static const paragraphModelVersion = 'line2para-1';
  static const _baseUrl = String.fromEnvironment(
    'FLUXDO_OCR_MODEL_BASE_URL',
    defaultValue:
        'https://modelscope.cn/models/pyteng/fluxdo-ocr/resolve/'
        '5e40c1fd3e8c6c2c18119622120c39cb77a8dd09/',
  );
  static const _archiveBaseUrl = String.fromEnvironment(
    'FLUXDO_OCR_MODEL_ARCHIVE_BASE_URL',
  );

  // 智能段落归并模型来源于 mgchao/SnowShotOCR（Apache-2.0），固定提交并校验 SHA-256。
  // 参见 packages/fluxdo_ocr/README.md。
  static const defaultParagraphModelUrl = String.fromEnvironment(
    'FLUXDO_OCR_LINE2PARA_URL',
    defaultValue:
        'https://modelscope.cn/models/mgchao/SnowShotOCR/resolve/'
        'a74b1a19f017058b3481906cbdb345622f2f2911/'
        'line2para/line2para_1_2-epoch12-signed-1.625.onnx',
  );
  static const defaultParagraphModelFile = OcrModelFile(
    'line2para_1_2-epoch12-signed-1.625.onnx',
    'line2para_1_2-epoch12-signed-1.625.onnx',
    3061303,
    '956253efb9eefe81692b5ba88b2923f1a012427933768acd5657c509b7363ac5',
  );
  static const _paragraphRetryCooldown = Duration(minutes: 5);
  static const _det = OcrModelFile(
    'det.tflite',
    'det.tflite',
    4995092,
    '90c01fa278a2d8175026b48b8b80c8f48d95448d36370122e35abbbd366ff4aa',
  );
  static const _rec = OcrModelFile(
    'rec.tflite',
    'rec.tflite',
    10610876,
    'be121dcbaea1aec7ea3b5619b604992306836e166f32ac02d747df0ba055ff64',
  );
  static const _config = OcrModelFile(
    'rec.yml',
    'rec.yml',
    150579,
    'ab078671bb49f06228eadccd34f1bb501e157f7a047095ffb943ba81512c77d1',
  );
  static const defaultBundles = [
    OcrModelBundle(
      baseUrl: _baseUrl,
      archiveBaseUrl: _archiveBaseUrl,
      archiveName: modelVersion,
      archiveSize: 15779840,
      archiveSha:
          '854f5d62cda1e0b0ac6b3ee426dc519dfe00720d388e8a7b3ab55870b91576bc',
      files: [_det, _rec, _config],
    ),
  ];
  static int get downloadBytes => _det.size + _rec.size + _config.size;
  final List<OcrModelBundle> bundles;
  final String paragraphModelUrl;
  final OcrModelFile paragraphModelFile;
  final Dio _dio;
  final Future<Directory> Function() _directory;
  final Future<Directory> Function()? _paragraphDirectory;
  Future<void>? _pending;
  Future<String?>? _paragraphPending;
  DateTime? _paragraphCooldownUntil;
  final Map<String, ({int size, int modifiedMs})> _verifiedFiles = {};

  static Future<Directory> _defaultDirectory() async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'ocr', modelVersion),
  );

  static Future<Directory> _defaultParagraphDirectory() async => Directory(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'ocr',
      paragraphModelVersion,
    ),
  );

  Future<OcrModelPaths> paths() async {
    final dir = (await _directory()).path;
    return (
      detector: p.join(dir, _det.name),
      recognizer: p.join(dir, _rec.name),
      config: p.join(dir, _config.name),
    );
  }

  /// 若 line2para 智能段落归并模型已就绪且通过校验，返回其本地文件路径；否则返回 null。
  Future<String?> paragraphModelPathIfReady() async {
    final getDir = _paragraphDirectory;
    if (getDir == null) return null;
    if (getDir == _defaultParagraphDirectory &&
        Platform.environment['FLUTTER_TEST'] == 'true') {
      return null;
    }
    try {
      final dir = await getDir();
      final file = File(p.join(dir.path, paragraphModelFile.name));
      if (await _isFileReady(
        file,
        paragraphModelFile.size,
        paragraphModelFile.sha256Hex,
      )) {
        return file.path;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 按需获取 line2para 智能段落归并模型（约 2.92 MiB）。
  ///
  /// - 已落盘时立即返回路径；
  /// - 未下载时以断点续传 + SHA-256 校验下载，不抛致命异常，失败时记录冷却并返回 null，
  ///   由上层自动回退到本地几何排版；
  /// - 传入 [waitTimeout] 时，若下载在超时内未完成则先返回 null 让本次识字不阻塞，
  ///   底层下载任务仍会在后台继续完成供下次复用。
  Future<String?> ensureParagraphModel({Duration? waitTimeout}) async {
    final getDir = _paragraphDirectory;
    if (getDir == null) return null;
    if (getDir == _defaultParagraphDirectory &&
        Platform.environment['FLUTTER_TEST'] == 'true') {
      return null;
    }
    final ready = await paragraphModelPathIfReady();
    if (ready != null) return ready;
    final uri = Uri.tryParse(paragraphModelUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    final cooldown = _paragraphCooldownUntil;
    if (cooldown != null && DateTime.now().isBefore(cooldown)) return null;

    var task = _paragraphPending;
    if (task == null) {
      task = _downloadParagraphModel(getDir);
      _paragraphPending = task;
      unawaited(
        task.whenComplete(() {
          if (identical(_paragraphPending, task)) {
            _paragraphPending = null;
          }
        }),
      );
    }
    if (waitTimeout == null) return task;
    try {
      return await task.timeout(waitTimeout);
    } on TimeoutException {
      return null;
    }
  }

  Future<String?> _downloadParagraphModel(
    Future<Directory> Function() getDir,
  ) async {
    try {
      final dir = await getDir();
      await dir.create(recursive: true);
      final target = File(p.join(dir.path, paragraphModelFile.name));
      if (await _isFileReady(
        target,
        paragraphModelFile.size,
        paragraphModelFile.sha256Hex,
      )) {
        return target.path;
      }
      final part = File('${target.path}.part');
      final token = CancelToken();
      await _fetch(
        paragraphModelUrl,
        part,
        paragraphModelFile.size,
        paragraphModelFile.sha256Hex,
        token,
        (_) {},
      );
      await part.rename(target.path);
      final stat = await target.stat();
      _verifiedFiles[target.path] = (
        size: stat.size,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
      );
      _paragraphCooldownUntil = null;
      AppLogger.info(
        'line2para 智能排版模型就绪 (${paragraphModelFile.size} bytes)',
        tag: 'OCR',
      );
      return target.path;
    } catch (error) {
      _paragraphCooldownUntil = DateTime.now().add(_paragraphRetryCooldown);
      AppLogger.warning(
        'line2para 模型下载失败，本次回退本地几何排版: $error',
        tag: 'OCR',
      );
      return null;
    }
  }

  Future<bool> isReady() async {
    final dir = await _directory();
    for (final file in bundles.expand((b) => b.files)) {
      if (!await _isFileReady(
        File(p.join(dir.path, file.name)),
        file.size,
        file.sha256Hex,
      )) {
        return false;
      }
    }
    return true;
  }

  /// 清理内存中的校验缓存（例如推理打开模型异常时强制重新校验磁盘文件）。
  void invalidateVerificationCache() => _verifiedFiles.clear();

  /// 返回模型目录当前占用的总字节数（包含断点临时文件与 line2para 排版模型）。
  Future<int> installedBytes() async {
    var total = await _directoryBytes(await _directory());
    final getParaDir = _paragraphDirectory;
    if (getParaDir != null) {
      total += await _directoryBytes(await getParaDir());
    }
    return total;
  }

  static Future<int> _directoryBytes(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // 并发删除时跳过
        }
      }
    }
    return total;
  }

  /// 删除已下载的离线识字模型与智能排版模型以释放存储空间。
  Future<void> clear() async {
    while (_pending != null) {
      try {
        await _pending;
      } catch (_) {}
    }
    while (_paragraphPending != null) {
      try {
        await _paragraphPending;
      } catch (_) {}
    }
    _verifiedFiles.clear();
    _paragraphCooldownUntil = null;
    final dir = await _directory();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    final getParaDir = _paragraphDirectory;
    if (getParaDir != null) {
      final paraDir = await getParaDir();
      if (await paraDir.exists()) {
        await paraDir.delete(recursive: true);
      }
    }
  }

  Future<bool> _isFileReady(File file, int size, String digest) async {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size != size) {
      _verifiedFiles.remove(file.path);
      return false;
    }
    final modifiedMs = stat.modified.millisecondsSinceEpoch;
    final cached = _verifiedFiles[file.path];
    if (cached != null &&
        cached.size == size &&
        cached.modifiedMs == modifiedMs) {
      return true;
    }
    final ok = await _validHash(file, size, digest);
    if (ok) {
      _verifiedFiles[file.path] = (size: size, modifiedMs: modifiedMs);
    } else {
      _verifiedFiles.remove(file.path);
    }
    return ok;
  }

  static Future<bool> _valid(File file, int size, String digest) async {
    if (!await file.exists() || await file.length() != size) return false;
    return _validHash(file, size, digest);
  }

  static Future<bool> _validHash(File file, int size, String digest) async {
    // 超过 1 MiB 的模型文件放到独立 isolate 计算 SHA-256，避免主线程卡顿。
    if (size >= 1024 * 1024) {
      final path = file.path;
      return Isolate.run(() async {
        final f = File(path);
        if (!await f.exists() || await f.length() != size) return false;
        return (await sha256.bind(f.openRead()).first).toString() == digest;
      });
    }
    return (await sha256.bind(file.openRead()).first).toString() == digest;
  }

  Future<void> download({
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    while (_pending != null) {
      try {
        await _pending;
      } catch (_) {
        // 前一个面板关闭后，排队的调用可以继续使用自己的取消令牌重试。
      }
    }
    cancelToken.throwIfCancellationRequested();
    final task = _download(cancelToken, onProgress);
    _pending = task;
    try {
      await task;
    } finally {
      _pending = null;
    }
  }

  Future<void> _download(
    CancelToken token,
    void Function(double) progress,
  ) async {
    final dir = await _directory();
    await dir.create(recursive: true);
    final total = bundles.expand((b) => b.files).fold(0, (n, f) => n + f.size);
    var done = 0;
    var highWater = 0.0;
    void report(int bytes) {
      final value = (bytes / total).clamp(0.0, 0.99);
      if (value > highWater) {
        highWater = value;
        progress(value);
      }
    }

    for (final bundle in bundles) {
      final missing = <OcrModelFile>[];
      for (final spec in bundle.files) {
        token.throwIfCancellationRequested();
        if (await _isFileReady(
          File(p.join(dir.path, spec.name)),
          spec.size,
          spec.sha256Hex,
        )) {
          done += spec.size;
        } else {
          missing.add(spec);
        }
      }
      while (missing.isNotEmpty) {
        final spec = missing.first;
        final file = File(p.join(dir.path, spec.name));
        try {
          final part = File('${file.path}.part');
          await _fetch(
            bundle.url(spec),
            part,
            spec.size,
            spec.sha256Hex,
            token,
            (n) => report(done + n),
          );
          token.throwIfCancellationRequested();
          await part.rename(file.path);
          final stat = await file.stat();
          _verifiedFiles[file.path] = (
            size: stat.size,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
          );
        } on Exception catch (error) {
          token.throwIfCancellationRequested();
          if (error is! DioException &&
              error is! FormatException &&
              error is! HttpException &&
              error is! SocketException &&
              error is! TimeoutException &&
              error is! TlsException) {
            rethrow;
          }
          if (bundle.archiveUrl == null) rethrow;
          AppLogger.warning(
            'OCR 模型主源下载失败，切换备用源: ${spec.name} ($error)',
            tag: 'OCR',
          );
          final remaining = missing.fold(0, (n, f) => n + f.size);
          await _fromArchive(
            dir,
            bundle,
            missing,
            token,
            (n) => report(done + n * remaining ~/ bundle.archiveSize),
          );
          done += remaining;
          break;
        }
        done += spec.size;
        missing.removeAt(0);
        report(done);
      }
      // 主源恢复后，清理之前在备用源留下的断点。
      final archivePart = File(
        p.join(dir.path, '${bundle.archiveName}.tar.part'),
      );
      if (await archivePart.exists()) await archivePart.delete();
    }
    token.throwIfCancellationRequested();
    progress(1);
    // 仅在新模型完整落盘后回收旧版应用专用的模型目录。
    if (_directory == _defaultDirectory) {
      // 只清理本功能曾使用的精确目录；保留其他模型和失败下载前的旧资源。
      for (final name in ['ppocr-v6-1', 'ppocr-v6-small-onnx-1']) {
        final old = Directory(p.join(dir.parent.path, name));
        try {
          if (await old.exists()) await old.delete(recursive: true);
        } on FileSystemException {
          /* 下次下载时重试。 */
        }
      }
    }
  }

  Future<void> _fromArchive(
    Directory dir,
    OcrModelBundle bundle,
    List<OcrModelFile> missing,
    CancelToken token,
    void Function(int) progress,
  ) async {
    final archive = File(p.join(dir.path, '${bundle.archiveName}.tar.part'));
    await _fetch(
      bundle.archiveUrl!,
      archive,
      bundle.archiveSize,
      bundle.archiveSha,
      token,
      progress,
    );
    final staging = await dir.createTemp('extract-');
    try {
      await _unpack(archive.path, staging.path, bundle.archiveName, missing);
      for (final spec in missing) {
        final file = File(p.join(staging.path, spec.name));
        if (!await _valid(file, spec.size, spec.sha256Hex)) {
          throw const FormatException('OCR 包内文件校验失败');
        }
      }
      for (final spec in missing) {
        token.throwIfCancellationRequested();
        final target = p.join(dir.path, spec.name);
        await File(p.join(staging.path, spec.name)).rename(target);
        final stat = await File(target).stat();
        _verifiedFiles[target] = (
          size: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
        );
        final part = File('$target.part');
        if (await part.exists()) await part.delete();
      }
    } finally {
      await staging.delete(recursive: true);
    }
  }

  static Future<void> _unpack(
    String path,
    String staging,
    String root,
    List<OcrModelFile> files,
  ) => Isolate.run(() {
    final input = InputFileStream(path);
    try {
      final tar = TarDecoder().decodeStream(input);
      for (final spec in files) {
        final entry = tar.findFile('$root/${spec.member}');
        if (entry == null ||
            !entry.isFile ||
            entry.isSymbolicLink ||
            entry.size != spec.size) {
          throw const FormatException('OCR 模型包不完整');
        }
        final out = OutputFileStream(p.join(staging, spec.name));
        try {
          entry.writeContent(out);
        } finally {
          out.closeSync();
        }
      }
    } finally {
      input.closeSync();
    }
  });

  Future<void> _fetch(
    String url,
    File part,
    int size,
    String digest,
    CancelToken token,
    void Function(int) progress,
  ) async {
    var offset = await part.exists() ? await part.length() : 0;
    if (offset == size && await _valid(part, size, digest)) return;
    if (offset >= size) offset = 0;

    // 只在同一发布文件内续传。主源散文件和备用源 tar 有各自的断点。
    const redirectStatuses = {301, 302, 303, 307, 308};
    var currentUrl = url;
    var redirects = 0;
    for (;;) {
      token.throwIfCancellationRequested();
      final response = await _dio.get<ResponseBody>(
        currentUrl,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            HttpHeaders.userAgentHeader: AppConstants.userAgent,
            HttpHeaders.acceptEncodingHeader: 'identity',
            if (offset > 0) HttpHeaders.rangeHeader: 'bytes=$offset-',
          },
          // 必须放行 3xx，否则 Dio 会在 RedirectInterceptor.onResponse 之前直接抛 badResponse。
          validateStatus: (code) =>
              code == 200 ||
              code == 206 ||
              code == 416 ||
              redirectStatuses.contains(code),
          receiveTimeout: const Duration(seconds: 15),
          extra: {FluxRequestKeys.callTimeoutMillis: 120000},
        ),
      );
      final body = response.data!;
      final status = response.statusCode;
      if (redirectStatuses.contains(status)) {
        await body.stream
            .listen((_) {}, onError: (Object _, StackTrace _) {})
            .cancel();
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.isEmpty) {
          throw const HttpException('OCR 下载重定向缺少目标地址');
        }
        redirects++;
        if (redirects > 10) {
          throw const HttpException('OCR 下载重定向次数过多');
        }
        final target = Uri.parse(currentUrl).resolve(location);
        if (target.scheme != 'https' ||
            target.host.isEmpty ||
            target.userInfo.isNotEmpty) {
          throw const FormatException('OCR 下载重定向地址无效');
        }
        currentUrl = target.toString();
        continue;
      }
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      final partial = status == 206;
      if (status == 416 ||
          (partial && range != 'bytes $offset-${size - 1}/$size')) {
        await body.stream.listen((_) {}).cancel();
        if (offset == 0) throw const FormatException('OCR 下载范围无效');
        offset = 0;
        currentUrl = url;
        redirects = 0;
        continue;
      }
      var received = partial ? offset : 0;
      try {
        final output = await part.open(
          mode: received > 0 ? FileMode.writeOnlyAppend : FileMode.writeOnly,
        );
        try {
          await for (final chunk in body.stream) {
            token.throwIfCancellationRequested();
            received += chunk.length;
            if (received > size) throw const FormatException('OCR 下载大小不匹配');
            await output.writeFrom(chunk);
            progress(received);
          }
        } finally {
          await output.close();
        }
      } on FormatException {
        if (await part.exists()) await part.delete();
        rethrow;
      }
      token.throwIfCancellationRequested();
      if (received < size) {
        if (received == 0 && await part.exists()) await part.delete();
        throw const HttpException('OCR 下载提前结束');
      }
      if (await _valid(part, size, digest)) return;
      await part.delete();
      if (offset > 0) {
        offset = 0;
        currentUrl = url;
        redirects = 0;
        continue;
      }
      throw const FormatException('OCR 模型校验失败');
    }
  }

  void dispose() => _dio.close(force: true);
}
