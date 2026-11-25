import 'dart:async';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:app_icons/app_icons.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/translation_engine.dart';
import '../../providers/ai_translation_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../services/ai_translation_service.dart';
import '../../services/toast_service.dart';
import '../../services/translation_service.dart';
import '../common/app_bottom_sheet.dart';

/// 帖子和图片识字结果共用翻译界面，识字结果直接作为纯文本传递。
void showAiTranslationSheet(
  BuildContext context, {
  required String cookedHtml,
}) {
  showTextTranslationSheet(
    context,
    text: AiTranslationService.extractPlainText(cookedHtml),
  );
}

Future<void> showTextTranslationSheet(
  BuildContext context, {
  required String text,
}) => AppBottomSheet.show<void>(
  context: context,
  title: context.l10n.ai_translationTitle,
  maxHeightFactor: 0.85,
  builder: (_) => TranslationSheetBody(text: text),
);

class TranslationSheetBody extends ConsumerStatefulWidget {
  const TranslationSheetBody({super.key, required this.text});

  final String text;

  @override
  ConsumerState<TranslationSheetBody> createState() =>
      _TranslationSheetBodyState();
}

class _TranslationSheetBodyState extends ConsumerState<TranslationSheetBody> {
  final _result = StringBuffer();
  StreamSubscription<String>? _subscription;
  CancelToken? _cancelToken;
  Timer? _flushTimer;
  late TranslationEngine _engine;
  late String _target;
  int _generation = 0;
  bool _streaming = false;
  bool _truncated = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _engine = ref.read(preferencesProvider).translationEngine;
    _target = ref.read(aiTranslationTargetLanguageProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  void _cancel() {
    _generation++;
    _cancelToken?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  Future<void> _start() async {
    if (!mounted) return;
    _cancel();
    final generation = _generation;
    final cancelToken = _cancelToken = CancelToken();
    setState(() {
      _result.clear();
      _error = null;
      _truncated = false;
      _streaming = true;
    });
    try {
      var text = widget.text.trim();
      if (text.isEmpty) throw S.current.ai_translationEmptyContent;
      Stream<String> stream;
      if (_engine == TranslationEngine.ai) {
        final selected = ref.read(aiTranslationSelectedModelProvider);
        if (selected == null) throw S.current.ai_translationNoModel;
        final apiKey = await AiProviderListNotifier.getApiKey(
          selected.provider.id,
        );
        if (!mounted || generation != _generation) return;
        if (apiKey == null || apiKey.trim().isEmpty) {
          throw S.current.ai_translationNoApiKey;
        }
        final clamped = AiTranslationService.clampForTranslation(text);
        _truncated = clamped.truncated;
        text = clamped.text;
        stream = ref
            .read(aiTranslationServiceProvider)
            .translateStream(
              provider: selected.provider,
              model: selected.model,
              apiKey: apiKey.trim(),
              text: text,
              targetLanguage: aiTranslationLanguageLabel(_target),
            );
      } else {
        stream = ref
            .read(translationServiceProvider)
            .translate(
              engine: _engine,
              text: text,
              targetCode: _target,
              targetName: aiTranslationLanguageLabel(_target),
              cancelToken: cancelToken,
            );
      }
      if (!mounted || generation != _generation) return;
      _subscription = stream.listen(
        (delta) {
          if (!mounted || generation != _generation) return;
          final first = _result.isEmpty;
          _result.write(delta);
          if (first) {
            setState(() {});
          } else {
            _flushTimer ??= Timer(const Duration(milliseconds: 80), () {
              _flushTimer = null;
              if (mounted && generation == _generation) setState(() {});
            });
          }
        },
        onError: (Object error) => _failed(error, generation),
        onDone: () {
          if (!mounted || generation != _generation) return;
          _flushTimer?.cancel();
          _flushTimer = null;
          setState(() {
            _streaming = false;
            if (_result.toString().trim().isEmpty) {
              _error = S.current.ai_translationFailed;
            }
          });
        },
        cancelOnError: true,
      );
    } catch (error) {
      _failed(error, generation);
    }
  }

  void _failed(Object error, int generation) {
    if (!mounted || generation != _generation) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    setState(() {
      _streaming = false;
      _error = switch (error) {
        String message => message,
        TranslationException(failure: TranslationFailure.rateLimited) =>
          S.current.ai_translationRateLimited,
        TranslationException(failure: TranslationFailure.incomplete) =>
          S.current.ai_translationIncomplete,
        _ => S.current.ai_translationFailed,
      };
    });
  }

  void _stop() {
    _cancel();
    setState(() {
      _streaming = false;
      _error = S.current.ai_translationStopped;
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _result.toString()));
    if (mounted) ToastService.showSuccess(S.current.common_copiedToClipboard);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final selected = _engine == TranslationEngine.ai
        ? ref.watch(aiTranslationSelectedModelProvider)
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 16,
          children: [
            DropdownButton<TranslationEngine>(
              value: _engine,
              hint: Text(l10n.ai_translationEngine),
              items: [
                for (final engine in TranslationEngine.values)
                  DropdownMenuItem(
                    value: engine,
                    child: Text(translationEngineLabel(engine)),
                  ),
              ],
              onChanged: (engine) {
                if (engine == null || engine == _engine) return;
                _engine = engine;
                ref
                    .read(preferencesProvider.notifier)
                    .setTranslationEngine(engine);
                _start();
              },
            ),
            DropdownButton<String>(
              value: _target,
              hint: Text(l10n.ai_translationTargetLanguage),
              items: [
                for (final language in aiTranslationLanguages.entries)
                  DropdownMenuItem(
                    value: language.key,
                    child: Text(language.value),
                  ),
              ],
              onChanged: (target) {
                if (target == null || target == _target) return;
                _target = target;
                _start();
              },
            ),
          ],
        ),
        if (selected != null)
          Text(
            '${selected.provider.name} / ${selected.model.name ?? selected.model.id}',
            style: theme.textTheme.bodySmall,
          ),
        if (_truncated)
          Text(l10n.ai_translationTruncated, style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_result.isNotEmpty)
                  SelectableText(
                    _result.toString(),
                    style: theme.textTheme.bodyMedium,
                  ),
                if (_result.isEmpty && _streaming)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: LoadingSpinner()),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _start,
                      child: Text(l10n.common_retry),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_streaming)
              TextButton.icon(
                onPressed: _stop,
                icon: const Icon(Symbols.stop_rounded),
                label: Text(l10n.ai_stopGenerate),
              ),
            TextButton.icon(
              onPressed: _result.isEmpty ? null : _copy,
              icon: const Icon(Symbols.content_copy_rounded),
              label: Text(l10n.common_copy),
            ),
          ],
        ),
      ],
    );
  }
}
