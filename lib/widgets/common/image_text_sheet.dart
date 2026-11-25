import 'package:app_icons/app_icons.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../providers/image_ocr_provider.dart';
import '../../services/ocr/ocr_model_store.dart';
import '../../services/toast_service.dart';
import '../ai/ai_translation_sheet.dart';
import 'app_bottom_sheet.dart';

Future<void> showImageTextSheet(
  BuildContext context, {
  required Future<Uint8List> Function(CancelToken) loadImage,
}) => AppBottomSheet.show<void>(
  context: context,
  title: context.l10n.imageViewer_recognizeText,
  maxHeightFactor: 0.85,
  builder: (_) => ImageTextSheet(loadImage: loadImage),
);

class ImageTextSheet extends ConsumerStatefulWidget {
  const ImageTextSheet({super.key, required this.loadImage});
  final Future<Uint8List> Function(CancelToken) loadImage;

  @override
  ConsumerState<ImageTextSheet> createState() => _ImageTextSheetState();
}

class _ImageTextSheetState extends ConsumerState<ImageTextSheet> {
  final _token = CancelToken();
  bool _busy = true;
  bool _needsDownload = false;
  double? _progress;
  String? _text;
  String? _error;

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
      _busy = true;
      _error = null;
    });
    try {
      final store = ref.read(ocrModelStoreProvider);
      if (!await store.isReady()) {
        if (!mounted) return;
        if (!download) {
          setState(() {
            _needsDownload = true;
            _busy = false;
          });
          return;
        }
        await store.download(
          cancelToken: _token,
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
        );
      }
      if (!mounted) return;
      setState(() {
        _needsDownload = false;
        _progress = null;
      });
      final service = ref.read(localOcrServiceProvider);
      final bytes = await widget.loadImage(_token);
      if (!mounted) return;
      final text = await service.recognize(
        bytes,
        await store.paths(),
        cancelToken: _token,
      );
      if (mounted) setState(() => _text = text);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _needsDownload
              ? context.l10n.imageViewer_ocrDownloadFailed
              : context.l10n.imageViewer_ocrFailed,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_needsDownload) ...[
          Text(
            l10n.imageViewer_ocrDownloadDescription(
              (OcrModelStore.downloadBytes / 1048576).toStringAsFixed(1),
            ),
          ),
          const SizedBox(height: 12),
          if (!_busy)
            FilledButton.icon(
              onPressed: () => _recognize(download: true),
              icon: const Icon(Symbols.download_rounded),
              label: Text(l10n.imageViewer_downloadOcr),
            ),
        ],
        if (_busy)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                if (_progress == null)
                  const LoadingSpinner()
                else
                  M3eCircularProgress(value: _progress),
                const SizedBox(height: 12),
                Text(
                  _progress == null
                      ? l10n.imageViewer_recognizing
                      : '${(_progress! * 100).round()}%',
                ),
              ],
            ),
          ),
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          if (!_needsDownload)
            TextButton(
              onPressed: _busy ? null : _recognize,
              child: Text(l10n.common_retry),
            ),
        ],
        if (_text != null)
          Flexible(
            child: SingleChildScrollView(
              child: _text!.trim().isEmpty
                  ? Text(l10n.imageViewer_noText)
                  : SelectableText(_text!),
            ),
          ),
        if (_text?.trim().isNotEmpty ?? false) ...[
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _text!));
                  if (mounted) {
                    ToastService.showSuccess(
                      S.current.common_copiedToClipboard,
                    );
                  }
                },
                icon: const Icon(Symbols.content_copy_rounded),
                label: Text(l10n.common_copy),
              ),
              TextButton.icon(
                onPressed: () =>
                    showTextTranslationSheet(context, text: _text!),
                icon: const Icon(Symbols.translate_rounded),
                label: Text(l10n.ai_translationMenuLabel),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
