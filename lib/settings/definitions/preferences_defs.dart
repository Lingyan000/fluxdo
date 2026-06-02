import 'dart:io';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../providers/ai_post_review_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../../widgets/ai/ai_model_select_sheet.dart';
import '../../providers/sticker_provider.dart';
import '../../services/sticker_market_service.dart';
import '../settings_model.dart';

/// 功能设置数据声明
List<SettingsGroup> buildPreferencesGroups(BuildContext context) {
  final l10n = context.l10n;
  return [
    SettingsGroup(
      title: l10n.preferences_basic,
      icon: Icons.tune,
      items: [
        SwitchModel(
          id: 'anonymousShare',
          title: l10n.preferences_anonymousShare,
          subtitle: l10n.preferences_anonymousShareDesc,
          icon: Icons.visibility_off_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).anonymousShare,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setAnonymousShare(v),
        ),
        SwitchModel(
          id: 'autoFillLogin',
          title: l10n.preferences_autoFillLogin,
          subtitle: l10n.preferences_autoFillLoginDesc,
          icon: Icons.password_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).autoFillLogin,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setAutoFillLogin(v),
        ),
        SwitchModel(
          id: 'clipboardTopicLinkDetection',
          title: l10n.preferences_clipboardTopicLinkDetection,
          subtitle: l10n.preferences_clipboardTopicLinkDetectionDesc,
          icon: Icons.content_paste_rounded,
          getValue: (ref) =>
              ref.watch(preferencesProvider).clipboardTopicLinkDetection,
          onChanged: (ref, v) => ref
              .read(preferencesProvider.notifier)
              .setClipboardTopicLinkDetection(v),
        ),
        ActionModel(
          id: 'topicFilterKeywords',
          title: l10n.preferences_topicFilterKeywords,
          subtitle: l10n.preferences_topicFilterKeywordsDesc,
          icon: Icons.filter_alt_off_rounded,
          getDynamicSubtitle: (ref) {
            final count = ref
                .watch(preferencesProvider)
                .topicFilterKeywords
                .length;
            if (count == 0) return null;
            return l10n.preferences_topicFilterKeywordsCount(count);
          },
          onTap: (context, ref) => showTopicFilterKeywordsDialog(context, ref),
        ),
        SwitchModel(
          id: 'cfClearanceRefresh',
          title: l10n.preferences_cfClearanceRefresh,
          subtitle: l10n.preferences_cfClearanceRefreshDesc,
          icon: Icons.security_update_warning_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).cfClearanceRefresh,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setCfClearanceRefresh(v),
        ),
        PlatformConditionalModel(
          inner: SwitchModel(
            id: 'portraitLock',
            title: l10n.preferences_portraitLock,
            subtitle: l10n.preferences_portraitLockDesc,
            icon: Icons.screen_lock_portrait_rounded,
            getValue: (ref) => ref.watch(preferencesProvider).portraitLock,
            onChanged: (ref, v) =>
                ref.read(preferencesProvider.notifier).setPortraitLock(v),
          ),
          condition: () => Platform.isIOS || Platform.isAndroid,
        ),
      ],
    ),
    SettingsGroup(
      title: l10n.preferences_editor,
      icon: Icons.edit_note_rounded,
      items: [
        SwitchModel(
          id: 'autoPanguSpacing',
          title: l10n.preferences_autoPanguSpacing,
          subtitle: l10n.preferences_autoPanguSpacingDesc,
          icon: Icons.auto_fix_high_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).autoPanguSpacing,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setAutoPanguSpacing(v),
        ),
        SwitchModel(
          id: 'aiPostReview',
          title: l10n.preferences_aiPostReview,
          subtitle: l10n.preferences_aiPostReviewDesc,
          icon: Icons.fact_check_outlined,
          getValue: (ref) => ref.watch(preferencesProvider).aiPostReviewEnabled,
          onChanged: (ref, v) async {
            final notifier = ref.read(preferencesProvider.notifier);
            await notifier.setAiPostReviewEnabled(v);
            if (!v) return;
            final prefs = ref.read(preferencesProvider);
            if (prefs.aiPostReviewModelKey != null) return;
            final selected = ref.read(aiPostReviewSelectedModelProvider);
            if (selected == null) return;
            await notifier.setAiPostReviewModelKey(
              buildAiModelKey(selected.provider.id, selected.model.id),
            );
          },
        ),
        ActionModel(
          id: 'aiPostReviewModel',
          title: l10n.preferences_aiPostReviewModel,
          icon: Icons.psychology_alt_outlined,
          getDynamicSubtitle: (ref) {
            final selected = ref.watch(aiPostReviewSelectedModelProvider);
            if (selected == null) {
              return l10n.preferences_aiPostReviewModelNotSelected;
            }
            final modelName = selected.model.name ?? selected.model.id;
            return '${selected.provider.name} / $modelName';
          },
          onTap: (context, ref) => _showAiPostReviewModelSheet(context, ref),
        ),
        ActionModel(
          id: 'stickerSource',
          title: l10n.preferences_stickerSource,
          icon: Icons.sticky_note_2_outlined,
          getDynamicSubtitle: (ref) =>
              ref.watch(stickerMarketServiceProvider).baseUrl,
          onTap: (context, ref) => _showStickerBaseUrlDialog(context, ref),
        ),
      ],
    ),
    if (Platform.isAndroid)
      SettingsGroup(
        title: l10n.preferences_advanced,
        icon: Icons.bug_report_outlined,
        items: [
          SwitchModel(
            id: 'crashlytics',
            title: l10n.preferences_crashlytics,
            subtitle: l10n.preferences_crashlyticsDesc,
            icon: Icons.bug_report_rounded,
            getValue: (ref) => ref.watch(preferencesProvider).crashlytics,
            onChanged: (ref, v) =>
                ref.read(preferencesProvider.notifier).setCrashlytics(v),
          ),
        ],
      ),
  ];
}

