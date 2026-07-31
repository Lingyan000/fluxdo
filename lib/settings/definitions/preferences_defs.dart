import 'dart:io';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../providers/ai_post_review_provider.dart';
import '../../providers/ai_translation_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/blocked_user_filter.dart';
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
      icon: Symbols.tune_rounded,
      items: [
        SwitchModel(
          id: 'anonymousShare',
          title: l10n.preferences_anonymousShare,
          subtitle: l10n.preferences_anonymousShareDesc,
          icon: Symbols.visibility_off_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).anonymousShare,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setAnonymousShare(v),
        ),
        SwitchModel(
          id: 'autoFillLogin',
          title: l10n.preferences_autoFillLogin,
          subtitle: l10n.preferences_autoFillLoginDesc,
          icon: Symbols.password_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).autoFillLogin,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setAutoFillLogin(v),
        ),
        SwitchModel(
          id: 'clipboardTopicLinkDetection',
          title: l10n.preferences_clipboardTopicLinkDetection,
          subtitle: l10n.preferences_clipboardTopicLinkDetectionDesc,
          icon: Symbols.content_paste_rounded,
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
          icon: Symbols.filter_alt_off_rounded,
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
        ActionModel(
          id: 'blockedUsernames',
          title: l10n.preferences_blockedUsernames,
          subtitle: l10n.preferences_blockedUsernamesDesc,
          icon: Symbols.person_off_rounded,
          getDynamicSubtitle: (ref) {
            final count = ref
                .watch(preferencesProvider)
                .blockedUsernames
                .length;
            if (count == 0) return l10n.preferences_blockedUsernamesEmpty;
            return l10n.preferences_blockedUsernamesCount(count);
          },
          onTap: (context, ref) => showBlockedUsernamesDialog(context, ref),
        ),
        PlatformConditionalModel(
          inner: SwitchModel(
            id: 'portraitLock',
            title: l10n.preferences_portraitLock,
            subtitle: l10n.preferences_portraitLockDesc,
            icon: Symbols.screen_lock_portrait_rounded,
            getValue: (ref) => ref.watch(preferencesProvider).portraitLock,
            onChanged: (ref, v) =>
                ref.read(preferencesProvider.notifier).setPortraitLock(v),
          ),
          condition: () => Platform.isIOS || Platform.isAndroid,
        ),
        PlatformConditionalModel(
          inner: SwitchModel(
            id: 'fullscreenSwipeBack',
            title: l10n.preferences_fullscreenSwipeBack,
            subtitle: l10n.preferences_fullscreenSwipeBackDesc,
            icon: Symbols.swipe_right_rounded,
            getValue: (ref) =>
                ref.watch(preferencesProvider).fullscreenSwipeBack,
            onChanged: (ref, v) => ref
                .read(preferencesProvider.notifier)
                .setFullscreenSwipeBack(v),
          ),
          condition: () => Platform.isIOS || Platform.isAndroid,
        ),
      ],
    ),
    SettingsGroup(
      title: l10n.preferences_editor,
      icon: Symbols.edit_note_rounded,
      items: [
        SwitchModel(
          id: 'autoPanguSpacing',
          title: l10n.preferences_autoPanguSpacing,
          subtitle: l10n.preferences_autoPanguSpacingDesc,
          icon: Symbols.auto_fix_high_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).autoPanguSpacing,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setAutoPanguSpacing(v),
        ),
        SwitchModel(
          id: 'useRichComposer',
          title: l10n.preferences_useRichComposer,
          subtitle: l10n.preferences_useRichComposerDesc,
          icon: Symbols.edit_document_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).useRichComposer,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setUseRichComposer(v),
        ),
        SwitchModel(
          id: 'composerEnterSoftBreak',
          title: l10n.preferences_composerEnterSoftBreak,
          subtitle: l10n.preferences_composerEnterSoftBreakDesc,
          icon: Symbols.keyboard_return_rounded,
          getValue: (ref) =>
              ref.watch(preferencesProvider).composerEnterSoftBreak,
          onChanged: (ref, v) => ref
              .read(preferencesProvider.notifier)
              .setComposerEnterSoftBreak(v),
          // 软换行是富文本编辑器(EditorState)的语义,源码编辑器不认
          enabledWhen: (ref) => ref.watch(preferencesProvider).useRichComposer,
        ),
        SwitchModel(
          id: 'composerLiveRender',
          title: l10n.preferences_composerLiveRender,
          subtitle: l10n.preferences_composerLiveRenderDesc,
          icon: Symbols.preview_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).composerLiveRender,
          onChanged: (ref, v) => ref
              .read(preferencesProvider.notifier)
              .setComposerLiveRender(v),
          // 即时渲染(ir)是富文本编辑器的模式,源码编辑器无显形概念
          enabledWhen: (ref) => ref.watch(preferencesProvider).useRichComposer,
        ),
        SwitchModel(
          id: 'aiPostReview',
          title: l10n.preferences_aiPostReview,
          subtitle: l10n.preferences_aiPostReviewDesc,
          icon: Symbols.fact_check_rounded,
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
          icon: Symbols.psychology_alt_rounded,
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
        SwitchModel(
          id: 'aiTranslation',
          title: l10n.ai_translationEnabled,
          subtitle: l10n.ai_translationEnabledDesc,
          icon: Symbols.translate_rounded,
          getValue: (ref) =>
              ref.watch(preferencesProvider).aiTranslationEnabled,
          onChanged: (ref, v) async {
            final notifier = ref.read(preferencesProvider.notifier);
            await notifier.setAiTranslationEnabled(v);
            if (!v) return;
            final prefs = ref.read(preferencesProvider);
            if (prefs.aiTranslationModelKey != null) return;
            final selected = ref.read(aiTranslationSelectedModelProvider);
            if (selected == null) return;
            await notifier.setAiTranslationModelKey(
              buildAiModelKey(selected.provider.id, selected.model.id),
            );
          },
        ),
        ActionModel(
          id: 'aiTranslationTargetLanguage',
          title: l10n.ai_translationTargetLanguage,
          icon: Symbols.translate_rounded,
          getDynamicSubtitle: (ref) {
            final preferred = ref.watch(
              preferencesProvider.select(
                (preferences) => preferences.aiTranslationTargetLanguage,
              ),
            );
            if (preferred == null || preferred.isEmpty) {
              return l10n.ai_translationTargetLanguageFollowApp;
            }
            return aiTranslationLanguageLabel(preferred);
          },
          onTap: (context, ref) =>
              _showAiTranslationLanguagePicker(context, ref),
        ),
        ActionModel(
          id: 'aiTranslationModel',
          title: l10n.ai_translationModel,
          icon: Symbols.psychology_alt_rounded,
          getDynamicSubtitle: (ref) {
            final selected = ref.watch(aiTranslationSelectedModelProvider);
            if (selected == null) {
              return l10n.ai_translationModelNotSelected;
            }
            final modelName = selected.model.name ?? selected.model.id;
            return '${selected.provider.name} / $modelName';
          },
          onTap: (context, ref) => _showAiTranslationModelSheet(context, ref),
        ),
        ActionModel(
          id: 'stickerSource',
          title: l10n.preferences_stickerSource,
          icon: Symbols.sticky_note_2_rounded,
          getDynamicSubtitle: (ref) =>
              ref.watch(stickerMarketServiceProvider).baseUrl,
          onTap: (context, ref) => _showStickerBaseUrlDialog(context, ref),
        ),
      ],
    ),
    if (Platform.isAndroid)
      SettingsGroup(
        title: l10n.preferences_advanced,
        icon: Symbols.bug_report_rounded,
        items: [
          SwitchModel(
            id: 'crashlytics',
            title: l10n.preferences_crashlytics,
            subtitle: l10n.preferences_crashlyticsDesc,
            icon: Symbols.bug_report_rounded,
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

void _showAiTranslationLanguagePicker(BuildContext context, WidgetRef ref) {
  final l10n = context.l10n;
  final current = ref.read(preferencesProvider).aiTranslationTargetLanguage;
  showAppDialog<String?>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(l10n.ai_translationTargetLanguage),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, ''),
          child: Row(
            children: [
              Icon(
                current == null || current.isEmpty
                    ? Symbols.radio_button_checked_rounded
                    : Symbols.radio_button_unchecked_rounded,
                color: current == null || current.isEmpty
                    ? Theme.of(dialogContext).colorScheme.primary
                    : null,
                size: 20,
              ),
              const SizedBox(width: 12),
              Text(l10n.ai_translationTargetLanguageFollowApp),
            ],
          ),
        ),
        for (final entry in aiTranslationLanguages.entries)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, entry.key),
            child: Row(
              children: [
                Icon(
                  entry.key == current
                      ? Symbols.radio_button_checked_rounded
                      : Symbols.radio_button_unchecked_rounded,
                  color: entry.key == current
                      ? Theme.of(dialogContext).colorScheme.primary
                      : null,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Text(entry.value),
              ],
            ),
          ),
      ],
    ),
  ).then((selected) {
    if (selected == null) return;
    ref
        .read(preferencesProvider.notifier)
        .setAiTranslationTargetLanguage(selected.isEmpty ? null : selected);
  });
}

