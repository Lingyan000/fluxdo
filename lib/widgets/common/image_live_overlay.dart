import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:dio/dio.dart';
import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/s.dart';
import '../../models/translation_engine.dart';
import '../../providers/ai_translation_provider.dart';
import '../../providers/image_ocr_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../services/app_logger.dart';
import '../../services/ocr/image_translation_service.dart';
import '../../services/ocr/local_ocr_service.dart';
import '../../services/ocr/ocr_model_store.dart';
import '../../services/ocr/picture_text_layout.dart';
import '../../services/toast_service.dart';
import '../../utils/image_save_utils.dart';
import '../ai/ai_translation_sheet.dart';
import 'app_bottom_sheet.dart';
import 'error_view.dart';
import 'image_text_sheet.dart';

/// 图片查看器原位叠加层工作模式。
enum ImageLiveOverlayMode { liveText, translate }

enum _DragTarget { startHandle, endHandle, directSlide }

/// 看图页原图叠加层：
/// - 实况选字模式：波纹点亮文字行、渐进流式可选、逐字无缝高亮、双水滴手柄 + 实时放大镜、
///   桌面端 I-beam 光标与鼠标划选、选区旁浮动胶囊（复制 / 翻译 / 全选 / 全文）；
/// - 覆盖翻译模式：在原图上按采样背景色/文字色矢量覆盖高清译文，支持原图对比、切换语言/引擎、保存译图。
class ImageLiveOverlay extends ConsumerStatefulWidget {
  const ImageLiveOverlay({
    super.key,
    required this.mode,
    required this.loadImage,
    required this.gestureController,
    required this.chromeVisible,
    required this.onClose,
    required this.onModeChanged,
    this.sourceKey = '',
    this.passive = false,
    this.keepDockVisibleWhenZoomed = false,
    this.onChromeHoverChanged,
    this.onRequestToggleChrome,
    this.initialTapGlobalPosition,
    this.onInitialTapMissed,
  });

  final ImageLiveOverlayMode mode;
  final Future<Uint8List> Function(CancelToken) loadImage;
  final ImageGestureController? gestureController;
  final ValueListenable<bool> chromeVisible;
  final VoidCallback onClose;
  final ValueChanged<ImageLiveOverlayMode> onModeChanged;

  /// 当前图片的唯一标识（URL 或 `'memory'`），切图变化时重置覆盖层状态。
  final String sourceKey;

  /// 静默直选模式（桌面端后台识别）：不展示底栏、错误条与识别高亮框，
  /// 仅在识别完成后提供悬停 I-beam 光标与直接拖选文字，点击/双击完全透传。
  final bool passive;

  /// 放大时是否仍保持底部模式胶囊可见（桌面端保持可见，移动端缩放时自动隐去）。
  final bool keepDockVisibleWhenZoomed;
  final ValueChanged<bool>? onChromeHoverChanged;
  final VoidCallback? onRequestToggleChrome;
  final Offset? initialTapGlobalPosition;

  /// 当传入 [initialTapGlobalPosition]（移动端长按直达）但落点附近未检测到文字时触发，
  /// 由宿主平滑回退到常规长按菜单。
  final VoidCallback? onInitialTapMissed;

  @override
  ConsumerState<ImageLiveOverlay> createState() => ImageLiveOverlayState();
}

