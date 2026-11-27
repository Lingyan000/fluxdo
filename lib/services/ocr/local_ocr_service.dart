import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fluxdo_ocr/fluxdo_ocr.dart';
import 'package:image/image.dart' as img;
import 'package:yaml/yaml.dart';

import '../app_logger.dart';
import 'apple_vision_ocr.dart';
import 'ocr_model_store.dart';
import 'picture_text_layout.dart';

/// OCR 识别阶段。
enum OcrStage { decoding, detecting, recognizing }

/// OCR 识别进度事件。
class OcrProgress {
  const OcrProgress({
    required this.stage,
    this.completed = 0,
    this.total = 0,
  });

  final OcrStage stage;
  final int completed;
  final int total;

  double? get fraction =>
      total > 0 ? (completed / total).clamp(0.0, 1.0) : null;
}

/// 已解码的 RGBA 像素帧（直接复用 Flutter 引擎解码结果，跳过 PNG 往返编解码）。
class OcrRgbaImage {
  const OcrRgbaImage({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;
  final Uint8List rgba;
}

/// 单段 OCR 识别文本行（原图坐标系）。
class OcrTextLine {
  const OcrTextLine({
    required this.text,
    required this.bounds,
    required this.charBounds,
    required this.rowIndex,
  });

  final String text;

  /// 该段文本在原图中的包围盒。
  final Rect bounds;

  /// 与 [text] 的 UTF-16 字符索引一一对应的原图包围盒。
  final List<Rect> charBounds;

  /// 所属视觉行序号（从上到下递增；同一水平行内的多段共享同一个序号）。
  final int rowIndex;

  /// 返回子串 `[start, end)` 在原图中的合并包围盒。
  Rect boundsForRange(int start, int end) {
    if (text.isEmpty || start >= end) return bounds;
    final safeStart = start.clamp(0, text.length);
    final safeEnd = end.clamp(safeStart, text.length);
    if (safeStart >= safeEnd) return bounds;
    if (charBounds.length == text.length) {
      var rect = charBounds[safeStart];
      for (var i = safeStart + 1; i < safeEnd; i++) {
        rect = rect.expandToInclude(charBounds[i]);
      }
      return rect;
    }
    final left = bounds.left + bounds.width * (safeStart / text.length);
    final right = bounds.left + bounds.width * (safeEnd / text.length);
    return Rect.fromLTRB(left, bounds.top, right, bounds.bottom);
  }
}

/// 完整 OCR 识别结果（含原图尺寸与结构化文本行）。
class OcrResult {
  const OcrResult({
    required this.imageWidth,
    required this.imageHeight,
    required this.lines,
  });

  final int imageWidth;
  final int imageHeight;
  final List<OcrTextLine> lines;

  bool get isEmpty => lines.isEmpty;

  /// 按段落规则与中英自动间距拼合后的可读纯文本。
  String get plainText => PictureTextLayout.fromOcr(this).fullText;
}

/// 在常驻后台 isolate 内执行 PP-OCRv6 small 的检测、识别和 CTC 解码。
///
/// 关键性能优化：
/// - 常驻 Worker 复用已打开的 LiteRT 解释器与 XNNPACK 打包权重（空闲 45s 自动释放）
/// - 识别行宽分桶 + 按桶连续推理，将 `AllocateTensors` 次数从十余次压到 1~3 次
/// - 支持直传已解码 `OcrRgbaImage`（零 PNG 编解码），并用 256 项 LUT 直读字节流
class LocalOcrService {
  LocalOcrService({
    Future<OcrResult> Function(Uint8List bytes)? systemRecognizer,
    Future<bool> Function()? systemAvailabilityCheck,
  }) : _systemRecognizer = systemRecognizer ?? AppleVisionOcr.recognize,
       _systemAvailabilityCheck =
           systemAvailabilityCheck ?? AppleVisionOcr.isAvailable;

  static const _maxCacheEntries = 8;
  static const _workerIdleTimeout = Duration(seconds: 45);
  static const _detectMaxWidth = 960;
  // 常见手机竖屏截图（如 9:16 / 2:3）缩放后高度约 1300~1440，单次检测即可完成，
  // 避免切成 2 片重叠检测造成双倍推理与两次张量重分配；真正超长截图仍自动切片。
  static const _detectBandMaxHeight = 1440;
  static const _recHeight = 48;
  static const _recMaxWidth = 1600;
  static const _recOverlap = 96;

  /// 识别模型固定宽度桶：减少不同行宽触发 XNNPACK 重建计算图的次数。
  static const List<int> recognitionWidthBuckets = [
    320,
    480,
    640,
    960,
    1280,
    1600,
  ];

  // 预计算归一化查找表（256 项，避免百万像素循环中反复除法）。
  static final Float32List _detLutR = Float32List.fromList([
    for (var v = 0; v < 256; v++) (v / 255.0 - 0.406) / 0.225,
  ]);
  static final Float32List _detLutG = Float32List.fromList([
    for (var v = 0; v < 256; v++) (v / 255.0 - 0.456) / 0.224,
  ]);
  static final Float32List _detLutB = Float32List.fromList([
    for (var v = 0; v < 256; v++) (v / 255.0 - 0.485) / 0.229,
  ]);
  static final Float32List _recLut = Float32List.fromList([
    for (var v = 0; v < 256; v++) v / 127.5 - 1.0,
  ]);

  final Future<OcrResult> Function(Uint8List bytes) _systemRecognizer;
  final Future<bool> Function() _systemAvailabilityCheck;
  final LinkedHashMap<String, OcrResult> _cache = LinkedHashMap();

  /// 当前设备上的系统原生 OCR 引擎是否可用（macOS / iOS 为 Apple Vision）。
  Future<bool> isSystemEngineAvailable() => _systemAvailabilityCheck();
  String? _cachedDictPath;
  int? _cachedDictSize;
  int? _cachedDictModifiedMs;
  List<String>? _cachedDictionary;

  Isolate? _workerIsolate;
  SendPort? _workerCommandPort;
  ReceivePort? _workerExitPort;
  Future<SendPort>? _workerStarting;
  Timer? _idleTimer;
  Future<void> _serialQueue = Future<void>.value();
  int _nextTaskId = 1;
  int _activeTasks = 0;
  bool _disposed = false;

  /// 将原始缩放宽度收敛到最接近的固定桶，减少 `AllocateTensors` 频率。
  @visibleForTesting
  static int bucketRecognitionWidth(int rawWidth) {
    for (final bucket in recognitionWidthBuckets) {
      if (rawWidth <= bucket) return bucket;
    }
    return recognitionWidthBuckets.last;
  }

  /// 规划文本行识别顺序：
  /// - 指定 [priorityIdx] 时，优先识别该行及其同宽度桶的其余行，确保首行秒出且零额外重分配；
  /// - 其余行按所属宽度桶分组排序，最大限度复用同一个 XNNPACK 计算图。
  @visibleForTesting
  static List<int> planRecognitionOrder(List<Rect> boxes, {int? priorityIdx}) {
    if (boxes.length <= 1) {
      return List<int>.generate(boxes.length, (i) => i);
    }
    int bucketFor(Rect box) {
      final h = math.max(1.0, box.height);
      final lineWidth = math.max(1, (box.width * _recHeight / h).ceil());
      final firstSlice = math.min(lineWidth, _recMaxWidth);
      return bucketRecognitionWidth(firstSlice);
    }

    final buckets = [for (final b in boxes) bucketFor(b)];
    final indices = List<int>.generate(boxes.length, (i) => i);
    final priorityBucket = priorityIdx != null ? buckets[priorityIdx] : null;
    indices.sort((a, b) {
      if (priorityIdx != null) {
        if (a == priorityIdx) return -1;
        if (b == priorityIdx) return 1;
        final aSame = buckets[a] == priorityBucket;
        final bSame = buckets[b] == priorityBucket;
        if (aSame != bSame) return aSame ? -1 : 1;
      }
      final cmp = buckets[a].compareTo(buckets[b]);
      return cmp != 0 ? cmp : a.compareTo(b);
    });
    return indices;
  }

  /// 仅供单元测试验证 LUT 像素预处理与白底 Alpha 混合。
  @visibleForTesting
  static Float32List debugNormalizePixels(
    img.Image image,
    int width, {
    required bool detection,
  }) => _pixels(image, width, detection: detection);

  /// 仅供单元测试验证 CTC argmax 解码。
  @visibleForTesting
  static List<({String text, double leftPx, double rightPx})> debugDecodeTokens(
    Float32List scores,
    int steps,
    List<String> dictionary,
    int width,
    int from,
    int until,
  ) => _decodeTokens(scores, steps, dictionary, width, from, until);

  void _rememberResult(String cacheKey, OcrResult result) {
    _cache.remove(cacheKey);
    _cache[cacheKey] = result;
    while (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// 清空识别结果内存缓存并释放常驻工作 isolate（模型清理后必须释放旧句柄）。
  void clearCache() {
    _cache.clear();
    _cachedDictionary = null;
    _shutdownWorker();
  }

  /// 释放常驻工作 isolate 与定时器。
  void dispose() {
    _disposed = true;
    _cache.clear();
    _shutdownWorker();
  }

  /// 兼容接口：仅返回拼合后的纯文本。
  Future<String> recognize(
    Uint8List pngBytes,
    OcrModelPaths? paths, {
    bool useSystemEngine = false,
    CancelToken? cancelToken,
    Future<OcrRgbaImage?> Function()? loadRgba,
  }) async {
    final result = await recognizeDetailed(
      pngBytes,
      paths,
      useSystemEngine: useSystemEngine,
      cancelToken: cancelToken,
      loadRgba: loadRgba,
    );
    return result.plainText;
  }

  /// 完整识别接口：返回原图尺寸、逻辑行分组及每个字符的原图坐标，供识字、实况选字与隐私打码共用。
  ///
  /// - [useSystemEngine]：为 `true` 时优先调用系统原生 Vision 引擎（macOS/iOS 硬件加速，免模型下载）；
  ///   若原生识别异常且 [paths] 非空，自动回退到本地 LiteRT 模型。
  /// - [loadRgba]：可选的惰性 RGBA 帧提供者（仅在未命中缓存且实际执行 LiteRT 推理时调用，避免缓存命中或原生引擎下无谓的 GPU 回读）。
  /// - [priorityPoint]：可选的原图像素坐标；传入时优先识别离该点最近的那一行并立刻回调 [onPartial]。
  /// - [onDetected]：检测阶段完成后立刻触发（几百毫秒内），供 UI 播放文字行波纹点亮动画。
  /// - [onPartial]：识别过程中分批回传当前已识别出的 [OcrResult]，实现边识别边选字。
  Future<OcrResult> recognizeDetailed(
    Uint8List pngBytes,
    OcrModelPaths? paths, {
    bool useSystemEngine = false,
    CancelToken? cancelToken,
    Future<OcrRgbaImage?> Function()? loadRgba,
    void Function(OcrProgress)? onProgress,
    void Function(int imageWidth, int imageHeight, List<Rect> boxes)?
    onDetected,
    void Function(OcrResult partial)? onPartial,
    Offset? priorityPoint,
  }) async {
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;

    final fingerprint = pngBytes.isNotEmpty ? _fingerprint(pngBytes) : null;
    final enginePrefix = useSystemEngine ? 'vision' : 'litert';
    final cacheKey = fingerprint != null ? '$enginePrefix:$fingerprint' : null;
    if (cacheKey != null) {
      final cached = _cache.remove(cacheKey);
      if (cached != null) {
        _cache[cacheKey] = cached;
        onDetected?.call(
          cached.imageWidth,
          cached.imageHeight,
          [for (final l in cached.lines) l.bounds],
        );
        onPartial?.call(cached);
        return cached;
      }
    }

    if (useSystemEngine) {
      onProgress?.call(const OcrProgress(stage: OcrStage.recognizing));
      try {
        final result = await _systemRecognizer(pngBytes);
        if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
        if (cacheKey != null) {
          _rememberResult(cacheKey, result);
        }
        onDetected?.call(
          result.imageWidth,
          result.imageHeight,
          [for (final l in result.lines) l.bounds],
        );
        if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
        onPartial?.call(result);
        return result;
      } catch (error) {
        if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
        if (paths == null) rethrow;
        AppLogger.warning(
          '系统 Vision OCR 失败，自动回退至离线模型: $error',
          tag: 'OCR',
        );
      }
    }

    if (paths == null) {
      throw StateError('离线 OCR 模型路径缺失');
    }

    final litertCacheKey = fingerprint != null ? 'litert:$fingerprint' : null;
    if (litertCacheKey != null && litertCacheKey != cacheKey) {
      final cached = _cache.remove(litertCacheKey);
      if (cached != null) {
        _cache[litertCacheKey] = cached;
        onDetected?.call(
          cached.imageWidth,
          cached.imageHeight,
          [for (final l in cached.lines) l.bounds],
        );
        onPartial?.call(cached);
        return cached;
      }
    }

    OcrRgbaImage? predecodedRgba;
    if (loadRgba != null) {
      try {
        predecodedRgba = await loadRgba();
      } catch (_) {
        predecodedRgba = null;
      }
      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    }

    final cachedDictionary = await _tryGetCachedDictionary(paths.config);
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;

    // 串行占用常驻 Worker 内的单会话解释器，避免重入；排队期间若已取消直接退出。
    final gate = Completer<void>();
    final prev = _serialQueue;
    _serialQueue = gate.future;
    try {
      await prev.catchError((_) {});
      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
      return await _runInWorker(
        pngBytes: pngBytes,
        predecodedRgba: predecodedRgba,
        cacheKey: litertCacheKey,
        paths: paths,
        cachedDictionary: cachedDictionary,
        cancelToken: cancelToken,
        onProgress: onProgress,
        onDetected: onDetected,
        onPartial: onPartial,
        priorityPoint: priorityPoint,
      );
    } finally {
      gate.complete();
    }
  }

  Future<OcrResult> _runInWorker({
    required Uint8List pngBytes,
    required OcrRgbaImage? predecodedRgba,
    required String? cacheKey,
    required OcrModelPaths paths,
    required List<String>? cachedDictionary,
    required CancelToken? cancelToken,
    required void Function(OcrProgress)? onProgress,
    required void Function(int imageWidth, int imageHeight, List<Rect> boxes)?
    onDetected,
    required void Function(OcrResult partial)? onPartial,
    required Offset? priorityPoint,
  }) async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _activeTasks++;

    final commandPort = await _ensureWorker();
    if (cancelToken?.isCancelled ?? false) {
      _finishTaskSlot();
      throw cancelToken!.cancelError!;
    }

    final taskId = _nextTaskId++;
    final replyPort = ReceivePort();
    final completer = Completer<_WorkerResult>();
    var detectedWidth = 0;
    var detectedHeight = 0;
    final partialLines = <OcrTextLine>[];

    final cancelSub = cancelToken?.whenCancel.then((_) {
      _workerCommandPort?.send(_CancelTaskMessage(taskId));
    });
    if (cancelSub != null) unawaited(cancelSub);

    final subscription = replyPort.listen((message) {
      if (message is _ProgressMessage) {
        onProgress?.call(
          OcrProgress(
            stage: OcrStage.values[message.stage],
            completed: message.completed,
            total: message.total,
          ),
        );
      } else if (message is _DetectedMessage) {
        detectedWidth = message.imageWidth;
        detectedHeight = message.imageHeight;
        final boxes = <Rect>[
          for (var i = 0; i < message.boxes.length; i += 4)
            Rect.fromLTRB(
              message.boxes[i],
              message.boxes[i + 1],
              message.boxes[i + 2],
              message.boxes[i + 3],
            ),
        ];
        onDetected?.call(detectedWidth, detectedHeight, boxes);
      } else if (message is _PartialBatchMessage) {
        for (final item in message.lines) {
          partialLines.add(_hydrateLine(item));
        }
        if (detectedWidth > 0 && detectedHeight > 0) {
          onPartial?.call(
            OcrResult(
              imageWidth: detectedWidth,
              imageHeight: detectedHeight,
              lines: List<OcrTextLine>.of(partialLines),
            ),
          );
        }
      } else if (message is _WorkerResult) {
        if (!completer.isCompleted) completer.complete(message);
      } else if (message is _WorkerError) {
        if (!completer.isCompleted) {
          completer.completeError(
            message.isFormat
                ? FormatException(message.message)
                : StateError(message.message),
          );
        }
      }
    });

    final useRgba = predecodedRgba != null && predecodedRgba.rgba.isNotEmpty;
    commandPort.send(
      _RunTaskMessage(
        taskId: taskId,
        encodedBytes: useRgba ? null : TransferableTypedData.fromList([pngBytes]),
        rgbaBytes: useRgba
            ? TransferableTypedData.fromList([predecodedRgba.rgba])
            : null,
        rgbaWidth: useRgba ? predecodedRgba.width : 0,
        rgbaHeight: useRgba ? predecodedRgba.height : 0,
        detectorPath: paths.detector,
        recognizerPath: paths.recognizer,
        configPath: paths.config,
        cachedDictionary: cachedDictionary,
        priorityX: priorityPoint?.dx,
        priorityY: priorityPoint?.dy,
        emitDetected: onDetected != null,
        emitPartial: onPartial != null,
        replyPort: replyPort.sendPort,
      ),
    );

    try {
      final raw = await completer.future;
      if (raw.dictionary != null) {
        await _storeCachedDictionary(paths.config, raw.dictionary!);
      }
      final result = OcrResult(
        imageWidth: raw.imageWidth,
        imageHeight: raw.imageHeight,
        lines: [for (final item in raw.lines) _hydrateLine(item)],
      );
      if (cacheKey != null) {
        _rememberResult(cacheKey, result);
      }
      AppLogger.info(
        'OCR 识别完成: engine=litert total=${raw.totalMs}ms '
        'decode=${raw.decodeMs}ms open=${raw.openMs}ms '
        'det=${raw.detMs}ms rec=${raw.recMs}ms '
        'size=${raw.imageWidth}x${raw.imageHeight} '
        'lines=${result.lines.length} '
        'allocs=det:${raw.detAllocs}/rec:${raw.recAllocs} '
        'rgba=$useRgba',
        tag: 'OCR',
      );
      return result;
    } finally {
      await subscription.cancel();
      replyPort.close();
      _finishTaskSlot();
    }
  }

  Future<SendPort> _ensureWorker() async {
    final existing = _workerCommandPort;
    if (existing != null) return existing;
    final pending = _workerStarting;
    if (pending != null) return pending;

    final startFuture = () async {
      final handshake = ReceivePort();
      final exitPort = ReceivePort();
      final isolate = await Isolate.spawn(
        _workerMain,
        handshake.sendPort,
        debugName: 'fluxdo-ocr-worker',
        onExit: exitPort.sendPort,
      );
      final commandPort = await handshake.first as SendPort;
      handshake.close();
      if (_disposed) {
        commandPort.send(const _ShutdownWorkerMessage());
        exitPort.close();
        throw StateError('LocalOcrService 已释放');
      }
      _workerIsolate = isolate;
      _workerCommandPort = commandPort;
      _workerExitPort = exitPort;
      exitPort.listen((_) {
        if (identical(_workerIsolate, isolate)) {
          _workerIsolate = null;
          _workerCommandPort = null;
          _workerExitPort?.close();
          _workerExitPort = null;
        }
      });
      return commandPort;
    }();
    _workerStarting = startFuture;
    try {
      return await startFuture;
    } finally {
      if (identical(_workerStarting, startFuture)) {
        _workerStarting = null;
      }
    }
  }

  void _finishTaskSlot() {
    _activeTasks = math.max(0, _activeTasks - 1);
    if (_activeTasks == 0 && !_disposed && _workerCommandPort != null) {
      _idleTimer?.cancel();
      _idleTimer = Timer(_workerIdleTimeout, _shutdownWorker);
    }
  }

  void _shutdownWorker() {
    _idleTimer?.cancel();
    _idleTimer = null;
    final port = _workerCommandPort;
    _workerCommandPort = null;
    if (port != null) {
      port.send(const _ShutdownWorkerMessage());
    }
    _workerIsolate = null;
    _workerExitPort?.close();
    _workerExitPort = null;
  }

  static OcrTextLine _hydrateLine(_WorkerLine item) => OcrTextLine(
    text: item.text,
    bounds: Rect.fromLTRB(
      item.bounds[0],
      item.bounds[1],
      item.bounds[2],
      item.bounds[3],
    ),
    charBounds: [
      for (var i = 0; i < item.charBounds.length; i += 4)
        Rect.fromLTRB(
          item.charBounds[i],
          item.charBounds[i + 1],
          item.charBounds[i + 2],
          item.charBounds[i + 3],
        ),
    ],
    rowIndex: item.rowIndex,
  );

  static String _fingerprint(Uint8List bytes) =>
      '${bytes.length}:${sha256.convert(bytes)}';

  Future<List<String>?> _tryGetCachedDictionary(String configPath) async {
    if (_cachedDictionary == null || _cachedDictPath != configPath) return null;
    final stat = await File(configPath).stat();
    if (stat.type != FileSystemEntityType.file) return null;
    if (stat.size == _cachedDictSize &&
        stat.modified.millisecondsSinceEpoch == _cachedDictModifiedMs) {
      return _cachedDictionary;
    }
    return null;
  }

  Future<void> _storeCachedDictionary(
    String configPath,
    List<String> dictionary,
  ) async {
    final stat = await File(configPath).stat();
    if (stat.type != FileSystemEntityType.file) return;
    _cachedDictPath = configPath;
    _cachedDictSize = stat.size;
    _cachedDictModifiedMs = stat.modified.millisecondsSinceEpoch;
    _cachedDictionary = dictionary;
  }

  /// 常驻工作 isolate 入口：保活 detector / recognizer 会话，按任务执行并支持即时取消。
  static Future<void> _workerMain(SendPort mainPort) async {
    final inbox = ReceivePort();
    mainPort.send(inbox.sendPort);

    final cancelledTasks = <int>{};
    final queue = Queue<_RunTaskMessage>();
    var processing = false;
    var shuttingDown = false;

    OcrInferenceModel? detector;
    String? detectorPath;
    OcrInferenceModel? recognizer;
    String? recognizerPath;

    void closeModels() {
      recognizer?.close();
      recognizer = null;
      recognizerPath = null;
      detector?.close();
      detector = null;
      detectorPath = null;
    }

    Future<void> drainQueue() async {
      if (processing) return;
      processing = true;
      try {
        while (queue.isNotEmpty && !shuttingDown) {
          final task = queue.removeFirst();
          try {
            final res = await _executeTask(
              task: task,
              isCancelled: () =>
                  shuttingDown || cancelledTasks.contains(task.taskId),
              obtainDetector: (path) {
                if (detector == null || detectorPath != path) {
                  detector?.close();
                  detector = OcrInferenceModel.open(path);
                  detectorPath = path;
                }
                return detector!;
              },
              obtainRecognizer: (path) {
                if (recognizer == null || recognizerPath != path) {
                  recognizer?.close();
                  recognizer = OcrInferenceModel.open(path);
                  recognizerPath = path;
                }
                return recognizer!;
              },
            );
            task.replyPort.send(res);
          } catch (error) {
            task.replyPort.send(
              _WorkerError(
                error.toString(),
                isFormat: error is FormatException,
              ),
            );
          } finally {
            cancelledTasks.remove(task.taskId);
          }
        }
      } finally {
        processing = false;
        if (shuttingDown) {
          closeModels();
          inbox.close();
        }
      }
    }

    inbox.listen((message) {
      if (message is _CancelTaskMessage) {
        cancelledTasks.add(message.taskId);
      } else if (message is _ShutdownWorkerMessage) {
        shuttingDown = true;
        if (!processing) {
          closeModels();
          inbox.close();
        }
      } else if (message is _RunTaskMessage) {
        if (shuttingDown) {
          message.replyPort.send(const _WorkerError('OCR 工作线程已关闭'));
          return;
        }
        queue.addLast(message);
        unawaited(drainQueue());
      }
    });
  }

  static Future<_WorkerResult> _executeTask({
    required _RunTaskMessage task,
    required bool Function() isCancelled,
    required OcrInferenceModel Function(String path) obtainDetector,
    required OcrInferenceModel Function(String path) obtainRecognizer,
  }) async {
    final totalSw = Stopwatch()..start();
    var decodeMs = 0;
    var openMs = 0;
    var detMs = 0;
    var recMs = 0;
    var detAllocs = 0;
    var recAllocs = 0;

    Future<void> checkCancellation() async {
      await Future<void>.delayed(Duration.zero);
      if (isCancelled()) throw StateError('OCR 已取消');
    }

    void report(OcrStage stage, [int completed = 0, int total = 0]) {
      task.replyPort.send(_ProgressMessage(stage.index, completed, total));
    }

    report(OcrStage.decoding);
    final decodeSw = Stopwatch()..start();
    img.Image? image;
    OcrNativeImage? nativeImage;
    if (task.rgbaBytes != null && task.rgbaWidth > 0 && task.rgbaHeight > 0) {
      final raw = task.rgbaBytes!.materialize().asUint8List();
      nativeImage = OcrNativeImage.fromBytes(
        bytes: raw,
        width: task.rgbaWidth,
        height: task.rgbaHeight,
        channels: 4,
      );
    } else if (task.encodedBytes != null) {
      final bytes = task.encodedBytes!.materialize().asUint8List();
      image = img.decodeImage(bytes);
      if (image != null &&
          (image.format != img.Format.uint8 || image.hasPalette)) {
        image = image.convert(
          format: img.Format.uint8,
          numChannels: image.hasAlpha ? 4 : 3,
        );
      }
      if (image != null &&
          image.format == img.Format.uint8 &&
          (image.numChannels == 3 || image.numChannels == 4)) {
        nativeImage = OcrNativeImage.fromBytes(
          bytes: image.toUint8List(),
          width: image.width,
          height: image.height,
          channels: image.numChannels,
        );
      }
    }
    if (nativeImage == null && image == null) {
      throw const FormatException('无法解码 OCR 图片');
    }
    final imageWidth = nativeImage?.width ?? image!.width;
    final imageHeight = nativeImage?.height ?? image!.height;
    decodeMs = decodeSw.elapsedMilliseconds;

    try {
      await checkCancellation();

      report(OcrStage.detecting);
      final openDetSw = Stopwatch()..start();
      final detector = obtainDetector(task.detectorPath);
      openMs += openDetSw.elapsedMilliseconds;
      detector.resetAllocateCount();

      final detSw = Stopwatch()..start();
      final boxes = await _detect(
        image: image,
        nativeImage: nativeImage,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        model: detector,
        checkCancellation: checkCancellation,
        report: report,
      );
      detMs = detSw.elapsedMilliseconds;
      detAllocs = detector.allocateCount;

      if (task.emitDetected) {
        final flat = Float64List(boxes.length * 4);
        for (var i = 0; i < boxes.length; i++) {
          final b = boxes[i].box;
          flat[i * 4] = b.left;
          flat[i * 4 + 1] = b.top;
          flat[i * 4 + 2] = b.right;
          flat[i * 4 + 3] = b.bottom;
        }
        task.replyPort.send(_DetectedMessage(imageWidth, imageHeight, flat));
      }

      if (boxes.isEmpty) {
        return _WorkerResult(
          imageWidth: imageWidth,
          imageHeight: imageHeight,
          lines: const [],
          totalMs: totalSw.elapsedMilliseconds,
          decodeMs: decodeMs,
          openMs: openMs,
          detMs: detMs,
          recMs: 0,
          detAllocs: detAllocs,
          recAllocs: 0,
        );
      }
      await checkCancellation();

      List<String>? newlyLoadedDictionary;
      final dictionary =
          task.cachedDictionary ??
          (newlyLoadedDictionary = await _loadDictionary(task.configPath));

      int? priorityIdx;
      if (task.priorityX != null && task.priorityY != null) {
        final px = task.priorityX!;
        final py = task.priorityY!;
        var bestGap = double.infinity;
        for (var i = 0; i < boxes.length; i++) {
          final r = boxes[i].box;
          final gap =
              math.max(math.max(r.left - px, 0.0), px - r.right) +
              math.max(math.max(r.top - py, 0.0), py - r.bottom);
          if (gap < bestGap) {
            bestGap = gap;
            priorityIdx = i;
          }
        }
      }
      final order = planRecognitionOrder(
        [for (final entry in boxes) entry.box],
        priorityIdx: priorityIdx,
      );

      report(OcrStage.recognizing, 0, boxes.length);
      final openRecSw = Stopwatch()..start();
      final recognizer = obtainRecognizer(task.recognizerPath);
      openMs += openRecSw.elapsedMilliseconds;
      recognizer.resetAllocateCount();

      final recSw = Stopwatch()..start();
      final recognized = List<_WorkerLine?>.filled(boxes.length, null);
      final pendingBatch = <_WorkerLine>[];
      for (var step = 0; step < order.length; step++) {
        final idx = order[step];
        final entry = boxes[idx];
        final line = await _read(
          image: image,
          nativeImage: nativeImage,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
          box: entry.box,
          rowIndex: entry.rowIndex,
          model: recognizer,
          dictionary: dictionary,
          checkCancellation: checkCancellation,
        );
        if (line != null) {
          recognized[idx] = line;
          if (task.emitPartial) pendingBatch.add(line);
        }
        final isPriorityDone = step == 0 && priorityIdx != null;
        final isBatchDue = (step + 1) % 4 == 0 || step + 1 == order.length;
        if (task.emitPartial &&
            pendingBatch.isNotEmpty &&
            (isPriorityDone || isBatchDue)) {
          task.replyPort.send(
            _PartialBatchMessage(List<_WorkerLine>.of(pendingBatch)),
          );
          pendingBatch.clear();
        }
        if ((step + 1) % 2 == 0 || step + 1 == order.length) {
          report(OcrStage.recognizing, step + 1, boxes.length);
        }
      }
      recMs = recSw.elapsedMilliseconds;
      recAllocs = recognizer.allocateCount;

      final orderedLines = <_WorkerLine>[for (final line in recognized) ?line];
      return _WorkerResult(
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        lines: orderedLines,
        dictionary: newlyLoadedDictionary,
        totalMs: totalSw.elapsedMilliseconds,
        decodeMs: decodeMs,
        openMs: openMs,
        detMs: detMs,
        recMs: recMs,
        detAllocs: detAllocs,
        recAllocs: recAllocs,
      );
    } finally {
      nativeImage?.dispose();
    }
  }

  static Future<List<String>> _loadDictionary(String configPath) async {
    final Object? config = loadYaml(await File(configPath).readAsString());
    final Object? postProcess = config is YamlMap
        ? config['PostProcess']
        : null;
    final Object? characters = postProcess is YamlMap
        ? postProcess['character_dict']
        : null;
    if (characters is! YamlList ||
        characters.isEmpty ||
        characters.any((c) => c is! String)) {
      throw const FormatException('OCR 配置缺少字符字典');
    }
    return <String>['', ...characters.cast<String>(), ' '];
  }

  static Future<List<({Rect box, int rowIndex})>> _detect({
    required img.Image? image,
    required OcrNativeImage? nativeImage,
    required int imageWidth,
    required int imageHeight,
    required OcrInferenceModel model,
    required Future<void> Function() checkCancellation,
    required void Function(OcrStage, [int, int]) report,
  }) async {
    // 长截图以原图坐标切片，重叠区域让跨边界的文字能在相邻片中完整出现。
    final scale = math.min(1.0, _detectMaxWidth / imageWidth);
    int aligned(double dimension) => math.max(1, (dimension / 32).round()) * 32;
    final width = aligned(imageWidth * scale);
    final bandHeight = (_detectBandMaxHeight / scale).round();
    final overlap = (160 / scale).round();
    final stride = bandHeight - overlap;
    final totalBands = imageHeight <= bandHeight
        ? 1
        : ((imageHeight - overlap - 1) ~/ stride) + 1;
    final boxes = <Rect>[];
    var bandIndex = 0;
    for (var top = 0; top < imageHeight; top += stride) {
      await checkCancellation();
      final height = math.min(bandHeight, imageHeight - top);
      final inputHeight = aligned(height * scale);
      final List<Rect> detected;
      if (nativeImage != null) {
        final flat = OcrNativeOps.runDetectionBand(
          detector: model,
          image: nativeImage,
          cropY: top,
          cropHeight: height,
          dstWidth: width,
          dstHeight: inputHeight,
        );
        detected = [
          for (var i = 0; i + 3 < flat.length; i += 4)
            Rect.fromLTRB(flat[i], flat[i + 1], flat[i + 2], flat[i + 3]),
        ];
      } else {
        final fallback = image!;
        final band = top == 0 && height == fallback.height
            ? fallback
            : img.copyCrop(
                fallback,
                x: 0,
                y: top,
                width: fallback.width,
                height: height,
              );
        final resized =
            band.width == width && band.height == inputHeight
            ? band
            : img.copyResize(
                band,
                width: width,
                height: inputHeight,
                interpolation: img.Interpolation.linear,
              );
        final input = _pixels(resized, width, detection: true);
        detected = model.infer(width, inputHeight, input, (shape, scores) {
          if (shape.length != 4 ||
              shape[0] != 1 ||
              shape[1] != 1 ||
              shape[2] != inputHeight ||
              shape[3] != width) {
            throw const FormatException('OCR 检测输出尺寸不匹配');
          }
          return _regions(scores, width, inputHeight);
        });
      }
      final last = top + height == imageHeight;
      for (final box in detected) {
        if ((top > 0 && box.top <= 1) ||
            (!last && box.bottom >= inputHeight - 1)) {
          continue;
        }
        boxes.add(
          Rect.fromLTRB(
            box.left * imageWidth / width,
            top + box.top * height / inputHeight,
            box.right * imageWidth / width,
            top + box.bottom * height / inputHeight,
          ),
        );
      }
      bandIndex++;
      if (totalBands > 1) {
        report(OcrStage.detecting, bandIndex, totalBands);
      }
      if (last) break;
    }
    return _readingOrder(boxes);
  }

  // 两个模型都接收平面的 BGR 张量。未填充的识别列保持归一化后的零值。
  // 直接读取底层 Uint8List + 256 项 LUT，并内联处理透明像素的白底合成，
  // 省掉 `package:image` 像素迭代器与整图 `compositeImage` 拷贝。
  static Float32List _pixels(
    img.Image image,
    int width, {
    required bool detection,
  }) {
    final imgH = image.height;
    final imgW = image.width;
    final plane = width * imgH;
    final plane2 = plane * 2;
    final values = Float32List(3 * plane);
    final channels = image.numChannels;

    if (image.format == img.Format.uint8 && (channels == 3 || channels == 4)) {
      final raw = image.toUint8List();
      final detR = _detLutR;
      final detG = _detLutG;
      final detB = _detLutB;
      final recLut = _recLut;

      var src = 0;
      if (detection) {
        for (var y = 0; y < imgH; y++) {
          var dst = y * width;
          if (channels == 4) {
            for (var x = 0; x < imgW; x++, dst++, src += 4) {
              var r = raw[src];
              var g = raw[src + 1];
              var b = raw[src + 2];
              final a = raw[src + 3];
              if (a != 255) {
                final inv = 255 - a;
                r = (r * a + 255 * inv + 127) ~/ 255;
                g = (g * a + 255 * inv + 127) ~/ 255;
                b = (b * a + 255 * inv + 127) ~/ 255;
              }
              values[dst] = detB[b];
              values[plane + dst] = detG[g];
              values[plane2 + dst] = detR[r];
            }
          } else {
            for (var x = 0; x < imgW; x++, dst++, src += 3) {
              values[dst] = detB[raw[src + 2]];
              values[plane + dst] = detG[raw[src + 1]];
              values[plane2 + dst] = detR[raw[src]];
            }
          }
        }
      } else {
        for (var y = 0; y < imgH; y++) {
          var dst = y * width;
          if (channels == 4) {
            for (var x = 0; x < imgW; x++, dst++, src += 4) {
              var r = raw[src];
              var g = raw[src + 1];
              var b = raw[src + 2];
              final a = raw[src + 3];
              if (a != 255) {
                final inv = 255 - a;
                r = (r * a + 255 * inv + 127) ~/ 255;
                g = (g * a + 255 * inv + 127) ~/ 255;
                b = (b * a + 255 * inv + 127) ~/ 255;
              }
              values[dst] = recLut[b];
              values[plane + dst] = recLut[g];
              values[plane2 + dst] = recLut[r];
            }
          } else {
            for (var x = 0; x < imgW; x++, dst++, src += 3) {
              values[dst] = recLut[raw[src + 2]];
              values[plane + dst] = recLut[raw[src + 1]];
              values[plane2 + dst] = recLut[raw[src]];
            }
          }
        }
      }
      return values;
    }

    // 兜底：灰度或非 3/4 通道图片。
    for (final pixel in image) {
      final pos = pixel.y * width + pixel.x;
      var r = pixel.r.toInt().clamp(0, 255);
      var g = pixel.g.toInt().clamp(0, 255);
      var b = pixel.b.toInt().clamp(0, 255);
      if (image.hasAlpha) {
        final a = pixel.a.toInt().clamp(0, 255);
        if (a != 255) {
          final inv = 255 - a;
          r = (r * a + 255 * inv + 127) ~/ 255;
          g = (g * a + 255 * inv + 127) ~/ 255;
          b = (b * a + 255 * inv + 127) ~/ 255;
        }
      }
      if (detection) {
        values[pos] = _detLutB[b];
        values[plane + pos] = _detLutG[g];
        values[plane2 + pos] = _detLutR[r];
      } else {
        values[pos] = _recLut[b];
        values[plane + pos] = _recLut[g];
        values[plane2 + pos] = _recLut[r];
      }
    }
    return values;
  }

  // 按水平连续段遍历概率图，使用官方检测配置的二值化、置信度和扩边参数。
  static List<Rect> _regions(Float32List scores, int width, int height) {
    const threshold = 0.2;
    final regions = <Rect>[];
    final pending = <int>[];
    for (var seed = 0; seed < scores.length; seed++) {
      if (scores[seed] <= threshold) continue;
      pending.add(seed);
      var left = width, right = 0, top = height, bottom = 0, count = 0;
      var sum = 0.0;
      while (pending.isNotEmpty) {
        final pos = pending.removeLast();
        if (scores[pos] <= threshold) continue;
        final y = pos ~/ width;
        final row = y * width;
        var x = pos - row;
        while (x > 0 && scores[row + x - 1] > threshold) {
          x--;
        }
        left = math.min(left, x);
        top = math.min(top, y);
        bottom = math.max(bottom, y + 1);
        var above = false, below = false;
        while (x < width && scores[row + x] > threshold) {
          final i = row + x;
          sum += scores[i];
          count++;
          scores[i] = 0;
          final hasAbove = y > 0 && scores[i - width] > threshold;
          final hasBelow = y + 1 < height && scores[i + width] > threshold;
          if (hasAbove && !above) pending.add(i - width);
          if (hasBelow && !below) pending.add(i + width);
          above = hasAbove;
          below = hasBelow;
          x++;
        }
        right = math.max(right, x);
      }
      final w = right - left, h = bottom - top;
      if (math.min(w, h) < 3 || sum / count < 0.45) continue;
      final padding = 1.4 * w * h / (2 * (w + h));
      regions.add(
        Rect.fromLTWH(
          left.toDouble(),
          top.toDouble(),
          w.toDouble(),
          h.toDouble(),
        ).inflate(padding),
      );
    }
    return regions;
  }

  static List<({Rect box, int rowIndex})> _readingOrder(List<Rect> boxes) {
    double area(Rect box) => box.width * box.height;
    boxes.sort((a, b) => area(b).compareTo(area(a)));
    final unique = <Rect>[];
    for (final box in boxes) {
      if (!unique.any((other) {
        final overlap = box.intersect(other);
        return !overlap.isEmpty && area(overlap) > 0.6 * area(box);
      })) {
        unique.add(box);
      }
    }
    unique.sort((a, b) => a.center.dy.compareTo(b.center.dy));
    final ordered = <({Rect box, int rowIndex})>[];
    final row = <Rect>[];
    var rowIndex = 0;

    void finishRow() {
      if (row.isEmpty) return;
      row.sort((a, b) => a.left.compareTo(b.left));
      for (final item in row) {
        ordered.add((box: item, rowIndex: rowIndex));
      }
      rowIndex++;
      row.clear();
    }

    for (final box in unique) {
      if (row.isNotEmpty &&
          box.center.dy - row.first.center.dy >
              math.min(box.height, row.first.height) / 2) {
        finishRow();
      }
      row.add(box);
    }
    finishRow();
    return ordered;
  }

  static Future<_WorkerLine?> _read({
    required img.Image? image,
    required OcrNativeImage? nativeImage,
    required int imageWidth,
    required int imageHeight,
    required Rect box,
    required int rowIndex,
    required OcrInferenceModel model,
    required List<String> dictionary,
    required Future<void> Function() checkCancellation,
  }) async {
    final bounds = box.intersect(
      Rect.fromLTWH(0, 0, imageWidth.toDouble(), imageHeight.toDouble()),
    );
    if (bounds.isEmpty) return null;
    final top = bounds.top.floor(), bottom = bounds.bottom.ceil();
    final left = bounds.left.floor(), right = bounds.right.ceil();
    if (right <= left || bottom <= top) return null;
    const height = _recHeight, maxWidth = _recMaxWidth, overlap = _recOverlap;
    final lineWidth = math.max(
      1,
      ((right - left) * height / (bottom - top)).ceil(),
    );
    final text = StringBuffer();
    final charBounds = <double>[];
    for (var start = 0; start < lineWidth; start += maxWidth - overlap) {
      await checkCancellation();
      final end = math.min(lineWidth, start + maxWidth);
      final x = left + (start * (right - left) / lineWidth).floor();
      final xEnd = math.max(
        x + 1,
        left + (end * (right - left) / lineWidth).ceil(),
      );
      final cropW = math.min(imageWidth - x, xEnd - x);
      final cropH = math.min(imageHeight - top, bottom - top);
      if (cropW <= 0 || cropH <= 0) break;
      final resizedW = math.max(1, end - start);
      final width = bucketRecognitionWidth(resizedW);
      final last = end == lineWidth;
      final fromPx = start == 0 ? 0.0 : (overlap ~/ 2).toDouble();
      final untilPx = last
          ? resizedW.toDouble()
          : (resizedW - overlap ~/ 2).toDouble();

      final List<({String text, double leftPx, double rightPx})> tokens;
      if (nativeImage != null) {
        final decoded = OcrNativeOps.runRecognitionSlice(
          recognizer: model,
          image: nativeImage,
          cropX: x,
          cropY: top,
          cropWidth: cropW,
          cropHeight: cropH,
          resizedWidth: resizedW,
          bucketWidth: width,
          dstHeight: height,
          fromPx: fromPx,
          untilPx: untilPx,
          expectedClasses: dictionary.length,
        );
        tokens = [
          for (var i = 0; i < decoded.labels.length; i++)
            (
              text: dictionary[decoded.labels[i]],
              leftPx: decoded.leftPx[i],
              rightPx: decoded.rightPx[i],
            ),
        ];
      } else {
        final fallback = image!;
        final part = img.copyCrop(
          fallback,
          x: x,
          y: top,
          width: cropW,
          height: cropH,
        );
        final resized = img.copyResize(
          part,
          height: height,
          width: resizedW,
          interpolation: img.Interpolation.linear,
        );
        tokens = model.infer(
          width,
          height,
          _pixels(resized, width, detection: false),
          (shape, scores) {
            if (shape.length != 3 ||
                shape[0] != 1 ||
                shape[2] != dictionary.length) {
              throw const FormatException('OCR 模型与字典不匹配');
            }
            return _decodeTokens(
              scores,
              shape[1],
              dictionary,
              width,
              fromPx.toInt(),
              untilPx.toInt(),
            );
          },
        );
      }
      final scaleX = cropW / resizedW;
      for (final token in tokens) {
        final rawLeft = (x + token.leftPx * scaleX)
            .clamp(bounds.left, bounds.right)
            .toDouble();
        final rawRight = (x + token.rightPx * scaleX)
            .clamp(math.min(rawLeft + 1.0, bounds.right), bounds.right)
            .toDouble();
        final unitCount = token.text.length;
        text.write(token.text);
        if (unitCount == 1) {
          charBounds
            ..add(rawLeft)
            ..add(bounds.top)
            ..add(rawRight)
            ..add(bounds.bottom);
        } else {
          final span = rawRight - rawLeft;
          for (var u = 0; u < unitCount; u++) {
            final uLeft = rawLeft + span * (u / unitCount);
            final uRight = rawLeft + span * ((u + 1) / unitCount);
            charBounds
              ..add(uLeft)
              ..add(bounds.top)
              ..add(uRight)
              ..add(bounds.bottom);
          }
        }
      }
      if (last) break;
    }
    final rawText = text.toString();
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) return null;

    // 同步裁掉首尾空白对应的字符框，保持 text 与 charBounds 一一对齐。
    final leading = rawText.length - rawText.trimLeft().length;
    final trailing = rawText.length - rawText.trimRight().length;
    final keptCharBounds = charBounds.sublist(
      leading * 4,
      charBounds.length - trailing * 4,
    );
    return _WorkerLine(
      text: trimmed,
      bounds: Float64List.fromList([
        bounds.left,
        bounds.top,
        bounds.right,
        bounds.bottom,
      ]),
      charBounds: Float64List.fromList(keptCharBounds),
      rowIndex: rowIndex,
    );
  }

  static List<({String text, double leftPx, double rightPx})> _decodeTokens(
    Float32List scores,
    int steps,
    List<String> dictionary,
    int width,
    int from,
    int until,
  ) {
    final result = <({String text, double leftPx, double rightPx})>[];
    final classes = dictionary.length;
    var previous = 0, start = 0;
    for (var step = 0; step <= steps; step++) {
      var label = 0;
      if (step < steps) {
        final offset = step * classes;
        var bestScore = scores[offset];
        for (var c = 1; c < classes; c++) {
          final s = scores[offset + c];
          if (s > bestScore) {
            bestScore = s;
            label = c;
          }
        }
      }
      if (label == previous) continue;
      final leftPx = start * width / steps;
      final rightPx = step * width / steps;
      final center = (leftPx + rightPx) / 2;
      if (previous != 0 && center >= from && center < until) {
        result.add((
          text: dictionary[previous],
          leftPx: leftPx,
          rightPx: rightPx,
        ));
      }
      previous = label;
      start = step;
    }
    return result;
  }
}

class _RunTaskMessage {
  const _RunTaskMessage({
    required this.taskId,
    required this.encodedBytes,
    required this.rgbaBytes,
    required this.rgbaWidth,
    required this.rgbaHeight,
    required this.detectorPath,
    required this.recognizerPath,
    required this.configPath,
    required this.cachedDictionary,
    required this.priorityX,
    required this.priorityY,
    required this.emitDetected,
    required this.emitPartial,
    required this.replyPort,
  });

  final int taskId;
  final TransferableTypedData? encodedBytes;
  final TransferableTypedData? rgbaBytes;
  final int rgbaWidth;
  final int rgbaHeight;
  final String detectorPath;
  final String recognizerPath;
  final String configPath;
  final List<String>? cachedDictionary;
  final double? priorityX;
  final double? priorityY;
  final bool emitDetected;
  final bool emitPartial;
  final SendPort replyPort;
}

class _CancelTaskMessage {
  const _CancelTaskMessage(this.taskId);
  final int taskId;
}

class _ShutdownWorkerMessage {
  const _ShutdownWorkerMessage();
}

class _WorkerError {
  const _WorkerError(this.message, {this.isFormat = false});
  final String message;
  final bool isFormat;
}

class _ProgressMessage {
  const _ProgressMessage(this.stage, this.completed, this.total);
  final int stage;
  final int completed;
  final int total;
}

class _DetectedMessage {
  const _DetectedMessage(this.imageWidth, this.imageHeight, this.boxes);
  final int imageWidth;
  final int imageHeight;
  final Float64List boxes;
}

class _PartialBatchMessage {
  const _PartialBatchMessage(this.lines);
  final List<_WorkerLine> lines;
}

class _WorkerLine {
  const _WorkerLine({
    required this.text,
    required this.bounds,
    required this.charBounds,
    required this.rowIndex,
  });

  final String text;
  final Float64List bounds;
  final Float64List charBounds;
  final int rowIndex;
}

class _WorkerResult {
  const _WorkerResult({
    required this.imageWidth,
    required this.imageHeight,
    required this.lines,
    this.dictionary,
    this.totalMs = 0,
    this.decodeMs = 0,
    this.openMs = 0,
    this.detMs = 0,
    this.recMs = 0,
    this.detAllocs = 0,
    this.recAllocs = 0,
  });

  final int imageWidth;
  final int imageHeight;
  final List<_WorkerLine> lines;
  final List<String>? dictionary;
  final int totalMs;
  final int decodeMs;
  final int openMs;
  final int detMs;
  final int recMs;
  final int detAllocs;
  final int recAllocs;
}