Future<void> _showAiTranslationModelSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final allModels = ref.read(aiPostReviewAvailableModelsProvider);
  if (allModels.isEmpty) {
    ToastService.showInfo(context.l10n.aiPostReview_noAvailableModel);
    return;
  }

  final current =
      ref.read(aiTranslationSelectedModelProvider) ?? allModels.first;
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
      .setAiTranslationModelKey(
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
  late final List<String> _keywords;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '');
    _wholeWord = widget.initialWholeWord;
    _keywords = List<String>.from(widget.initialKeywords);
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
      scrollable: true,
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
                icon: const Icon(Symbols.clear_all_rounded, size: 18),
                label: Text(l10n.common_clear),
                onPressed: () => setState(() {
                  _keywords.clear();
                  _controller.clear();
                }),
              ),
            ),
            _EntryChipsEditor(
              controller: _controller,
              entries: _keywords,
              hintText: l10n.preferences_topicFilterKeywordsHint,
              helperText: l10n.preferences_topicFilterKeywordsHelper,
              normalizeEntry: (value) => value.trim(),
              isDuplicate: (existing, candidate) => existing == candidate,
              onEntriesChanged: (entries) {
                setState(() {
                  _keywords
                    ..clear()
                    ..addAll(entries);
                });
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
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
            final keywords = _appendTokenEntries(
              _keywords,
              _controller.text,
              normalizeEntry: (value) => value.trim(),
              isDuplicate: (existing, candidate) => existing == candidate,
            );
            Navigator.pop(context, (keywords: keywords, wholeWord: _wholeWord));
          },
          child: Text(l10n.common_confirm),
        ),
      ],
    );
  }
}