class ImageLiveOverlayState extends ConsumerState<ImageLiveOverlay>
    with TickerProviderStateMixin {
  CancelToken _token = CancelToken();

  late final AnimationController _sweepController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  Uint8List? _imageBytes;
  ui.Image? _decodedImage;

  List<Rect> _detectedBoxes = const [];
  Offset? _sweepOrigin;
  OcrResult? _ocrResult;
  PictureTextLayout? _layout;

  /// 当前选中的字符闭区间 `[start, end]`。
  ({int start, int end})? _selection;
  _DragTarget? _activeDrag;
  PointerDeviceKind? _activeDragKind;
  Offset? _dragFinger;
  Offset? _dragFixedAnchor;
  int? _lastHapticGlyph;
  bool _hoveringText = false;
  Offset? _pendingSelectionGlobalPosition;
  Offset? _pendingSelectionImagePosition;
  Offset? _longPressDragGlobalPosition;
  bool _initialSelectionResolved = false;

  /// 覆盖翻译结果。
  List<TranslatedTextBlock> _translatedBlocks = const [];
  bool _showOriginalPeek = false;
  bool _savingTranslated = false;
  late TranslationEngine _engine;
  late String _targetCode;

  /// 状态字段。
  bool _needsDownload = false;
  bool _downloading = false;
  double? _downloadProgress;
  bool _reading = false;
  OcrProgress? _ocrProgress;
  bool _translating = false;
  Object? _errorObject;
  StackTrace? _errorStackTrace;
  String? _errorTitle;

  /// 供宿主快捷键调用：是否有正在选中的文字。
  bool get hasSelection => _selection != null;

  /// 长按可重复选择同一图片中的文字；尚未读到的行在后续识别结果中选中。
  bool selectTextAt(Offset globalPosition) {
    if (widget.mode != ImageLiveOverlayMode.liveText) return false;
    if (_selectLineAt(globalPosition)) return true;
    if (_reading) {
      _pendingSelectionGlobalPosition = globalPosition;
      _pendingSelectionImagePosition = _computePriorityPoint(globalPosition);
      return true;
    }
    return false;
  }

  /// 首次长按的指针仍由查看器持有，移动与抬手事件也由查看器转交。
  void updateLongPressSelection(Offset globalPosition) {
    if (widget.mode != ImageLiveOverlayMode.liveText) return;
    _longPressDragGlobalPosition = globalPosition;
    _extendLongPressSelection();
  }

  void endLongPressSelection() {
    if (_longPressDragGlobalPosition == null) return;
    _longPressDragGlobalPosition = null;
    _onPanEnd();
  }

  bool _selectLineAt(Offset globalPosition) {
    final point = _computePriorityPoint(globalPosition);
    return point != null && _selectLineAtImagePoint(point);
  }

  bool _selectLineAtImagePoint(Offset point) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || _layout == null) return false;
    final display = _displayRect(box.size);
    if (display.isEmpty) return false;
    final hit = _layout!.glyphAt(
      point.dx,
      point.dy,
      reach: 10 * _imageSize.width / display.width,
    );
    if (hit == null) return false;
    setState(() {
      _selection = _layout!.lineRangeOf(hit);
      _pendingSelectionGlobalPosition = null;
      _pendingSelectionImagePosition = null;
      _initialSelectionResolved = true;
    });
    return true;
  }

  void _extendLongPressSelection() {
    final position = _longPressDragGlobalPosition;
    final selection = _selection;
    final layout = _layout;
    final box = context.findRenderObject();
    if (position == null ||
        selection == null ||
        layout == null ||
        _pendingSelectionGlobalPosition != null ||
        box is! RenderBox ||
        !box.hasSize) {
      return;
    }
    if (_activeDrag == null) {
      final anchor = layout.glyphs[selection.start];
      _activeDrag = _DragTarget.directSlide;
      _activeDragKind = PointerDeviceKind.touch;
      _dragFixedAnchor = Offset(anchor.centerX, anchor.centerY);
    }
    _onPanUpdate(
      DragUpdateDetails(
        globalPosition: position,
        localPosition: box.globalToLocal(position),
      ),
      box.size,
    );
  }

  /// 供宿主快捷键（Esc）调用：若存在选区先清选区，否则返回 false 由宿主关闭覆盖层。
  bool clearSelectionIfAny() {
    if (_selection == null) return false;
    setState(() => _selection = null);
    return true;
  }

  /// 供宿主快捷键（Cmd/Ctrl+C）调用：复制当前选中文字，成功返回 true。
  Future<bool> copySelectionIfAny() async {
    if (_selection == null || _selectedText.isEmpty) return false;
    await _copySelection();
    return true;
  }

  /// 供宿主快捷键（Space）调用：翻译模式下切换原图/译图对比。
  void toggleOriginalPeek() {
    if (widget.mode != ImageLiveOverlayMode.translate ||
        _translatedBlocks.isEmpty) {
      return;
    }
    setState(() => _showOriginalPeek = !_showOriginalPeek);
  }

  @override
  void initState() {
    super.initState();
    _pendingSelectionGlobalPosition = widget.initialTapGlobalPosition;
    _engine = ref.read(preferencesProvider).translationEngine;
    _targetCode = ref.read(aiTranslationTargetLanguageProvider);
    widget.gestureController?.addListener(_onGestureChanged);
    _startFlow();
  }

  @override
  void didUpdateWidget(covariant ImageLiveOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.gestureController, widget.gestureController)) {
      oldWidget.gestureController?.removeListener(_onGestureChanged);
      widget.gestureController?.addListener(_onGestureChanged);
    }
    if (oldWidget.sourceKey != widget.sourceKey) {
      _resetForNewImage();
      _startFlow();
      return;
    }
    if (oldWidget.passive != widget.passive) {
      if (oldWidget.passive && !widget.passive) {
        if (widget.mode == ImageLiveOverlayMode.translate) {
          _selection = null;
          _hoveringText = false;
          if (_translatedBlocks.isEmpty && !_translating) {
            _startFlow();
          }
        } else {
          _showOriginalPeek = false;
          if (_ocrResult != null) {
            if (_ocrResult!.isEmpty) {
              ToastService.showInfo(S.current.imageViewer_noText);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) widget.onClose();
              });
            } else {
              _sweepOrigin =
                  _computePriorityPoint() ?? Offset(_imageSize.width / 2, 0);
              _sweepController.forward(from: 0);
            }
          } else if (!_reading) {
            _startFlow();
          }
        }
      } else {
        _selection = null;
        _showOriginalPeek = false;
      }
      _syncPulse();
    }
    if (oldWidget.mode != widget.mode) {
      if (widget.mode == ImageLiveOverlayMode.translate) {
        _selection = null;
        _hoveringText = false;
        if (_translatedBlocks.isEmpty && !_translating && !_needsDownload) {
          _startFlow();
        }
      } else {
        _showOriginalPeek = false;
      }
      _syncPulse();
    }
  }

  void _resetForNewImage() {
    _token.cancel();
    _sweepController.stop();
    _pulseController.stop();
    _imageBytes = null;
    _decodedImage?.dispose();
    _decodedImage = null;
    _detectedBoxes = const [];
    _sweepOrigin = null;
    _ocrResult = null;
    _layout = null;
    _selection = null;
    _activeDrag = null;
    _activeDragKind = null;
    _dragFinger = null;
    _dragFixedAnchor = null;
    _lastHapticGlyph = null;
    _hoveringText = false;
    _pendingSelectionGlobalPosition = widget.initialTapGlobalPosition;
    _pendingSelectionImagePosition = null;
    _longPressDragGlobalPosition = null;
    _initialSelectionResolved = false;
    _translatedBlocks = const [];
    _showOriginalPeek = false;
    _needsDownload = false;
    _downloading = false;
    _downloadProgress = null;
    _reading = false;
    _ocrProgress = null;
    _translating = false;
    _errorObject = null;
    _errorStackTrace = null;
    _errorTitle = null;
  }

  void _syncPulse() {
    final shouldPulse = !widget.passive && (_reading || _translating);
    if (shouldPulse) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else if (_pulseController.isAnimating) {
      _pulseController.stop();
    }
  }

  @override
  void dispose() {
    widget.gestureController?.removeListener(_onGestureChanged);
    _token.cancel();
    _sweepController.dispose();
    _pulseController.dispose();
    _decodedImage?.dispose();
    super.dispose();
  }

  void _onGestureChanged() {
    if (mounted) setState(() {});
  }

  Rect _displayRect(Size viewport) {
    final details = widget.gestureController?.details;
    final img = _decodedImage;
    Rect? fallbackRaw;
    if (img != null && !viewport.isEmpty) {
      final fitted = applyBoxFit(
        BoxFit.contain,
        Size(img.width.toDouble(), img.height.toDouble()),
        viewport,
      );
      final size = fitted.destination;
      fallbackRaw = Rect.fromCenter(
        center: viewport.center(Offset.zero),
        width: size.width,
        height: size.height,
      );
    }

    if (details != null) {
      final layoutRect =
          details.layoutRect ??
          (!viewport.isEmpty ? Offset.zero & viewport : null);
      final rawDest = details.rawDestinationRect ?? fallbackRaw;
      if (layoutRect != null &&
          rawDest != null &&
          !layoutRect.isEmpty &&
          !rawDest.isEmpty) {
        // 用无副作用副本按 RawGestureImage 同一算式即时算出当前帧真实位置，
        // 彻底避免 details.destinationRect 滞后一帧导致的缩放偏移。
        final probe = GestureDetails(
          offset: details.offset,
          totalScale: details.totalScale,
          gestureDetails: details,
          actionType: details.actionType,
          userOffset: details.userOffset,
        );
        var rect = probe.calculateFinalDestinationRect(layoutRect, rawDest);
        final slideOffset = details.slidePageOffset;
        if (slideOffset != null) {
          rect = rect.shift(slideOffset);
        }
        // RawGestureImage 的 layoutRect 位于其所在 RepaintBoundary 坐标系，
        // 桌面端顶栏位于画布上方时 layoutRect.topLeft 可能非零，平移回局部坐标对齐。
        rect = rect.shift(-layoutRect.topLeft);
        if (!rect.isEmpty && rect.isFinite) return rect;
      }
      final dest = details.destinationRect;
      if (dest != null && !dest.isEmpty && dest.isFinite) {
        final layout = details.layoutRect;
        return (layout != null && !layout.isEmpty)
            ? dest.shift(-layout.topLeft)
            : dest;
      }
    }

    return fallbackRaw ?? Rect.zero;
  }

  Size get _imageSize {
    final img = _decodedImage;
    if (img != null) return Size(img.width.toDouble(), img.height.toDouble());
    final ocr = _ocrResult;
    if (ocr != null && ocr.imageWidth > 0 && ocr.imageHeight > 0) {
      return Size(ocr.imageWidth.toDouble(), ocr.imageHeight.toDouble());
    }
    return Size.zero;
  }

  Future<void> _startFlow({bool download = false}) async {
    _token.cancel();
    final token = _token = CancelToken();
    setState(() {
      _errorObject = null;
      _errorStackTrace = null;
      _errorTitle = null;
      _needsDownload = false;
      if (download) {
        _downloading = true;
        _downloadProgress = null;
      }
    });

    var failedWhileDownloading = download;
    try {
      final store = ref.read(ocrModelStoreProvider);
      if (!await store.isReady()) {
        if (!mounted || token.isCancelled) return;
        if (widget.passive) return;
        if (!download) {
          setState(() {
            _needsDownload = true;
            _downloading = false;
          });
          return;
        }
        failedWhileDownloading = true;
        setState(() {
          _downloading = true;
          _downloadProgress = null;
        });
        await store.download(
          cancelToken: token,
          onProgress: (p) {
            if (mounted && !token.isCancelled) {
              setState(() => _downloadProgress = p);
            }
          },
        );
      }
      if (!mounted || token.isCancelled) return;
      failedWhileDownloading = false;
      setState(() {
        _downloading = false;
        _downloadProgress = null;
        _needsDownload = false;
      });

      var bytes = _imageBytes;
      if (bytes == null) {
        setState(() => _reading = true);
        _syncPulse();
        bytes = await widget.loadImage(token);
        if (!mounted || token.isCancelled) return;
        final decoded = await decodeImageFromList(bytes);
        if (!mounted || token.isCancelled) {
          decoded.dispose();
          return;
        }
        _imageBytes = bytes;
        _decodedImage?.dispose();
        _decodedImage = decoded;
      }

      var ocr = _ocrResult;
      if (ocr == null) {
        setState(() {
          _reading = true;
          _ocrProgress = null;
        });
        _syncPulse();
        final priority =
            _pendingSelectionImagePosition ??
            _computePriorityPoint(_pendingSelectionGlobalPosition);
        if (_pendingSelectionGlobalPosition != null) {
          // 排队期间缩放或平移图片，也要保留长按时指向的原图位置。
          _pendingSelectionImagePosition = priority;
        }
        final hasMissFallback =
            !widget.passive &&
            priority != null &&
            widget.onInitialTapMissed != null;
        var missedLongPress = false;
        final service = ref.read(localOcrServiceProvider);
        final decodedImg = _decodedImage;
        ocr = await service.recognizeDetailed(
          bytes,
          await store.paths(),
          cancelToken: token,
          loadRgba: decodedImg == null
              ? null
              : () async {
                  final bd = await decodedImg.toByteData(
                    format: ui.ImageByteFormat.rawRgba,
                  );
                  if (bd == null) return null;
                  return OcrRgbaImage(
                    width: decodedImg.width,
                    height: decodedImg.height,
                    rgba: bd.buffer.asUint8List(
                      bd.offsetInBytes,
                      bd.lengthInBytes,
                    ),
                  );
                },
          priorityPoint: priority,
          onProgress: (progress) {
            if (mounted && !token.isCancelled && !widget.passive) {
              setState(() => _ocrProgress = progress);
            }
          },
          onDetected: (w, h, boxes) {
            if (!mounted || token.isCancelled) return;
            if (hasMissFallback) {
              final reach = w * 0.05;
              final nearAny = boxes.any(
                (b) => b.inflate(reach).contains(priority),
              );
              if (!nearAny) {
                missedLongPress = true;
                token.cancel('long-press-missed');
                final onMissed = widget.onInitialTapMissed;
                widget.onClose();
                onMissed?.call();
                return;
              }
            }
            setState(() {
              _detectedBoxes = boxes;
              _sweepOrigin = priority ?? Offset(w / 2, 0);
            });
            if (!widget.passive) {
              _sweepController.forward(from: 0);
            }
          },
          onPartial: (partial) {
            if (!mounted || token.isCancelled) return;
            _updateLayoutKeepingSelection(partial);
          },
        );
        if (!mounted || token.isCancelled || missedLongPress) return;
        _ocrResult = ocr;
        _updateLayoutKeepingSelection(ocr);
        setState(() {
          _reading = false;
          _ocrProgress = null;
        });
        _syncPulse();

        if (hasMissFallback && (ocr.isEmpty || !_initialSelectionResolved)) {
          final onMissed = widget.onInitialTapMissed;
          widget.onClose();
          onMissed?.call();
          return;
        }
      }

      if (ocr.isEmpty) {
        if (mounted && !widget.passive) {
          ToastService.showInfo(S.current.imageViewer_noText);
          widget.onClose();
        }
        return;
      }

      if (!widget.passive && widget.mode == ImageLiveOverlayMode.translate) {
        await _runImageTranslation(bytes, ocr, token);
      }
    } catch (error, stackTrace) {
      if (!mounted || token.isCancelled) return;
      if (widget.passive) {
        AppLogger.warning('后台静默识字失败: $error', tag: 'OCR');
        setState(() {
          _reading = false;
          _ocrProgress = null;
        });
        _syncPulse();
        return;
      }
      AppLogger.error(
        failedWhileDownloading
            ? 'OCR 模型下载失败'
            : (widget.mode == ImageLiveOverlayMode.translate
                  ? '图片覆盖翻译失败'
                  : '原图实况识字失败'),
        tag: 'OCR',
        error: error,
        stackTrace: stackTrace,
      );
      if (!failedWhileDownloading && _ocrResult == null) {
        ref.read(ocrModelStoreProvider).invalidateVerificationCache();
      }
      setState(() {
        _downloading = false;
        _downloadProgress = null;
        _reading = false;
        _translating = false;
        _needsDownload = failedWhileDownloading;
        _errorObject = error;
        _errorStackTrace = stackTrace;
        _errorTitle = failedWhileDownloading
            ? S.current.imageViewer_ocrDownloadFailed
            : (widget.mode == ImageLiveOverlayMode.translate
                  ? S.current.imageViewer_translateImageFailed
                  : S.current.imageViewer_ocrFailed);
      });
      _syncPulse();
    }
  }

  Future<void> _runImageTranslation(
    Uint8List bytes,
    OcrResult ocr,
    CancelToken token,
  ) async {
    setState(() {
      _translating = true;
      _errorObject = null;
      _errorStackTrace = null;
      _errorTitle = null;
    });
    _syncPulse();

    ({AiProvider provider, AiModel model})? aiModel;
    String? apiKey;
    if (_engine == TranslationEngine.ai) {
      aiModel = ref.read(aiTranslationSelectedModelProvider);
      if (aiModel == null) {
        throw S.current.ai_translationNoModel;
      }
      apiKey = await AiProviderListNotifier.getApiKey(aiModel.provider.id);
      if (!mounted || token.isCancelled) return;
      if (apiKey == null || apiKey.trim().isEmpty) {
        throw S.current.ai_translationNoApiKey;
      }
    }

    final blocks = await ImageTranslationService.translateImage(
      imageBytes: bytes,
      ocr: ocr,
      engine: _engine,
      targetCode: _targetCode,
      targetName: aiTranslationLanguageLabel(_targetCode),
      translationService: ref.read(translationServiceProvider),
      aiTranslationService: ref.read(aiTranslationServiceProvider),
      aiModel: aiModel,
      apiKey: apiKey,
      cancelToken: token,
    );
    if (!mounted || token.isCancelled) return;
    setState(() {
      _translatedBlocks = blocks;
      _translating = false;
      _showOriginalPeek = false;
    });
    _syncPulse();
    if (blocks.isEmpty) {
      ToastService.showInfo(S.current.imageViewer_translateNoTranslatableText);
    }
  }

  Offset? _computePriorityPoint([Offset? globalPosition]) {
    final tap = globalPosition ?? widget.initialTapGlobalPosition;
    final img = _decodedImage;
    if (tap == null || img == null) return null;
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return null;
    final local = ro.globalToLocal(tap);
    final display = _displayRect(ro.size);
    if (display.isEmpty || !display.contains(local)) return null;
    final scale = display.width / img.width;
    return Offset(
      (local.dx - display.left) / scale,
      (local.dy - display.top) / scale,
    );
  }

  void _updateLayoutKeepingSelection(OcrResult ocr) {
    final prevLayout = _layout;
    final prevSelection = _selection;
    Offset? anchorStart;
    Offset? anchorEnd;
    if (prevLayout != null && prevSelection != null && !prevLayout.isEmpty) {
      final a = prevLayout.glyphs[prevSelection.start];
      final b = prevLayout.glyphs[prevSelection.end];
      anchorStart = Offset(a.centerX, a.centerY);
      anchorEnd = Offset(b.centerX, b.centerY);
    }

    final next = PictureTextLayout.fromOcr(ocr);
    ({int start, int end})? nextSelection;
    if (anchorStart != null && anchorEnd != null && !next.isEmpty) {
      final a = next.nearestGlyph(anchorStart.dx, anchorStart.dy);
      final b = next.nearestGlyph(anchorEnd.dx, anchorEnd.dy);
      if (a != null && b != null) {
        nextSelection = (start: math.min(a, b), end: math.max(a, b));
      }
    }

    setState(() {
      _layout = next;
      if (nextSelection != null) _selection = nextSelection;
    });
    final pending = _pendingSelectionImagePosition;
    if (pending != null && widget.mode == ImageLiveOverlayMode.liveText) {
      _selectLineAtImagePoint(pending);
    }
    _extendLongPressSelection();
  }

  String get _selectedText {
    final layout = _layout;
    final sel = _selection;
    if (layout == null || sel == null || layout.isEmpty) return '';
    return layout.extractText(sel.start, sel.end);
  }

  void _selectAll() {
    final layout = _layout;
    if (layout == null || layout.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _selection = (start: 0, end: layout.glyphs.length - 1);
    });
  }

  Future<void> _copySelection() async {
    final text = _selectedText;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ToastService.showSuccess(S.current.common_copiedToClipboard);
      setState(() => _selection = null);
    }
  }

  void _translateSelection() {
    final text = _selectedText;
    if (text.isEmpty) return;
    showTextTranslationSheet(context, text: text);
  }

  void _openFullTextSheet() {
    final bytes = _imageBytes;
    if (bytes == null) return;
    showImageTextSheet(context, loadImage: (_) async => bytes);
  }

  Future<void> _saveTranslatedImage() async {
    final image = _decodedImage;
    if (image == null || _translatedBlocks.isEmpty || _savingTranslated) return;
    setState(() => _savingTranslated = true);
    try {
      final png = await ImageTranslationService.renderTranslatedPng(
        image,
        _translatedBlocks,
      );
      await ImageSaveUtils.saveBytes(
        png,
        fileName: 'translated_${DateTime.now().millisecondsSinceEpoch}.png',
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        '保存翻译图片失败',
        tag: 'OCR',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) ToastService.showError(S.current.imageViewer_saveFailedRetry);
    } finally {
      if (mounted) setState(() => _savingTranslated = false);
    }
  }

  void _showTranslateSettingsSheet() {
    AppBottomSheet.show<void>(
      context: context,
      title: context.l10n.imageViewer_translateImage,
      builder: (ctx) {
        var engine = _engine;
        var target = _targetCode;
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  ctx.l10n.ai_translationEngine,
                  style: Theme.of(ctx).textTheme.labelMedium,
                ),
                const SizedBox(height: 8),
                M3eButtonGroup<TranslationEngine>(
                  selected: engine,
                  onSelected: (value) => setSheetState(() => engine = value),
                  items: [
                    for (final item in TranslationEngine.values)
                      M3eButtonGroupItem(
                        value: item,
                        label: Text(translationEngineLabel(item)),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  ctx.l10n.ai_translationTargetLanguage,
                  style: Theme.of(ctx).textTheme.labelMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in aiTranslationLanguages.entries)
                      ChoiceChip(
                        selected: target == entry.key,
                        label: Text(entry.value),
                        onSelected: (_) =>
                            setSheetState(() => target = entry.key),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    if (engine != _engine || target != _targetCode) {
                      setState(() {
                        _engine = engine;
                        _targetCode = target;
                        _translatedBlocks = const [];
                      });
                      ref
                          .read(preferencesProvider.notifier)
                          .setTranslationEngine(engine);
                      final bytes = _imageBytes;
                      final ocr = _ocrResult;
                      if (bytes != null && ocr != null) {
                        _token.cancel();
                        final token = _token = CancelToken();
                        _runImageTranslation(bytes, ocr, token);
                      } else {
                        _startFlow();
                      }
                    }
                  },
                  child: Text(ctx.l10n.common_confirm),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showErrorDetails() {
    AppBottomSheet.show<void>(
      context: context,
      title: _errorTitle ?? context.l10n.imageViewer_ocrFailed,
      builder: (ctx) => ErrorView(
        error: _errorObject ?? (_errorTitle ?? context.l10n.imageViewer_ocrFailed),
        stackTrace: _errorStackTrace,
        title: _errorTitle,
        onRetry: () {
          Navigator.pop(ctx);
          _startFlow(download: _needsDownload);
        },
      ),
    );
  }

  // ── 桌面悬停 I-beam 光标 & 竞技场安全的手柄/划选手势 ──

  /// 统一文本命中判定：按屏幕逻辑像素容差（鼠标 2px 精准贴合，触摸 10px 舒适容差），
  /// 确保桌面端悬停显示 I-beam 光标的区域与左键拖选区域 100% 一致，绝不在空白处误抢翻页/平移。
  int? _hitTextGlyph(Offset pos, PointerDeviceKind? kind, Size viewport) {
    final layout = _layout;
    final imageSize = _imageSize;
    if (layout == null || layout.isEmpty || imageSize.isEmpty) return null;
    final display = _displayRect(viewport);
    if (display.isEmpty || !display.contains(pos)) return null;
    final scale = display.width / imageSize.width;
    if (scale <= 0) return null;
    final imgX = (pos.dx - display.left) / scale;
    final imgY = (pos.dy - display.top) / scale;
    final screenPadding = kind == PointerDeviceKind.mouse ? 2.0 : 10.0;
    return layout.glyphAt(imgX, imgY, reach: screenPadding / scale);
  }

  void _onHover(PointerHoverEvent event, Size viewport) {
    if (widget.mode != ImageLiveOverlayMode.liveText) return;
    final hit =
        _hitTextGlyph(event.localPosition, event.kind, viewport) != null;
    if (hit != _hoveringText) {
      setState(() => _hoveringText = hit);
    }
  }

  ({
    _DragTarget target,
    Offset fixedAnchor,
    ({int start, int end})? initialSelection,
  })?
  _hitDragTarget(Offset pos, PointerDeviceKind? kind, Size viewport) {
    final layout = _layout;
    final imageSize = _imageSize;
    if (layout == null || layout.isEmpty || imageSize.isEmpty) return null;
    final display = _displayRect(viewport);
    if (display.isEmpty) return null;
    final scale = display.width / imageSize.width;

    // 1. 优先命中首尾水滴手柄
    final sel = _selection;
    if (sel != null) {
      final grab = kind == PointerDeviceKind.mouse ? 14.0 : 28.0;
      final first = layout.glyphs[sel.start].bounds;
      final last = layout.glyphs[sel.end].bounds;
      double distToBar(double imgX, double imgTop, double imgBottom) {
        final sx = display.left + imgX * scale;
        final sTop = display.top + imgTop * scale;
        final sBottom = display.top + imgBottom * scale;
        final clampedY = pos.dy.clamp(sTop - grab, sBottom + grab);
        return (pos - Offset(sx, clampedY)).distance;
      }

      final toEnd = distToBar(last.right, last.top, last.bottom);
      final toStart = distToBar(first.left, first.top, first.bottom);
      if (toEnd <= grab && toEnd <= toStart) {
        return (
          target: _DragTarget.endHandle,
          fixedAnchor: Offset(first.center.dx, first.center.dy),
          initialSelection: null,
        );
      }
      if (toStart <= grab) {
        return (
          target: _DragTarget.startHandle,
          fixedAnchor: Offset(last.center.dx, last.center.dy),
          initialSelection: null,
        );
      }
    }

    // 2. 鼠标直接拖选；触摸只有拖动手柄或长按后才选字，普通滑动留给画廊。
    if (kind != PointerDeviceKind.mouse) return null;
    final hit = _hitTextGlyph(pos, kind, viewport);
    if (hit != null) {
      final g = layout.glyphs[hit];
      return (
        target: _DragTarget.directSlide,
        fixedAnchor: Offset(g.centerX, g.centerY),
        initialSelection: (start: hit, end: hit),
      );
    }
    return null;
  }

  void _onPanStart(Offset downPosition, PointerDeviceKind kind, Size viewport) {
    final hit = _hitDragTarget(downPosition, kind, viewport);
    if (hit == null) return;
    if (kind != PointerDeviceKind.mouse) {
      HapticFeedback.selectionClick();
    }
    setState(() {
      _activeDrag = hit.target;
      _activeDragKind = kind;
      _dragFinger = downPosition;
      _dragFixedAnchor = hit.fixedAnchor;
      _lastHapticGlyph = null;
      if (hit.initialSelection != null) {
        _selection = hit.initialSelection;
      }
    });
  }

  void _onPanUpdate(DragUpdateDetails details, Size viewport) {
    if (_activeDrag == null) return;
    final layout = _layout;
    final imageSize = _imageSize;
    final fixedAnchor = _dragFixedAnchor;
    if (layout == null ||
        layout.isEmpty ||
        imageSize.isEmpty ||
        fixedAnchor == null) {
      return;
    }

    final display = _displayRect(viewport);
    if (display.isEmpty) return;
    final scale = display.width / imageSize.width;
    final pos = details.localPosition;
    final isMouse = _activeDragKind == PointerDeviceKind.mouse;
    // 触摸拖动稍微向上偏移避开手指遮挡；鼠标直接精准对准指针位置。
    final aimOffset = isMouse ? 0.0 : 12.0;
    final imgX = (pos.dx - display.left) / scale;
    final imgY = (pos.dy - aimOffset - display.top) / scale;

    final glyph = layout.nearestGlyph(imgX, imgY);
    final fixed = layout.nearestGlyph(fixedAnchor.dx, fixedAnchor.dy);
    if (glyph == null || fixed == null) return;

    if (glyph != _lastHapticGlyph) {
      if (_lastHapticGlyph != null && !isMouse) {
        HapticFeedback.selectionClick();
      }
      _lastHapticGlyph = glyph;
    }
    setState(() {
      _dragFinger = pos;
      _selection = (start: math.min(fixed, glyph), end: math.max(fixed, glyph));
    });
  }

  void _onPanEnd() {
    if (_activeDrag == null) return;
    setState(() {
      _activeDrag = null;
      _activeDragKind = null;
      _dragFinger = null;
      _dragFixedAnchor = null;
      _lastHapticGlyph = null;
    });
  }

  void _onCanvasTapUp(TapUpDetails details, Size viewport) {
    if (widget.mode != ImageLiveOverlayMode.liveText) return;
    final layout = _layout;
    final imageSize = _imageSize;
    if (layout == null || layout.isEmpty || imageSize.isEmpty) return;

    final display = _displayRect(viewport);
    if (display.isEmpty) return;
    final scale = display.width / imageSize.width;
    final local = details.localPosition;
    final imgX = (local.dx - display.left) / scale;
    final imgY = (local.dy - display.top) / scale;

    final hit = layout.glyphAt(imgX, imgY, reach: imageSize.width * 0.025);
    if (hit != null) {
      HapticFeedback.selectionClick();
      setState(() => _selection = layout.lineRangeOf(hit));
    } else if (_selection != null) {
      setState(() => _selection = null);
    } else {
      widget.onRequestToggleChrome?.call();
    }
  }

  bool get _hasBlockingStatus =>
      _downloading ||
      _needsDownload ||
      _errorTitle != null ||
      _reading ||
      _translating;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        final display = _displayRect(viewport);
        final imageSize = _imageSize;
        final isZoomed = (widget.gestureController?.details?.totalScale ?? 1.0) > 1.02;

        return Stack(
          fit: StackFit.expand,
          children: [
            // 1. 覆盖绘制层（翻译矢量文字 / 实况选字波纹、选区、手柄与放大镜）。
            IgnorePointer(
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _sweepController,
                  _pulseController,
                  ?widget.gestureController,
                ]),
                builder: (context, _) {
                  final liveDisplay = _displayRect(viewport);
                  return CustomPaint(
                    painter: widget.mode == ImageLiveOverlayMode.translate
                        ? _TranslatedOverlayPainter(
                            displayRect: liveDisplay,
                            imageSize: imageSize,
                            blocks: _showOriginalPeek
                                ? const []
                                : _translatedBlocks,
                            detectedBoxes: _translating || _reading
                                ? _detectedBoxes
                                : const [],
                            pulse: _pulseController.value,
                            sweep: _sweepController.value,
                            sweepOrigin: _sweepOrigin ?? Offset.zero,
                          )
                        : _LiveTextOverlayPainter(
                            displayRect: liveDisplay,
                            imageSize: imageSize,
                            decodedImage: _decodedImage,
                            detectedBoxes: _detectedBoxes,
                            showDetectedHighlights: !widget.passive,
                            layout: _layout,
                            selection: _selection,
                            reading: _reading,
                            pulse: _pulseController.value,
                            sweep: _sweepController.value,
                            sweepOrigin: _sweepOrigin ?? Offset.zero,
                            dragFinger:
                                _activeDrag != null &&
                                    _activeDragKind != PointerDeviceKind.mouse
                                ? _dragFinger
                                : null,
                            accentColor: Theme.of(context).colorScheme.primary,
                            shapes: context.shapes,
                          ),
                  );
                },
              ),
            ),

            // 2. 鼠标命中文字可拖选；触摸只认领手柄，普通滑动放行给画廊。
            if (widget.mode == ImageLiveOverlayMode.liveText &&
                _layout != null &&
                !_layout!.isEmpty)
              MouseRegion(
                opaque: false,
                cursor: _hoveringText
                    ? SystemMouseCursors.text
                    : MouseCursor.defer,
                onHover: (e) => _onHover(e, viewport),
                onExit: (_) {
                  if (_hoveringText) setState(() => _hoveringText = false);
                },
                child: RawGestureDetector(
                  behavior: HitTestBehavior.translucent,
                  gestures: <Type, GestureRecognizerFactory>{
                    if (!widget.passive || _selection != null)
                      TapGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                            TapGestureRecognizer
                          >(
                            () => TapGestureRecognizer(),
                            (instance) {
                              instance.onTapUp = (d) =>
                                  _onCanvasTapUp(d, viewport);
                            },
                          ),
                    _ConditionalPanGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          _ConditionalPanGestureRecognizer
                        >(
                          () => _ConditionalPanGestureRecognizer(),
                          (instance) {
                            instance.shouldClaim = (pos, kind) =>
                                _hitDragTarget(pos, kind, viewport) != null;
                            instance.onClaimedStart = (downPos, kind) =>
                                _onPanStart(downPos, kind, viewport);
                            instance.onUpdate = (d) =>
                                _onPanUpdate(d, viewport);
                            instance.onEnd = (_) => _onPanEnd();
                            instance.onCancel = _onPanEnd;
                          },
                        ),
                  },
                ),
              ),

            // 3. 选区旁浮动操作胶囊（复制 / 翻译 / 全选 / 全文）
            if (widget.mode == ImageLiveOverlayMode.liveText &&
                _selection != null &&
                _activeDrag == null &&
                _layout != null &&
                !imageSize.isEmpty)
              _buildSelectionToolbar(context, viewport, display, imageSize),

            // 4. 底部统一紧凑毛玻璃控制坞（静默直选模式下不显示，保留宿主正常底栏）。
            if (!widget.passive)
              ValueListenableBuilder<bool>(
              valueListenable: widget.chromeVisible,
              builder: (context, chromeShown, _) {
                final visible =
                    _hasBlockingStatus ||
                    (chromeShown &&
                        _activeDrag == null &&
                        (widget.keepDockVisibleWhenZoomed || !isZoomed));
                return Positioned(
                  left: 16,
                  right: 16,
                  bottom: MediaQuery.paddingOf(context).bottom + 16,
                  child: IgnorePointer(
                    ignoring: !visible,
                    child: AnimatedOpacity(
                      opacity: visible ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Center(
                        child: MouseRegion(
                          onEnter: (_) =>
                              widget.onChromeHoverChanged?.call(true),
                          onExit: (_) =>
                              widget.onChromeHoverChanged?.call(false),
                          child: _buildBottomGlassDock(context),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildSelectionToolbar(
    BuildContext context,
    Size viewport,
    Rect display,
    Size imageSize,
  ) {
    final l10n = context.l10n;
    final imgBounds = _layout!.selectionBounds(
      _selection!.start,
      _selection!.end,
    );
    if (imgBounds == null || display.isEmpty) return const SizedBox.shrink();

    final scale = display.width / imageSize.width;
    final selRect = Rect.fromLTRB(
      display.left + imgBounds.left * scale,
      display.top + imgBounds.top * scale,
      display.left + imgBounds.right * scale,
      display.top + imgBounds.bottom * scale,
    );

    const toolbarHeight = 42.0;
    const estWidth = 256.0;
    const gap = 14.0;
    const margin = 16.0;
    final padding = MediaQuery.paddingOf(context);
    final highest = padding.top + 56;
    final lowest = math.max(
      highest,
      viewport.height - padding.bottom - 80 - toolbarHeight,
    );
    final above = selRect.top - gap - toolbarHeight;
    final below = selRect.bottom + gap * 1.6;
    final y = (above >= highest
            ? above
            : (below <= lowest
                  ? below
                  : (selRect.top + gap).clamp(highest, lowest)))
        .toDouble();
    final x = (selRect.center.dx - estWidth / 2)
        .clamp(margin, math.max(margin, viewport.width - estWidth - margin))
        .toDouble();

    return Positioned(
      left: x,
      top: y,
      child: MouseRegion(
        onEnter: (_) => widget.onChromeHoverChanged?.call(true),
        onExit: (_) => widget.onChromeHoverChanged?.call(false),
        child: _FrostedMediaPill(
          radius: 22,
          opacity: 0.92,
          child: SizedBox(
            height: toolbarHeight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DockTextAction(
                  icon: Symbols.content_copy_rounded,
                  label: l10n.common_copy,
                  onTap: _copySelection,
                ),
                _DockTextAction(
                  icon: Symbols.translate_rounded,
                  label: l10n.ai_translationMenuLabel,
                  onTap: _translateSelection,
                ),
                _DockTextAction(
                  label: l10n.imageViewer_selectAll,
                  onTap: _selectAll,
                ),
                _DockTextAction(
                  label: l10n.imageViewer_fullText,
                  onTap: _openFullTextSheet,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomGlassDock(BuildContext context) {
    final l10n = context.l10n;
    final totalMiB = (OcrModelStore.downloadBytes / 1048576).toStringAsFixed(1);

    if (_downloading) {
      final p = _downloadProgress;
      return _FrostedMediaPill(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (p == null)
                const LoadingSpinner(size: 16, color: Colors.white)
              else
                M3eCircularProgress(
                  value: p,
                  size: 18,
                  strokeWidth: 2.5,
                  color: Colors.white,
                  trackColor: Colors.white24,
                ),
              const SizedBox(width: 10),
              Text(
                p == null
                    ? l10n.imageViewer_downloadingOcr
                    : '${l10n.imageViewer_downloadingOcr} ${(p * 100).round()}%',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(width: 6),
              _DockIconAction(
                icon: Symbols.close_rounded,
                tooltip: l10n.common_close,
                onTap: widget.onClose,
                compact: true,
              ),
            ],
          ),
        ),
      );
    }

    if (_errorTitle != null) {
      return _FrostedMediaPill(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Symbols.error_outline_rounded,
                size: 16,
                color: Color(0xFFFF8A80),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _errorTitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              _DockTextAction(
                label: l10n.common_viewDetails,
                onTap: _showErrorDetails,
              ),
              _DockTextAction(
                label: l10n.common_retry,
                emphasize: true,
                onTap: () => _startFlow(download: _needsDownload),
              ),
              _DockIconAction(
                icon: Symbols.close_rounded,
                tooltip: l10n.common_close,
                onTap: widget.onClose,
                compact: true,
              ),
            ],
          ),
        ),
      );
    }

    if (_needsDownload) {
      return _FrostedMediaPill(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${l10n.imageViewer_downloadOcr}（$totalMiB MiB）',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(width: 6),
              _DockTextAction(
                label: l10n.common_confirm,
                emphasize: true,
                onTap: () => _startFlow(download: true),
              ),
              _DockIconAction(
                icon: Symbols.close_rounded,
                tooltip: l10n.common_close,
                onTap: widget.onClose,
                compact: true,
              ),
            ],
          ),
        ),
      );
    }

    if (_reading || _translating) {
      final String label;
      if (_translating) {
        label = l10n.imageViewer_translatingImage;
      } else if (_ocrProgress?.stage == OcrStage.detecting) {
        label = l10n.imageViewer_detectingText;
      } else if (_ocrProgress?.stage == OcrStage.recognizing &&
          (_ocrProgress?.total ?? 0) > 0) {
        label = l10n.imageViewer_recognizingProgress(
          _ocrProgress!.completed,
          _ocrProgress!.total,
        );
      } else {
        label = l10n.imageViewer_recognizing;
      }
      return _FrostedMediaPill(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LoadingSpinner(size: 16, color: Colors.white),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(width: 6),
              _DockIconAction(
                icon: Symbols.close_rounded,
                tooltip: l10n.common_close,
                onTap: widget.onClose,
                compact: true,
              ),
            ],
          ),
        ),
      );
    }

    // 译图态：紧凑单排纯图标 + 短语言标签，不压画面
    if (widget.mode == ImageLiveOverlayMode.translate) {
      return _FrostedMediaPill(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onLongPressStart: (_) =>
                    setState(() => _showOriginalPeek = true),
                onLongPressEnd: (_) =>
                    setState(() => _showOriginalPeek = false),
                child: _DockTextAction(
                  icon: _showOriginalPeek
                      ? Symbols.visibility_rounded
                      : Symbols.compare_rounded,
                  label: _showOriginalPeek
                      ? l10n.imageViewer_showTranslated
                      : l10n.imageViewer_showOriginal,
                  onTap: toggleOriginalPeek,
                ),
              ),
              _DockIconAction(
                icon: Symbols.tune_rounded,
                tooltip:
                    '${aiTranslationLanguageLabel(_targetCode)} · ${translationEngineLabel(_engine)}',
                onTap: _showTranslateSettingsSheet,
              ),
              if (_translatedBlocks.isNotEmpty)
                _DockIconAction(
                  icon: Symbols.save_alt_rounded,
                  tooltip: l10n.imageViewer_saveTranslated,
                  busy: _savingTranslated,
                  onTap: _saveTranslatedImage,
                ),
              _DockIconAction(
                icon: Symbols.document_scanner_rounded,
                tooltip: l10n.imageViewer_recognizeText,
                onTap: () =>
                    widget.onModeChanged(ImageLiveOverlayMode.liveText),
              ),
              _DockIconAction(
                icon: Symbols.close_rounded,
                tooltip: l10n.common_close,
                onTap: widget.onClose,
              ),
            ],
          ),
        ),
      );
    }

    // 实况选字空闲态：极致紧凑单排玻璃坞
    return _FrostedMediaPill(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DockTextAction(
              icon: Symbols.select_all_rounded,
              label: l10n.imageViewer_selectAll,
              onTap: _selectAll,
            ),
            _DockIconAction(
              icon: Symbols.subject_rounded,
              tooltip: l10n.imageViewer_fullText,
              onTap: _openFullTextSheet,
            ),
            _DockIconAction(
              icon: Symbols.translate_rounded,
              tooltip: l10n.imageViewer_translateImage,
              onTap: () => widget.onModeChanged(ImageLiveOverlayMode.translate),
            ),
            _DockIconAction(
              icon: Symbols.close_rounded,
              tooltip: l10n.common_close,
              onTap: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// 仅在单指/鼠标按下位置命中句柄或文字时才认领滑动选字：
/// - 保留按下瞬间的精准坐标（避免超过拖动阈值后指针已偏离细文字行导致命中失败）；
/// - 移动超过极小阈值立即在手势竞技场胜出，确保底图平移/缩放不会抢走选字拖拽；
/// - 空白处不认领，双指按下立即让渡给底图捏合缩放。
class _ConditionalPanGestureRecognizer extends PanGestureRecognizer {
  bool Function(Offset localPosition, PointerDeviceKind kind)? shouldClaim;
  void Function(Offset downLocalPosition, PointerDeviceKind kind)?
  onClaimedStart;

  final Set<int> _activePointers = {};
  int? _claimedPointer;
  Offset? _downLocalPosition;
  PointerDeviceKind? _downKind;
  bool _accepted = false;

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) {
    // 绝不拦截桌面触控板双指滑动/捏合（PointerPanZoom），始终放行给画廊翻页与缩放。
    return false;
  }

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {}

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    if (_activePointers.length > 1) {
      // 第二根手指落下：立刻放弃选字拖拽，保证双指捏合缩放始终丝滑接管。
      _resetClaim();
      resolve(GestureDisposition.rejected);
      return;
    }
    if (shouldClaim?.call(event.localPosition, event.kind) != true) {
      _activePointers.remove(event.pointer);
      return;
    }
    _claimedPointer = event.pointer;
    _downLocalPosition = event.localPosition;
    _downKind = event.kind;
    _accepted = false;
    onStart = (_) {
      final pos = _downLocalPosition;
      final kind = _downKind;
      if (pos != null && kind != null) {
        onClaimedStart?.call(pos, kind);
      }
    };
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent &&
        event.pointer == _claimedPointer &&
        !_accepted &&
        _activePointers.length == 1 &&
        _downLocalPosition != null) {
      final slop = _downKind == PointerDeviceKind.mouse ? 3.0 : 6.0;
      if ((event.localPosition - _downLocalPosition!).distance >= slop) {
        _accepted = true;
        resolve(GestureDisposition.accepted);
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _activePointers.remove(event.pointer);
      if (event.pointer == _claimedPointer) {
        _resetClaim();
      }
    }
    super.handleEvent(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _activePointers.clear();
    _resetClaim();
    super.didStopTrackingLastPointer(pointer);
  }

  void _resetClaim() {
    _claimedPointer = null;
    _downLocalPosition = null;
    _downKind = null;
    _accepted = false;
  }
}

class _FrostedMediaPill extends StatelessWidget {
  const _FrostedMediaPill({
    required this.child,
    this.radius = 24,
    this.opacity = 0.72,
  });

  final Widget child;
  final double radius;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final borderRadius = context.shapes.borderRadius(radius);
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(borderRadius: borderRadius),
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRSuperellipse(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: const Color(0xFF26282E).withValues(alpha: opacity),
              shape: RoundedSuperellipseBorder(
                borderRadius: borderRadius,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
              ),
            ),
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
      ),
    );
  }
}

