import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../providers/image_ocr_provider.dart';
import '../../services/app_logger.dart';
import '../../services/ocr/local_ocr_service.dart';
import '../../services/ocr/ocr_model_store.dart';
import '../../services/toast_service.dart';
import '../ai/ai_translation_sheet.dart';
import 'app_bottom_sheet.dart';
import 'error_view.dart';

Future<void> showImageTextSheet(
  BuildContext context, {
  required Future<Uint8List> Function(CancelToken) loadImage,
}) => AppBottomSheet.show<void>(
  context: context,
  title: context.l10n.imageViewer_recognizeText,
  maxHeightFactor: 0.85,
  builder: (_) => ImageTextSheet(loadImage: loadImage),
);

enum _OcrSheetPhase {
  checking,
  needsDownload,
  downloading,
  recognizing,
  done,
  error,
}

class ImageTextSheet extends ConsumerStatefulWidget {
  const ImageTextSheet({super.key, required this.loadImage});
  final Future<Uint8List> Function(CancelToken) loadImage;

  @override
  ConsumerState<ImageTextSheet> createState() => _ImageTextSheetState();
}

class _ImageTextSheetState extends ConsumerState<ImageTextSheet> {
  final _token = CancelToken();
  _OcrSheetPhase _phase = _OcrSheetPhase.checking;
  double? _downloadProgress;
  OcrProgress? _ocrProgress;
  String? _text;
  String? _selectedText;
  String? _error;
  Object? _errorObject;
  StackTrace? _errorStackTrace;

  @override
  void initState() {
    super.initState();
    _recognize();
  }

  @override
  void dispose() {
    _token.cancel();
    super.dispose();
  }

  Future<void> _recognize({bool download = false}) async {
    setState(() {
      _phase = download
          ? _OcrSheetPhase.downloading
          : _OcrSheetPhase.checking;
      _downloadProgress = null;
      _ocrProgress = null;
      _error = null;
      _errorObject = null;
      _errorStackTrace = null;
    });
    var failedWhileDownloading = download;
    try {
      final store = ref.read(ocrModelStoreProvider);
      if (!await store.isReady()) {
        if (!mounted) return;
        if (!download) {
          setState(() => _phase = _OcrSheetPhase.needsDownload);
          return;
        }
        failedWhileDownloading = true;
        setState(() {
          _phase = _OcrSheetPhase.downloading;
          _downloadProgress = null;
        });
        await store.download(
          cancelToken: _token,
          onProgress: (progress) {
            if (mounted) {
              setState(() {
                _phase = _OcrSheetPhase.downloading;
                _downloadProgress = progress;
              });
            }
          },
        );
      }
      if (!mounted) return;
      failedWhileDownloading = false;
      setState(() {
        _phase = _OcrSheetPhase.recognizing;
        _downloadProgress = null;
        _ocrProgress = null;
      });
      final service = ref.read(localOcrServiceProvider);
      final bytes = await widget.loadImage(_token);
      if (!mounted) return;
      final result = await service.recognizeDetailed(
        bytes,
        await store.paths(),
        cancelToken: _token,
        onProgress: (progress) {
          if (mounted && _phase == _OcrSheetPhase.recognizing) {
            setState(() => _ocrProgress = progress);
          }
        },
      );
      if (!mounted) return;
      setState(() {
        _text = result.plainText;
        _selectedText = null;
        _phase = _OcrSheetPhase.done;
      });
    } catch (error, stackTrace) {
      if (!mounted || _token.isCancelled) return;
      AppLogger.error(
        failedWhileDownloading ? 'OCR 模型下载或校验失败' : 'OCR 离线识字失败',
        tag: 'OCR',
        error: error,
        stackTrace: stackTrace,
        fields: {'phase': failedWhileDownloading ? 'download' : 'recognize'},
      );
      if (failedWhileDownloading) {
        setState(() {
          _phase = _OcrSheetPhase.needsDownload;
          _downloadProgress = null;
          _error = context.l10n.imageViewer_ocrDownloadFailed;
          _errorObject = error;
          _errorStackTrace = stackTrace;
        });
      } else {
        ref.read(ocrModelStoreProvider).invalidateVerificationCache();
        setState(() {
          _phase = _OcrSheetPhase.error;
          _ocrProgress = null;
          _error = context.l10n.imageViewer_ocrFailed;
          _errorObject = error;
          _errorStackTrace = stackTrace;
        });
      }
    }
  }

  String get _activeText {
    final selected = _selectedText?.trim();
    if (selected != null && selected.isNotEmpty) return selected;
    return _text ?? '';
  }

  bool get _hasSelection => (_selectedText?.trim().isNotEmpty ?? false);