Future<void> showBlockedUsernamesDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final usernames = ref.read(preferencesProvider).blockedUsernames;
  final result = await showAppDialog<List<String>>(
    context: context,
    builder: (_) => _BlockedUsernamesDialog(initialUsernames: usernames),
  );
  if (result == null || !context.mounted) return;
  await ref.read(preferencesProvider.notifier).setBlockedUsernames(result);
}

class _BlockedUsernamesDialog extends StatefulWidget {
  final List<String> initialUsernames;

  const _BlockedUsernamesDialog({required this.initialUsernames});

  @override
  State<_BlockedUsernamesDialog> createState() =>
      _BlockedUsernamesDialogState();
}

class _BlockedUsernamesDialogState extends State<_BlockedUsernamesDialog> {
  late final TextEditingController _controller;
  late final List<String> _usernames;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '');
    _usernames = BlockedUserFilter.sanitizeUsernames(widget.initialUsernames);
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
      scrollable: true,
      title: Text(l10n.preferences_blockedUsernames),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Symbols.clear_all_rounded, size: 18),
                label: Text(l10n.common_clear),
                onPressed: () => setState(() {
                  _usernames.clear();
                  _controller.clear();
                }),
              ),
            ),
            _EntryChipsEditor(
              controller: _controller,
              entries: _usernames,
              hintText: l10n.preferences_blockedUsernamesHint,
              helperText: l10n.preferences_blockedUsernamesHelper,
              normalizeEntry: BlockedUserFilter.stripAtPrefix,
              isDuplicate: (existing, candidate) =>
                  BlockedUserFilter.normalizeUsername(existing) ==
                  BlockedUserFilter.normalizeUsername(candidate),
              onEntriesChanged: (entries) {
                setState(() {
                  _usernames
                    ..clear()
                    ..addAll(entries);
                });
              },
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
            final usernames = _appendTokenEntries(
              _usernames,
              _controller.text,
              normalizeEntry: BlockedUserFilter.stripAtPrefix,
              isDuplicate: (existing, candidate) =>
                  BlockedUserFilter.normalizeUsername(existing) ==
                  BlockedUserFilter.normalizeUsername(candidate),
            );
            Navigator.pop(
              context,
              BlockedUserFilter.sanitizeUsernames(usernames),
            );
          },
          child: Text(l10n.common_confirm),
        ),
      ],
    );
  }
}