Future<void> _showAiPostReviewModelSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final allModels = ref.read(aiPostReviewAvailableModelsProvider);
  if (allModels.isEmpty) {
    ToastService.showInfo(context.l10n.aiPostReview_noAvailableModel);
    return;
  }

  final current =
      ref.read(aiPostReviewSelectedModelProvider) ?? allModels.first;
  final selected = await showAiModelSelectSheet(
    context: context,
    allModels: allModels,
    current: current,
    mode: PromptType.text,
  );
  if (!context.mounted || selected == null) return;

  if (!selected.model.output.contains(Modality.text)) {
    ToastService.showInfo(context.l10n.aiPostReview_chooseTextModel);
    return;
  }

  await ref
      .read(preferencesProvider.notifier)
      .setAiPostReviewModelKey(
        buildAiModelKey(selected.provider.id, selected.model.id),
      );
}

typedef _TopicFilterDialogResult = ({List<String> keywords, bool wholeWord});

/// 打开「标题关键词过滤」编辑弹窗（公共入口，hint bar 与设置项均复用）。
Future<void> showTopicFilterKeywordsDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final prefs = ref.read(preferencesProvider);
  final result = await showAppDialog<_TopicFilterDialogResult>(
    context: context,
    builder: (dialogContext) => _TopicFilterKeywordsDialog(
      initialKeywords: prefs.topicFilterKeywords,
      initialWholeWord: prefs.topicFilterWholeWord,
    ),
  );
  if (result == null || !context.mounted) return;
  final notifier = ref.read(preferencesProvider.notifier);
  await notifier.setTopicFilterKeywords(result.keywords);
  await notifier.setTopicFilterWholeWord(result.wholeWord);
}

class _TopicFilterKeywordsDialog extends StatefulWidget {
  final List<String> initialKeywords;
  final bool initialWholeWord;

  const _TopicFilterKeywordsDialog({
    required this.initialKeywords,
    required this.initialWholeWord,
  });

  @override
  State<_TopicFilterKeywordsDialog> createState() =>
      _TopicFilterKeywordsDialogState();
}

class _TopicFilterKeywordsDialogState
    extends State<_TopicFilterKeywordsDialog> {
  late final TextEditingController _controller;
  late bool _wholeWord;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialKeywords.join('\n'),
    );
    _wholeWord = widget.initialWholeWord;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AlertDialog(
      title: Text(l10n.preferences_topicFilterKeywords),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.clear_all_rounded, size: 18),
                label: Text(l10n.common_clear),
                onPressed: () => _controller.clear(),
              ),
            ),
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: l10n.preferences_topicFilterKeywordsHint,
                helperText: l10n.preferences_topicFilterKeywordsHelper,
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.multiline,
              minLines: 5,
              maxLines: 10,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l10n.preferences_topicFilterWholeWord),
              subtitle: Text(l10n.preferences_topicFilterWholeWordDesc),
              value: _wholeWord,
              onChanged: (v) => setState(() => _wholeWord = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: () {
            final keywords = _controller.text
                .split('\n')
                .map((keyword) => keyword.trim())
                .where((keyword) => keyword.isNotEmpty)
                .toList();
            Navigator.pop(context, (keywords: keywords, wholeWord: _wholeWord));
          },
          child: Text(l10n.common_confirm),
        ),
      ],
    );
  }
}

void _showStickerBaseUrlDialog(BuildContext context, WidgetRef ref) {
  final service = ref.read(stickerMarketServiceProvider);
  final controller = TextEditingController(text: service.baseUrl);

  showAppDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(context.l10n.preferences_stickerSource),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: context.l10n.preferences_enterUrl,
              border: const OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
            autofocus: true,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                controller.text = StickerMarketService.defaultBaseUrl;
              },
              child: Text(context.l10n.common_restoreDefault),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(context.l10n.common_cancel),
        ),
        FilledButton(
          onPressed: () async {
            final url = controller.text.trim();
            if (url.isNotEmpty) {
              await service.setBaseUrl(url);
              ref.invalidate(stickerGroupsProvider);
            }
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          },
          child: Text(context.l10n.common_confirm),
        ),
      ],
    ),
  ).then((_) => controller.dispose());
}
