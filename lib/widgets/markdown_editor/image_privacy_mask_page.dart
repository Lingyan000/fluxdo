import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/s.dart';
import '../../providers/image_ocr_provider.dart';
import '../../services/app_logger.dart';
import '../../services/ocr/image_mask_renderer.dart';
import '../../services/ocr/local_ocr_service.dart';
import '../../services/ocr/ocr_model_store.dart';
import '../../services/ocr/privacy_detector.dart';
import '../../services/toast_service.dart';
import '../../utils/image_tool_bytes.dart';

/// 打开全屏交互式隐私打码页，返回已应用打码的图片字节（取消则返回 null）。
Future<Uint8List?> showImagePrivacyMaskPage(
  BuildContext context, {
  required Uint8List bytes,
  bool encodePng = true,
}) => Navigator.of(context).push<Uint8List>(
  InteractionPageRoute(
    builder: (_) => ImagePrivacyMaskPage(
      bytes: bytes,
      encodePng: encodePng,
    ),
  ),
);

enum _MaskToolMode { auto, manual }

/// 全屏隐私打码页：自动定位文字隐私与二维码，支持点选切换、点击任意文字行补充打码、
/// 手动拖动框选区域，并实时预览马赛克 / 模糊 / 纯色三种遮挡样式。
class ImagePrivacyMaskPage extends ConsumerStatefulWidget {
  const ImagePrivacyMaskPage({
    super.key,
    required this.bytes,
    this.encodePng = true,
  });

  final Uint8List bytes;
  final bool encodePng;

  @override
  ConsumerState<ImagePrivacyMaskPage> createState() =>
      _ImagePrivacyMaskPageState();
}

class _ImagePrivacyMaskPageState extends ConsumerState<ImagePrivacyMaskPage> {
  final _token = CancelToken();
  final _transformController = TransformationController();

  Uint8List? _normalizedPng;
  ui.Image? _decodedImage;
  ui.Image? _mosaicPreviewImage;
  OcrResult? _ocrResult;

  final List<PrivacyRegion> _regions = [];
  final List<List<PrivacyRegion>> _undoStack = [];
  int _manualCounter = 0;

  _MaskToolMode _toolMode = _MaskToolMode.auto;
  PrivacyMaskStyle _maskStyle = PrivacyMaskStyle.mosaic;

  bool _initializing = true;
  bool _scanningQr = false;
  bool _scanningOcr = false;
  bool _ocrModelMissing = false;
  bool _downloadingOcr = false;
  double? _downloadProgress;
  OcrProgress? _ocrProgress;
  bool _applying = false;

  /// 手动框选拖动状态（原图像素坐标）。
  Offset? _dragStartImage;
  Rect? _draftImageRect;

  @override
  void initState() {
    super.initState();
    _prepareAndScan();
  }

  @override
  void dispose() {
    _token.cancel();
    _transformController.dispose();
    _decodedImage?.dispose();
    _mosaicPreviewImage?.dispose();
    super.dispose();
  }