typedef _TokenDuplicate = bool Function(String existing, String candidate);

List<String> _appendTokenEntries(
  List<String> existing,
  String rawInput, {
  required String Function(String value) normalizeEntry,
  required _TokenDuplicate isDuplicate,
}) {
  final entries = List<String>.from(existing);
  for (final part in rawInput.split(RegExp(r'[\r\n]+'))) {
    final candidate = normalizeEntry(part);
    if (candidate.isEmpty ||
        entries.any((entry) => isDuplicate(entry, candidate))) {
      continue;
    }
    entries.add(candidate);
  }
  return entries;
}

/// 回车后将本次输入立刻转成可删除的气泡，避免多行文本框在移动端键盘出现时
/// 挤压其余设置项。粘贴多行内容时也会一次识别为多个条目。
class _EntryChipsEditor extends StatefulWidget {
  final TextEditingController controller;
  final List<String> entries;
  final String hintText;
  final String helperText;
  final String Function(String value) normalizeEntry;
  final _TokenDuplicate isDuplicate;
  final ValueChanged<List<String>> onEntriesChanged;

  const _EntryChipsEditor({
    required this.controller,
    required this.entries,
    required this.hintText,
    required this.helperText,
    required this.normalizeEntry,
    required this.isDuplicate,
    required this.onEntriesChanged,
  });

  @override
  State<_EntryChipsEditor> createState() => _EntryChipsEditorState();
}

class _EntryChipsEditorState extends State<_EntryChipsEditor> {
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _commitInput([String? submittedValue]) {
    final nextEntries = _appendTokenEntries(
      widget.entries,
      submittedValue ?? widget.controller.text,
      normalizeEntry: widget.normalizeEntry,
      isDuplicate: widget.isDuplicate,
    );
    widget.controller.clear();
    if (nextEntries.length != widget.entries.length) {
      widget.onEntriesChanged(nextEntries);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.entries.isNotEmpty) ...[
          Semantics(
            liveRegion: true,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var index = 0; index < widget.entries.length; index++)
                  InputChip(
                    label: Text(widget.entries[index]),
                    onDeleted: () {
                      final nextEntries = List<String>.from(widget.entries)
                        ..removeAt(index);
                      widget.onEntriesChanged(nextEntries);
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: widget.controller,
          focusNode: _focusNode,
          decoration: InputDecoration(
            hintText: widget.hintText,
            helperText: widget.helperText,
            helperMaxLines: 2,
            border: const OutlineInputBorder(),
          ),
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          autofocus: true,
          onSubmitted: _commitInput,
          onChanged: (value) {
            if (value.contains('\n')) _commitInput(value);
          },
          style: theme.textTheme.bodyLarge,
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