  Future<void> _copyActiveText() async {
    final content = _activeText;
    if (content.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: content));
    if (mounted) {
      ToastService.showSuccess(S.current.common_copiedToClipboard);
    }
  }

  void _translateActiveText() {
    final content = _activeText;
    if (content.isEmpty) return;
    showTextTranslationSheet(context, text: content);
  }

  @override
  Widget build(BuildContext context) {
    return switch (_phase) {
      _OcrSheetPhase.checking => _buildProgressView(
        context,
        progress: null,
        title: context.l10n.imageViewer_recognizing,
      ),
      _OcrSheetPhase.needsDownload => _buildDownloadPrompt(context),
      _OcrSheetPhase.downloading => _buildDownloadingView(context),
      _OcrSheetPhase.recognizing => _buildRecognizingView(context),
      _OcrSheetPhase.done => _buildResultView(context),
      _OcrSheetPhase.error => _buildErrorView(context),
    };
  }

  Widget _buildDownloadPrompt(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final totalMiB = (OcrModelStore.downloadBytes / 1048576).toStringAsFixed(1);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: ShapeDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedSuperellipseBorder(
              borderRadius: context.shapes.borderRadius(16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: ShapeDecoration(
                      color: theme.colorScheme.primaryContainer,
                      shape: RoundedSuperellipseBorder(
                        borderRadius: context.shapes.borderRadius(12),
                      ),
                    ),
                    child: Icon(
                      Symbols.document_scanner_rounded,
                      color: theme.colorScheme.onPrimaryContainer,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.imageViewer_ocrDownloadDescription(totalMiB),
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    Symbols.shield_lock_rounded,
                    size: 16,
                    color: context.emphasis.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.imageViewer_ocrModelReadyHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          InlineErrorView(
            error: _errorObject ?? _error!,
            message: _error,
            compact: true,
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => _recognize(download: true),
          icon: const Icon(Symbols.download_rounded),
          label: Text(l10n.imageViewer_downloadOcr),
        ),
      ],
    );
  }

  Widget _buildDownloadingView(BuildContext context) {
    final l10n = context.l10n;
    final totalMiB = OcrModelStore.downloadBytes / 1048576;
    final progress = _downloadProgress;
    final subtitle = progress == null
        ? null
        : '${(progress * 100).round()}% · '
              '${l10n.imageViewer_downloadingOcrProgress((totalMiB * progress).toStringAsFixed(1), totalMiB.toStringAsFixed(1))}';
    return _buildProgressView(
      context,
      progress: progress,
      title: l10n.imageViewer_downloadingOcr,
      subtitle: subtitle,
    );
  }

  Widget _buildRecognizingView(BuildContext context) {
    final l10n = context.l10n;
    final ocr = _ocrProgress;
    final String title;
    double? progress;
    if (ocr == null || ocr.stage == OcrStage.decoding) {
      title = l10n.imageViewer_recognizing;
    } else if (ocr.stage == OcrStage.detecting) {
      title = l10n.imageViewer_detectingText;
      progress = ocr.total > 1 ? ocr.fraction : null;
    } else {
      title = ocr.total > 0
          ? l10n.imageViewer_recognizingProgress(ocr.completed, ocr.total)
          : l10n.imageViewer_recognizing;
      progress = ocr.fraction;
    }
    return _buildProgressView(context, progress: progress, title: title);
  }

  Widget _buildProgressView(
    BuildContext context, {
    required double? progress,
    required String title,
    String? subtitle,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (progress == null)
            const LoadingSpinner()
          else
            M3eCircularProgress(value: progress),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleSmall),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorView(BuildContext context) {
    final l10n = context.l10n;
    return ErrorView(
      error: _errorObject ?? (_error ?? l10n.imageViewer_ocrFailed),
      stackTrace: _errorStackTrace,
      title: _error ?? l10n.imageViewer_ocrFailed,
      onRetry: _recognize,
    );
  }

  Widget _buildResultView(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final text = _text?.trim() ?? '';
    if (text.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: AppEmptyState(
          animate: false,
          icon: Icon(
            Symbols.text_fields_rounded,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          title: l10n.imageViewer_noText,
        ),
      );
    }

    final lineCount = text.split('\n').length;
    final charCount = text.replaceAll(RegExp(r'\s+'), '').length;
    final selectedCount =
        _selectedText?.trim().replaceAll(RegExp(r'\s+'), '').length ?? 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Text(
                _hasSelection
                    ? l10n.imageViewer_ocrSelectedStats(selectedCount)
                    : l10n.imageViewer_ocrStats(lineCount, charCount),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: _hasSelection
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Flexible(
          child: Container(
            width: double.infinity,
            decoration: ShapeDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              shape: RoundedSuperellipseBorder(
                borderRadius: context.shapes.borderRadius(14),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: SelectableText(
                _text!,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                onSelectionChanged: (selection, _) {
                  final next = selection.isValid && !selection.isCollapsed
                      ? _text!.substring(
                          selection.start.clamp(0, _text!.length),
                          selection.end.clamp(0, _text!.length),
                        )
                      : null;
                  if (next != _selectedText) {
                    setState(() => _selectedText = next);
                  }
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _copyActiveText,
                icon: const Icon(Symbols.content_copy_rounded, size: 18),
                label: Text(
                  _hasSelection
                      ? l10n.imageViewer_copySelected
                      : l10n.common_copy,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _translateActiveText,
                icon: const Icon(Symbols.translate_rounded, size: 18),
                label: Text(
                  _hasSelection
                      ? l10n.imageViewer_translateSelected
                      : l10n.ai_translationMenuLabel,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
