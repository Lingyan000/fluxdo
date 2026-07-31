import 'dart:async';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../providers/ai_translation_provider.dart';
import '../../services/ai_translation_service.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../common/app_bottom_sheet.dart';

/// 打开帖子 AI 翻译弹层。弹层独立于楼层树，避免破坏帖子实例缓存。
void showAiTranslationSheet(
  BuildContext context, {
  required String cookedHtml,
}) {
  showAppBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => AppSheetScaffold(
      maxHeightFactor: 0.85,
      child: _AiTranslationSheetBody(cookedHtml: cookedHtml),
    ),
  );
}

class _AiTranslationSheetBody extends ConsumerStatefulWidget {
  const _AiTranslationSheetBody({required this.cookedHtml});

  final String cookedHtml;

  @override
  ConsumerState<_AiTranslationSheetBody> createState() =>
      _AiTranslationSheetBodyState();
}

class _AiTranslationSheetBodyState
    extends ConsumerState<_AiTranslationSheetBody> {
  final StringBuffer _result = StringBuffer();
  StreamSubscription<String>? _subscription;
  Timer? _flushTimer;
  bool _dirty = false;
  bool _firstDeltaShown = false;
  bool _streaming = false;
  bool _truncated = false;
  String? _error;

  /// 高频 token 合并为约 12 FPS 的 UI 更新，避免长译文逐 token 重建。
  static const _flushInterval = Duration(milliseconds: 80);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  void _markDirty() {
    if (!_firstDeltaShown) {
      _firstDeltaShown = true;
      _dirty = false;
      setState(() {});
      return;
    }
    _dirty = true;
    _flushTimer ??= Timer(_flushInterval, () {
      _flushTimer = null;
      if (!mounted || !_dirty) return;
      _dirty = false;
      setState(() {});
    });
  }

  Future<void> _start() async {
    if (!mounted) return;
    await _subscription?.cancel();
    setState(() {
      _result.clear();
      _error = null;
      _firstDeltaShown = false;
      _truncated = false;
      _streaming = true;
    });

    final selected = ref.read(aiTranslationSelectedModelProvider);
    if (selected == null) {
      setState(() {
        _streaming = false;
        _error = S.current.ai_translationNoModel;
      });
      return;
    }
    final apiKey = await AiProviderListNotifier.getApiKey(selected.provider.id);
    if (!mounted) return;
    if (apiKey == null || apiKey.trim().isEmpty) {
      setState(() {
        _streaming = false;
        _error = S.current.ai_translationNoApiKey;
      });
      return;
    }

    final text = AiTranslationService.extractPlainText(widget.cookedHtml);
    if (text.isEmpty) {
      setState(() {
        _streaming = false;
        _error = S.current.ai_translationEmptyContent;
      });
      return;
    }
    final clamped = AiTranslationService.clampForTranslation(text);
    if (clamped.truncated) {
      setState(() => _truncated = true);
    }

    final target = ref.read(aiTranslationTargetLanguageProvider);
    final service = ref.read(aiTranslationServiceProvider);
    _subscription = service
        .translateStream(
          provider: selected.provider,
          model: selected.model,
          apiKey: apiKey.trim(),
          text: clamped.text,
          targetLanguage: aiTranslationLanguageLabel(target),
        )
        .listen(
          (delta) {
            if (!mounted) return;
            _result.write(delta);
            _markDirty();
          },
          onError: (Object error) {
            if (!mounted) return;
            _flushTimer?.cancel();
            _flushTimer = null;
            _dirty = false;
            setState(() {
              _streaming = false;
              _error = S.current.ai_translationFailed;
            });
            debugPrint('[AiTranslation] 翻译失败: $error');
          },
          onDone: () {
            if (!mounted) return;
            _flushTimer?.cancel();
            _flushTimer = null;
            _dirty = false;
            setState(() {
              _streaming = false;
              // 流正常结束却一个 TextDelta 都没有:推理模型把预算烧在
              // thinking 上导致正文被截断、内容策略拦截、provider 返回空
              // SSE body 都会走到这里。不置错误的话 build 会落进
              // `_result.isEmpty` 的 spinner 分支且永不退出 —— 既没有提示
              // 也没有重试入口。对齐 AiPostReviewService 的空结果保护。
              if (_result.isEmpty) _error = S.current.ai_translationFailed;
            });
          },
        );
  }

  /// 中途停止:保留已生成的部分译文;一个字都没出时落进错误分支
  /// 给出「已停止」+ 重试,避免停在永久 spinner。
  void _stop() {
    _subscription?.cancel();
    _subscription = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirty = false;
    setState(() {
      _streaming = false;
      if (_result.isEmpty) _error = S.current.ai_translationStopped;
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _result.toString()));
    if (mounted) ToastService.showSuccess(S.current.common_copiedToClipboard);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = ref.watch(aiTranslationTargetLanguageProvider);
    final selected = ref.watch(aiTranslationSelectedModelProvider);
    final l10n = context.l10n;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Symbols.translate_rounded,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              l10n.ai_translationTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              aiTranslationLanguageLabel(target),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (selected != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '${selected.provider.name} / ${selected.model.name ?? selected.model.id}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (_truncated)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10n.ai_translationTruncated,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.tertiary,
              ),
            ),
          ),
        const SizedBox(height: 12),
        Flexible(
          child: SingleChildScrollView(
            child: _error != null
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed: _start,
                          child: Text(l10n.common_retry),
                        ),
                      ],
                    ),
                  )
                : _result.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    ),
                  )
                : SelectableText(
                    _result.toString(),
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_streaming) ...[
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _stop,
                icon: const Icon(Symbols.stop_rounded, size: 18),
                label: Text(l10n.ai_stopGenerate),
              ),
            ],
            TextButton.icon(
              onPressed: _result.isEmpty ? null : _copy,
              icon: const Icon(Symbols.content_copy_rounded, size: 18),
              label: Text(l10n.common_copy),
            ),
          ],
        ),
      ],
    );
  }
}