class _DockTextAction extends StatelessWidget {
  const _DockTextAction({
    this.icon,
    required this.label,
    required this.onTap,
    this.emphasize = false,
  });

  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final fg = emphasize ? Theme.of(context).colorScheme.primary : Colors.white;
    return InkWell(
      onTap: onTap,
      borderRadius: context.shapes.borderRadius(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Icon(icon, size: 17, color: fg),
              ),
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DockIconAction extends StatelessWidget {
  const _DockIconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.busy = false,
    this.compact = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool busy;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 32.0 : 40.0;
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: size,
        child: IconButton(
          padding: EdgeInsets.zero,
          onPressed: busy ? null : onTap,
          icon: busy
              ? const LoadingSpinner(size: 15, color: Colors.white)
              : Icon(icon, size: compact ? 18 : 20, color: Colors.white),
        ),
      ),
    );
  }
}

/// 实况选字画布绘制器：波纹点亮文字行 + 连续选区色带 + 首尾水滴手柄 + 圆形实时放大镜。
class _LiveTextOverlayPainter extends CustomPainter {
  const _LiveTextOverlayPainter({
    required this.displayRect,
    required this.imageSize,
    required this.decodedImage,
    required this.detectedBoxes,
    required this.showDetectedHighlights,
    required this.layout,
    required this.selection,
    required this.reading,
    required this.pulse,
    required this.sweep,
    required this.sweepOrigin,
    required this.dragFinger,
    required this.accentColor,
    required this.shapes,
  });

