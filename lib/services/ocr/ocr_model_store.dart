import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  const OcrModelBundle(
    this.repo,
    this.revision,
    this.archiveSize,
    this.archiveSha,
    this.files,
  );
  final String repo;
  final String revision;
  final int archiveSize;
  final String archiveSha;
  final List<OcrModelFile> files;

  String url(OcrModelFile file) =>
      'https://modelscope.cn/models/PaddlePaddle/$repo/resolve/$revision/${file.member}';
  String get archiveName => '${repo}_infer';
  String get archiveUrl =>
      'https://paddle-model-ecology.bj.bcebos.com/paddlex/'
      'official_inference_model/paddle3.0.0/$archiveName.tar';
}

typedef OcrModelPaths = ({String detector, String recognizer, String config});

class OcrModelStore {
  OcrModelStore({
    Dio? dio,
    Future<Directory> Function()? directory,
    this.bundles = officialBundles,
  }) : _dio = dio ?? TranslationService.createClient(),
       _directory = directory ?? _defaultDirectory;

  // 飞桨官方 PP-OCRv6 small。两个渠道解包后逐文件一致，识别配置里含唯一一份字典。
  static const _det = OcrModelFile(
    'det.onnx',
    'inference.onnx',
    9880512,
    'd73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e',
  );
  static const _rec = OcrModelFile(
    'rec.onnx',
    'inference.onnx',
    21159378,
    '5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634',
  );
  static const _config = OcrModelFile(
    'rec.yml',
    'inference.yml',
    150579,
    'ab078671bb49f06228eadccd34f1bb501e157f7a047095ffb943ba81512c77d1',
  );
  static const officialBundles = [
    OcrModelBundle(
      'PP-OCRv6_small_det_onnx',
      '956a0b620a4017cc04056c692be1703b0025d028',
      9891840,
      'd218f6fbf0f1c23d2161bd6ac7f5eaa6104fa89955c09290497e31008e2618e4',
      [_det],
    ),
    OcrModelBundle(
      'PP-OCRv6_small_rec_onnx',
      '296d43bc0ebced0fd9c605174aa5962e49810ab6',
      21319680,
      'd267ab077a44a0eedb1ea8f8c542d263f211de8e9d7a029bf9fcfff7e5a88fb1',
      [_rec, _config],
    ),
  ];
  static int get downloadBytes => _det.size + _rec.size + _config.size;
  final List<OcrModelBundle> bundles;
  final Dio _dio;
  final Future<Directory> Function() _directory;
  Future<void>? _pending;
  final Map<String, ({int size, int modifiedMs})> _verifiedFiles = {};

  static Future<Directory> _defaultDirectory() async => Directory(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'ocr',
      'ppocr-v6-small-onnx-1',
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

  /// 返回模型目录当前占用的总字节数（包含断点临时文件）。
  Future<int> installedBytes() async {
    final dir = await _directory();
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

  /// 删除已下载的离线识字模型以释放存储空间。
  Future<void> clear() async {
    while (_pending != null) {
      try {
        await _pending;
      } catch (_) {}
    }
    _verifiedFiles.clear();
    final dir = await _directory();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
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
      final old = Directory(p.join(dir.parent.path, 'ppocr-v6-1'));
      try {
        if (await old.exists()) await old.delete(recursive: true);
      } on FileSystemException {
        /* 下次下载时重试。 */
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
      bundle.archiveUrl,
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
    for (;;) {
      token.throwIfCancellationRequested();
      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            HttpHeaders.acceptEncodingHeader: 'identity',
            if (offset > 0) HttpHeaders.rangeHeader: 'bytes=$offset-',
          },
          validateStatus: (code) => code == 200 || code == 206 || code == 416,
          receiveTimeout: const Duration(seconds: 15),
          extra: {FluxRequestKeys.callTimeoutMillis: 120000},
        ),
      );
      final body = response.data!;
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      final partial = response.statusCode == 206;
      if (response.statusCode == 416 ||
          (partial && range != 'bytes $offset-${size - 1}/$size')) {
        await body.stream.listen((_) {}).cancel();
        if (offset == 0) throw const FormatException('OCR 下载范围无效');
        offset = 0;
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
        continue;
      }
      throw const FormatException('OCR 模型校验失败');
    }
  }

  void dispose() => _dio.close(force: true);
}