  Future<ui.Image> _decodeRgbaImage(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  Future<void> _buildMosaicPreview(Uint8List png) async {
    try {
      final grid = await ImageMaskRenderer.buildMosaicPreviewGrid(png);
      if (grid == null || !mounted || _token.isCancelled) return;
      final preview = await _decodeRgbaImage(
        grid.rgba,
        grid.width,
        grid.height,
      );
      if (!mounted || _token.isCancelled) {
        preview.dispose();
        return;
      }
      setState(() {
        _mosaicPreviewImage?.dispose();
        _mosaicPreviewImage = preview;
      });
    } catch (error, stackTrace) {
      AppLogger.warning(
        '生成马赛克预览纹理失败: $error',
        tag: 'PrivacyMask',
        fields: {'stackTrace': stackTrace.toString()},
      );
    }
  }

  Future<void> _prepareAndScan() async {
    try {
      final png = await ImageToolBytes.png(widget.bytes);
      if (!mounted || _token.isCancelled) return;
      final decoded = await decodeImageFromList(png);
      if (!mounted || _token.isCancelled) {
        decoded.dispose();
        return;
      }
      setState(() {
        _normalizedPng = png;
        _decodedImage = decoded;
        _initializing = false;
      });

      // 并行生成真实马赛克预览纹理、二维码扫描与 OCR 文本隐私扫描。
      await Future.wait([
        _buildMosaicPreview(png),
        _scanQrCodes(png),
        _scanOcrIfReady(png),
      ]);
    } catch (error, stackTrace) {
      if (!mounted) return;
      AppLogger.error(
        '隐私打码图片初始化失败',
        tag: 'PrivacyMask',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() => _initializing = false);
      ToastService.showError(S.current.imageMask_applyFailed);
    }
  }

  Future<void> _scanQrCodes(Uint8List png) async {
    setState(() => _scanningQr = true);
    try {
      final qrRegions = await PrivacyDetector.detectQrCodes(png);
      if (!mounted || _token.isCancelled) return;
      if (qrRegions.isNotEmpty) {
        setState(() {
          _regions.removeWhere((r) => r.category == PrivacyCategory.qrCode);
          _regions.addAll(qrRegions);
        });
      }
    } catch (error, stackTrace) {
      // 二维码检测失败不阻断文本检测和手动打码。
      AppLogger.warning(
        '隐私打码二维码检测失败: $error',
        tag: 'PrivacyMask',
        fields: {'stackTrace': stackTrace.toString()},
      );
    } finally {
      if (mounted) setState(() => _scanningQr = false);
    }
  }

  Future<void> _scanOcrIfReady(Uint8List png) async {
    final useSystemEngine = await shouldUseSystemOcrEngine(ref);
    if (!mounted || _token.isCancelled) return;
    if (useSystemEngine) {
      await _runOcrScan(png, useSystemEngine: true);
      return;
    }
    final store = ref.read(ocrModelStoreProvider);
    final ready = await store.isReady();
    if (!mounted || _token.isCancelled) return;
    if (!ready) {
      setState(() => _ocrModelMissing = true);
      return;
    }
    await _runOcrScan(png);
  }

  Future<void> _downloadAndScanOcr() async {
    final png = _normalizedPng;
    if (png == null || _downloadingOcr) return;
    setState(() {
      _downloadingOcr = true;
      _downloadProgress = null;
    });
    try {
      final store = ref.read(ocrModelStoreProvider);
      await store.download(
        cancelToken: _token,
        onProgress: (p) {
          if (mounted) setState(() => _downloadProgress = p);
        },
      );
      if (!mounted || _token.isCancelled) return;
      setState(() {
        _downloadingOcr = false;
        _downloadProgress = null;
        _ocrModelMissing = false;
      });
      await _runOcrScan(png);
    } catch (error, stackTrace) {
      if (!mounted || _token.isCancelled) return;
      AppLogger.error(
        '隐私打码下载 OCR 模型失败',
        tag: 'PrivacyMask',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() {
        _downloadingOcr = false;
        _downloadProgress = null;
      });
      ToastService.showError(S.current.imageViewer_ocrDownloadFailed);
    }
  }

  Future<void> _runOcrScan(Uint8List png, {bool useSystemEngine = false}) async {
    setState(() {
      _scanningOcr = true;
      _ocrProgress = null;
    });
    try {
      final store = ref.read(ocrModelStoreProvider);
      final service = ref.read(localOcrServiceProvider);
      final paths = useSystemEngine
          ? (await store.isReady() ? await store.paths() : null)
          : await store.paths();
      final paragraphModelPath = await store.paragraphModelPathIfReady();
      if (!mounted || _token.isCancelled) return;
      final ocr = await service.recognizeDetailed(
        png,
        paths,
        useSystemEngine: useSystemEngine,
        paragraphModelPath: paragraphModelPath,
        cancelToken: _token,
        onProgress: (progress) {
          if (mounted) setState(() => _ocrProgress = progress);
        },
      );
      if (!mounted || _token.isCancelled) return;
      final detected = PrivacyDetector.detectText(ocr);
      setState(() {
        _ocrResult = ocr;
        _regions.removeWhere(
          (r) =>
              r.category != PrivacyCategory.qrCode &&
              r.category != PrivacyCategory.manual,
        );
        _regions.insertAll(0, detected);
      });
    } catch (error, stackTrace) {
      if (!mounted || _token.isCancelled) return;
      AppLogger.error(
        '隐私打码 OCR 扫描失败',
        tag: 'PrivacyMask',
        error: error,
        stackTrace: stackTrace,
      );
      ToastService.showError(S.current.imageViewer_ocrFailed);
    } finally {
      if (mounted) {
        setState(() {
          _scanningOcr = false;
          _ocrProgress = null;
        });
      }
    }
  }

  void _pushUndo() {
    _undoStack.add(List<PrivacyRegion>.of(_regions));
    if (_undoStack.length > 30) {
      _undoStack.removeAt(0);
    }
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _regions
        ..clear()
        ..addAll(_undoStack.removeLast());
    });
  }

  void _toggleAllDetected() {
    if (_regions.isEmpty) return;
    _pushUndo();
    HapticFeedback.selectionClick();
    final hasAnyEnabled = _regions.any((r) => r.enabled);
    setState(() {
      if (hasAnyEnabled) {
        for (var i = 0; i < _regions.length; i++) {
          _regions[i] = _regions[i].copyWith(enabled: false);
        }
      } else {
        for (var i = 0; i < _regions.length; i++) {
          _regions[i] = _regions[i].copyWith(enabled: true);
        }
      }
    });
  }

  void _toggleCategory(PrivacyCategory category) {
    final indices = <int>[
      for (var i = 0; i < _regions.length; i++)
        if (_regions[i].category == category) i,
    ];
    if (indices.isEmpty) return;
    _pushUndo();
    HapticFeedback.selectionClick();
    final anyEnabled = indices.any((i) => _regions[i].enabled);
    setState(() {
      for (final i in indices) {
        _regions[i] = _regions[i].copyWith(enabled: !anyEnabled);
      }
    });
  }

  void _handleCanvasTap(Offset imagePoint) {
    // 1. 优先命中已存在的隐私框（后添加的在上层，逆序检测）
    for (var i = _regions.length - 1; i >= 0; i--) {
      final region = _regions[i];
      if (region.bounds.inflate(8).contains(imagePoint)) {
        _pushUndo();
        HapticFeedback.selectionClick();
        setState(() {
          if (region.category == PrivacyCategory.manual && region.enabled) {
            _regions.removeAt(i);
          } else {
            _regions[i] = region.copyWith(enabled: !region.enabled);
          }
        });
        return;
      }
    }

    // 2. 智能点选模式下，点击任意未命中的 OCR 文本行直接补充打码
    if (_toolMode == _MaskToolMode.auto && _ocrResult != null) {
      for (final line in _ocrResult!.lines) {
        if (line.bounds.inflate(6).contains(imagePoint)) {
          _pushUndo();
          HapticFeedback.selectionClick();
          final limit = Rect.fromLTWH(
            0,
            0,
            _ocrResult!.imageWidth.toDouble(),
            _ocrResult!.imageHeight.toDouble(),
          );
          final pad = math.max(2.0, line.bounds.height * 0.1);
          final padded = Rect.fromLTRB(
            (line.bounds.left - pad).clamp(limit.left, limit.right),
            (line.bounds.top - pad).clamp(limit.top, limit.bottom),
            (line.bounds.right + pad).clamp(limit.left, limit.right),
            (line.bounds.bottom + pad).clamp(limit.top, limit.bottom),
          );
          setState(() {
            _regions.add(
              PrivacyRegion(
                id: 'manual_${_manualCounter++}',
                category: PrivacyCategory.manual,
                bounds: padded,
                preview: line.text,
              ),
            );
          });
          return;
        }
      }
    }
  }

  void _handleManualPanStart(Offset imagePoint) {
    setState(() {
      _dragStartImage = imagePoint;
      _draftImageRect = Rect.fromPoints(imagePoint, imagePoint);
    });
  }

  void _handleManualPanUpdate(Offset imagePoint, Size imageSize) {
    final start = _dragStartImage;
    if (start == null) return;
    final clamped = Offset(
      imagePoint.dx.clamp(0.0, imageSize.width),
      imagePoint.dy.clamp(0.0, imageSize.height),
    );
    setState(() {
      _draftImageRect = Rect.fromPoints(start, clamped);
    });
  }

  void _handleManualPanEnd() {
    final draft = _draftImageRect;
    setState(() {
      _dragStartImage = null;
      _draftImageRect = null;
    });
    if (draft == null || draft.width < 8 || draft.height < 8) return;
    _pushUndo();
    HapticFeedback.selectionClick();
    setState(() {
      _regions.add(
        PrivacyRegion(
          id: 'manual_${_manualCounter++}',
          category: PrivacyCategory.manual,
          bounds: draft,
        ),
      );
    });
  }

  Future<void> _applyMask() async {
    final png = _normalizedPng;
    if (png == null || _applying) return;
    final activeRects = [
      for (final r in _regions)
        if (r.enabled) r.bounds,
    ];
    if (activeRects.isEmpty) return;

    setState(() => _applying = true);
    try {
      final rendered = await ImageMaskRenderer.render(
        imageBytes: png,
        rects: activeRects,
        style: _maskStyle,
        encodePng: widget.encodePng,
      );
      if (!mounted) return;
      Navigator.of(context).pop(rendered);
    } catch (error, stackTrace) {
      if (!mounted) return;
      AppLogger.error(
        '应用隐私打码渲染失败',
        tag: 'PrivacyMask',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() => _applying = false);
      ToastService.showError(S.current.imageMask_applyFailed);
    }
  }

  int get _enabledCount => _regions.where((r) => r.enabled).length;

  bool get _isScanning => _scanningQr || _scanningOcr;

  String _categoryLabel(BuildContext context, PrivacyCategory category) {
    final l10n = context.l10n;
    return switch (category) {
      PrivacyCategory.phone => l10n.imageMask_catPhone,
      PrivacyCategory.email => l10n.imageMask_catEmail,
      PrivacyCategory.idCard => l10n.imageMask_catIdCard,
      PrivacyCategory.bankCard => l10n.imageMask_catBankCard,
      PrivacyCategory.secret => l10n.imageMask_catSecret,
      PrivacyCategory.ipAddress => l10n.imageMask_catIp,
      PrivacyCategory.account => l10n.imageMask_catAccount,
      PrivacyCategory.qrCode => l10n.imageMask_catQrCode,
      PrivacyCategory.manual => l10n.imageMask_catManual,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final enabledCount = _enabledCount;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        leading: const BackButton(),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.imageMask_title),
            if (!_initializing)
              Text(
                _isScanning
                    ? _scanningStatusText(l10n)
                    : l10n.imageMask_maskedCount(enabledCount),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: l10n.imageMask_undo,
            onPressed: _undoStack.isEmpty || _applying ? null : _undo,
            icon: const Icon(Symbols.undo_rounded),
          ),
          if (_regions.isNotEmpty)
            IconButton(
              tooltip: enabledCount > 0
                  ? l10n.imageMask_clearAll
                  : l10n.imageMask_selectAll,
              onPressed: _applying ? null : _toggleAllDetected,
              icon: Icon(
                enabledCount > 0
                    ? Symbols.deselect_rounded
                    : Symbols.select_all_rounded,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 4),
            child: FilledButton(
              onPressed: enabledCount == 0 || _applying || _initializing
                  ? null
                  : _applyMask,
              child: _applying
                  ? const LoadingSpinner(size: 16)
                  : Text(l10n.imageMask_apply),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_ocrModelMissing || _downloadingOcr) _buildOcrBanner(context),
          Expanded(
            child: Container(
              width: double.infinity,
              color: const Color(0xFF0E1014),
              child: _initializing || _decodedImage == null
                  ? const Center(child: LoadingSpinner(color: Colors.white))
                  : _buildInteractiveCanvas(context),
            ),
          ),
          _buildBottomDock(context),
        ],
      ),
    );
  }

  String _scanningStatusText(AppLocalizations l10n) {
    final ocr = _ocrProgress;
    if (_scanningOcr && ocr != null) {
      if (ocr.stage == OcrStage.detecting) {
        return l10n.imageViewer_detectingText;
      }
      if (ocr.stage == OcrStage.recognizing && ocr.total > 0) {
        return l10n.imageViewer_recognizingProgress(ocr.completed, ocr.total);
      }
      return l10n.imageMask_scanning;
    }
    if (_scanningQr && !_scanningOcr) {
      return l10n.imageMask_scanningQr;
    }
    return l10n.imageMask_scanning;
  }

  Widget _buildOcrBanner(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final totalMiB = (OcrModelStore.downloadBytes / 1048576).toStringAsFixed(1);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.65),
      child: _downloadingOcr
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const LoadingSpinner(size: 16),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _downloadProgress == null
                            ? l10n.imageViewer_downloadingOcr
                            : '${l10n.imageViewer_downloadingOcr} · ${(_downloadProgress! * 100).round()}%',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                M3eLinearProgress(value: _downloadProgress),
              ],
            )
          : Row(
              children: [
                Icon(
                  Symbols.info_rounded,
                  size: 18,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${l10n.imageMask_ocrNotDownloadedHint}（$totalMiB MiB）',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _downloadAndScanOcr,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: Text(l10n.imageMask_downloadOcrAction),
                ),
              ],
            ),
    );
  }

  Widget _buildInteractiveCanvas(BuildContext context) {
    final image = _decodedImage!;
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final accentColor = Theme.of(context).colorScheme.primary;

    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = applyBoxFit(
          BoxFit.contain,
          imageSize,
          constraints.biggest,
        );
        final displaySize = fitted.destination;
        final scale = displaySize.width / imageSize.width;

        Offset toImage(Offset local) => Offset(
          (local.dx / scale).clamp(0.0, imageSize.width),
          (local.dy / scale).clamp(0.0, imageSize.height),
        );

        Rect toDisplay(Rect r) => Rect.fromLTRB(
          r.left * scale,
          r.top * scale,
          r.right * scale,
          r.bottom * scale,
        );

        final canvas = Center(
          child: SizedBox(
            width: displaySize.width,
            height: displaySize.height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _applying
                  ? null
                  : (details) => _handleCanvasTap(toImage(details.localPosition)),
              onPanStart: _toolMode == _MaskToolMode.manual && !_applying
                  ? (details) =>
                        _handleManualPanStart(toImage(details.localPosition))
                  : null,
              onPanUpdate: _toolMode == _MaskToolMode.manual && !_applying
                  ? (details) => _handleManualPanUpdate(
                      toImage(details.localPosition),
                      imageSize,
                    )
                  : null,
              onPanEnd: _toolMode == _MaskToolMode.manual && !_applying
                  ? (_) => _handleManualPanEnd()
                  : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RawImage(
                    image: image,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                  ),
                  // 模糊样式使用真实 BackdropFilter 实时预览遮挡效果。
                  if (_maskStyle == PrivacyMaskStyle.blur)
                    for (final region in _regions)
                      if (region.enabled)
                        _buildBlurOverlay(context, toDisplay(region.bounds)),
                  CustomPaint(
                    painter: _PrivacyOverlayPainter(
                      regions: _regions,
                      ocrLines: _toolMode == _MaskToolMode.auto
                          ? (_ocrResult?.lines ?? const [])
                          : const [],
                      draftRect: _draftImageRect,
                      scale: scale,
                      style: _maskStyle,
                      accentColor: accentColor,
                      shapes: context.shapes,
                      mosaicImage: _mosaicPreviewImage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              transformationController: _transformController,
              minScale: 1.0,
              maxScale: 4.0,
              panEnabled: _toolMode == _MaskToolMode.auto,
              scaleEnabled: _toolMode == _MaskToolMode.auto,
              child: canvas,
            ),
            if (_isScanning)
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: ShapeDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      shape: RoundedSuperellipseBorder(
                        borderRadius: context.shapes.borderRadius(20),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const LoadingSpinner(size: 14, color: Colors.white),
                        const SizedBox(width: 8),
                        Text(
                          _scanningStatusText(context.l10n),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildBlurOverlay(BuildContext context, Rect rect) {
    final radius = math.min(6.0, math.min(rect.width, rect.height) * 0.18);
    return Positioned.fromRect(
      rect: rect,
      child: ClipRRect(
        borderRadius: context.shapes.borderRadius(radius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9),
          child: ColoredBox(color: Colors.black.withValues(alpha: 0.08)),
        ),
      ),
    );
  }

  Widget _buildBottomDock(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    // 统计已检测到的分类，供一键按类开关。
    final categoryCounts = <PrivacyCategory, ({int total, int enabled})>{};
    for (final r in _regions) {
      final prev = categoryCounts[r.category] ?? (total: 0, enabled: 0);
      categoryCounts[r.category] = (
        total: prev.total + 1,
        enabled: prev.enabled + (r.enabled ? 1 : 0),
      );
    }

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (categoryCounts.isNotEmpty) ...[
                SizedBox(
                  height: 36,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final entry in categoryCounts.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            selected: entry.value.enabled > 0,
                            visualDensity: VisualDensity.compact,
                            label: Text(
                              '${_categoryLabel(context, entry.key)} ${entry.value.enabled}/${entry.value.total}',
                            ),
                            onSelected: _applying
                                ? null
                                : (_) => _toggleCategory(entry.key),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  M3eButtonGroup<_MaskToolMode>(
                    selected: _toolMode,
                    itemPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    onSelected: (mode) {
                      setState(() => _toolMode = mode);
                    },
                    items: [
                      M3eButtonGroupItem(
                        value: _MaskToolMode.auto,
                        icon: const Icon(Symbols.touch_app_rounded, size: 16),
                        label: Text(l10n.imageMask_modeAuto),
                      ),
                      M3eButtonGroupItem(
                        value: _MaskToolMode.manual,
                        icon: const Icon(Symbols.crop_free_rounded, size: 16),
                        label: Text(l10n.imageMask_modeManual),
                      ),
                    ],
                  ),
                  M3eButtonGroup<PrivacyMaskStyle>(
                    selected: _maskStyle,
                    itemPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    onSelected: (style) {
                      setState(() => _maskStyle = style);
                    },
                    items: [
                      M3eButtonGroupItem(
                        value: PrivacyMaskStyle.mosaic,
                        label: Text(l10n.imageMask_styleMosaic),
                      ),
                      M3eButtonGroupItem(
                        value: PrivacyMaskStyle.blur,
                        label: Text(l10n.imageMask_styleBlur),
                      ),
                      M3eButtonGroupItem(
                        value: PrivacyMaskStyle.solid,
                        label: Text(l10n.imageMask_styleSolid),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _toolMode == _MaskToolMode.manual
                    ? l10n.imageMask_hintManual
                    : (_regions.isEmpty && !_isScanning
                          ? l10n.imageMask_noneFound
                          : l10n.imageMask_hintAuto),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrivacyOverlayPainter extends CustomPainter {
  const _PrivacyOverlayPainter({
    required this.regions,
    required this.ocrLines,
    required this.draftRect,
    required this.scale,
    required this.style,
    required this.accentColor,
    required this.shapes,
    required this.mosaicImage,
  });

  final List<PrivacyRegion> regions;
  final List<OcrTextLine> ocrLines;
  final Rect? draftRect;
  final double scale;
  final PrivacyMaskStyle style;
  final Color accentColor;
  final UiShapes shapes;
  final ui.Image? mosaicImage;

  Rect _scaled(Rect r) => Rect.fromLTRB(
    r.left * scale,
    r.top * scale,
    r.right * scale,
    r.bottom * scale,
  );

  @override
  void paint(Canvas canvas, Size size) {
    // 1. 淡描可点选的 OCR 文本行轮廓，方便用户一眼看出可直接点按补充打码。
    if (ocrLines.isNotEmpty) {
      final linePaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.16)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      final lineRadius = shapes.radius(3);
      for (final line in ocrLines) {
        final rect = _scaled(line.bounds);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, lineRadius), linePaint);
      }
    }

    // 2. 绘制隐私区域（已启用 = 实时样式预览 + 高亮边框；已取消 = 虚线/弱提示框）。
    for (final region in regions) {
      final rect = _scaled(region.bounds);
      final radius = shapes.radius(
        math.min(6.0, math.min(rect.width, rect.height) * 0.18),
      );
      final rrect = RRect.fromRectAndRadius(rect, radius);

      if (region.enabled) {
        switch (style) {
          case PrivacyMaskStyle.mosaic:
            _paintMosaicPreview(canvas, size, rect);
          case PrivacyMaskStyle.solid:
            canvas.drawRRect(
              rrect,
              Paint()..color = const Color(0xFF1E2026),
            );
          case PrivacyMaskStyle.blur:
            // 模糊内容由下方 BackdropFilter 渲染，这里只补边框。
            break;
        }
        final isMosaic = style == PrivacyMaskStyle.mosaic;
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = accentColor.withValues(alpha: isMosaic ? 0.45 : 0.9)
            ..style = PaintingStyle.stroke
            ..strokeWidth = isMosaic ? 1.0 : 1.6,
        );
      } else {
        canvas.drawRRect(
          rrect,
          Paint()..color = accentColor.withValues(alpha: 0.12),
        );
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = accentColor.withValues(alpha: 0.55)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2,
        );
      }
    }

    // 3. 手动框选中的临时选框。
    if (draftRect != null && !draftRect!.isEmpty) {
      final rect = _scaled(draftRect!);
      final rrect = RRect.fromRectAndRadius(rect, shapes.radius(4));
      canvas.drawRRect(
        rrect,
        Paint()..color = accentColor.withValues(alpha: 0.25),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = accentColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  void _paintMosaicPreview(
    Canvas canvas,
    Size canvasSize,
    Rect rect,
  ) {
    canvas.save();
    canvas.clipRect(rect);
    final mosaic = mosaicImage;
    if (mosaic != null) {
      // 将真实像素化纹理以最近邻采样对齐铺满画布并裁切到目标区域，与导出效果像素一致。
      canvas.drawImageRect(
        mosaic,
        Rect.fromLTWH(
          0,
          0,
          mosaic.width.toDouble(),
          mosaic.height.toDouble(),
        ),
        Offset.zero & canvasSize,
        Paint()..filterQuality = FilterQuality.none,
      );
    } else {
      final cell = math
          .max(5.0, math.min(rect.width, rect.height) * 0.25)
          .clamp(5.0, 12.0);
      final lightPaint = Paint()..color = const Color(0xD9D8DCE4);
      final midPaint = Paint()..color = const Color(0xD99BA2AE);
      var row = 0;
      for (var y = rect.top; y < rect.bottom; y += cell) {
        var col = 0;
        for (var x = rect.left; x < rect.right; x += cell) {
          canvas.drawRect(
            Rect.fromLTWH(
              x,
              y,
              math.min(cell, rect.right - x),
              math.min(cell, rect.bottom - y),
            ),
            (row + col).isEven ? lightPaint : midPaint,
          );
          col++;
        }
        row++;
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PrivacyOverlayPainter oldDelegate) => true;
}