  final Rect displayRect;
  final Size imageSize;
  final ui.Image? decodedImage;
  final List<Rect> detectedBoxes;
  final bool showDetectedHighlights;
  final PictureTextLayout? layout;
  final ({int start, int end})? selection;
  final bool reading;
  final double pulse;
  final double sweep;
  final Offset sweepOrigin;
  final Offset? dragFinger;
  final Color accentColor;
  final UiShapes shapes;

  @override
  void paint(Canvas canvas, Size size) {
    if (displayRect.isEmpty || imageSize.isEmpty) return;
    final k = displayRect.width / imageSize.width;
    Rect mapBox(Rect r) => Rect.fromLTRB(
      displayRect.left + r.left * k,
      displayRect.top + r.top * k,
      displayRect.left + r.right * k,
      displayRect.top + r.bottom * k,
    );

    if (showDetectedHighlights && detectedBoxes.isNotEmpty) {
      final litAlpha = reading ? (0.12 + 0.18 * pulse) : 0.12;
      final maxReach = math.max(
        1.0,
        math.sqrt(
          math.pow(
                math.max(sweepOrigin.dx, imageSize.width - sweepOrigin.dx),
                2,
              ) +
              math.pow(
                math.max(sweepOrigin.dy, imageSize.height - sweepOrigin.dy),
                2,
              ),
        ),
      );
      for (final box in detectedBoxes) {
        final dist = (box.center - sweepOrigin).distance / maxReach;
        final shown = ((sweep * 1.25 - dist) / 0.25).clamp(0.0, 1.0);
        if (shown <= 0) continue;
        final r = mapBox(box);
        final radius = shapes.radius(math.min(6.0, r.height * 0.2));
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, radius),
          Paint()..color = Colors.white.withValues(alpha: litAlpha * shown),
        );
      }
    }

    final text = layout;
    final sel = selection;
    if (text == null || sel == null || text.isEmpty) return;
    final highlightColor = accentColor.withValues(alpha: 0.36);
    for (final lineRect in text.selectionRects(sel.start, sel.end)) {
      final r = mapBox(lineRect);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, shapes.radius(3)),
        Paint()..color = highlightColor,
      );
    }

    final first = mapBox(text.glyphs[sel.start].bounds);
    final last = mapBox(text.glyphs[sel.end].bounds);
    _drawHandle(canvas, first.left, first.top, first.bottom, isStart: true);
    _drawHandle(canvas, last.right, last.top, last.bottom, isStart: false);

    final finger = dragFinger;
    final img = decodedImage;
    if (finger != null && img != null) {
      _drawLoupe(canvas, finger, img, k);
    }
  }

  void _drawHandle(
    Canvas canvas,
    double x,
    double top,
    double bottom, {
    required bool isStart,
  }) {
    final paint = Paint()..color = accentColor;
    canvas.drawRect(Rect.fromLTRB(x - 1.2, top, x + 1.2, bottom), paint);
    const dotRadius = 6.0;
    final cy = isStart ? top - dotRadius * 0.65 : bottom + dotRadius * 0.65;
    canvas.drawCircle(Offset(x, cy), dotRadius, paint);
    canvas.drawCircle(
      Offset(x, cy),
      dotRadius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  void _drawLoupe(Canvas canvas, Offset finger, ui.Image image, double k) {
    const radius = 50.0;
    const zoom = 1.8;
    final center = Offset(
      finger.dx.clamp(radius + 8, displayRect.right.clamp(radius + 8, 4000)),
      math.max(radius + 16, finger.dy - radius - 42),
    );
    final px = (finger.dx - displayRect.left) / k;
    final py = (finger.dy - 12.0 - displayRect.top) / k;
    final halfSrc = radius / (k * zoom);
    final src = Rect.fromLTRB(
      px - halfSrc,
      py - halfSrc,
      px + halfSrc,
      py + halfSrc,
    );
    final dst = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(center, radius, Paint()..color = Colors.black);
    canvas.save();
    canvas.clipPath(Path()..addOval(dst));
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
  }

  @override
  bool shouldRepaint(covariant _LiveTextOverlayPainter oldDelegate) => true;
}

/// 覆盖式图片翻译绘制器：扫描中波纹提示，完成后高清矢量覆盖译文。
class _TranslatedOverlayPainter extends CustomPainter {
  const _TranslatedOverlayPainter({
    required this.displayRect,
    required this.imageSize,
    required this.blocks,
    required this.detectedBoxes,
    required this.pulse,
    required this.sweep,
    required this.sweepOrigin,
  });

  final Rect displayRect;
  final Size imageSize;
  final List<TranslatedTextBlock> blocks;
  final List<Rect> detectedBoxes;
  final double pulse;
  final double sweep;
  final Offset sweepOrigin;

  @override
  void paint(Canvas canvas, Size size) {
    if (displayRect.isEmpty || imageSize.isEmpty) return;

    if (blocks.isNotEmpty) {
      ImageTranslationService.paintTranslatedBlocks(
        canvas,
        displayRect: displayRect,
        imageSize: imageSize,
        blocks: blocks,
      );
      return;
    }

    if (detectedBoxes.isEmpty) return;
    final k = displayRect.width / imageSize.width;
    final alpha = 0.14 + 0.18 * pulse;
    final maxReach = math.max(
      1.0,
      math.sqrt(
        math.pow(math.max(sweepOrigin.dx, imageSize.width - sweepOrigin.dx), 2) +
            math.pow(
              math.max(sweepOrigin.dy, imageSize.height - sweepOrigin.dy),
              2,
            ),
      ),
    );
    for (final box in detectedBoxes) {
      final dist = (box.center - sweepOrigin).distance / maxReach;
      final shown = ((sweep * 1.25 - dist) / 0.25).clamp(0.0, 1.0);
      if (shown <= 0) continue;
      final r = Rect.fromLTRB(
        displayRect.left + box.left * k,
        displayRect.top + box.top * k,
        displayRect.left + box.right * k,
        displayRect.top + box.bottom * k,
      );
      canvas.drawRect(
        r,
        Paint()..color = Colors.white.withValues(alpha: alpha * shown),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TranslatedOverlayPainter oldDelegate) => true;
}
