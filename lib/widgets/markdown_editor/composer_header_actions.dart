import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';

import '../../l10n/s.dart';
import '../../utils/platform_utils.dart';
import '../../services/draft_controller.dart';
import 'composer_draft_status.dart';
import 'composer_page_chrome.dart';
import 'composer_view_mode_switcher.dart';
import 'composer_submit_button.dart';

typedef ComposerReviewBuilder = Widget Function(
  Widget Function(bool reviewing, VoidCallback? trigger) builder,
);

enum _HeaderAction { preview, review, discard, draft }

/// 创建、编辑和回复共用的文档操作区。窄屏优先给标题和提交按钮留空间。
class ComposerHeaderActions extends StatelessWidget {
  const ComposerHeaderActions({
    super.key,
    required this.availableWidth,
    required this.submitLabel,
    required this.onSubmit,
    required this.previewing,
    required this.onTogglePreview,
    this.submitIcon,
    this.submitting = false,
    this.showDiscard = false,
    this.onDiscard,
    this.reviewBuilder,
    this.draftStatus,
    this.onRetryDraft,
    this.minimumTitleWidth,
    this.floating = false,
    this.endInset = 16,
  });

  final double availableWidth;

  /// Measured title content, including decorations such as a reply avatar.
  final double? minimumTitleWidth;
  final String submitLabel;
  final IconData? submitIcon;
  final VoidCallback? onSubmit;
  final bool submitting;
  final bool previewing;
  final VoidCallback? onTogglePreview;
  final bool showDiscard;
  final VoidCallback? onDiscard;
  final ValueListenable<DraftSaveStatus>? draftStatus;
  final VoidCallback? onRetryDraft;

  /// 顶栏没有实底（只有渐隐遮罩）时，操作与提交键收进同一块浮起胶囊
  final bool floating;

  /// 与屏幕右缘的距离（编辑页按 ComposerPageGrid）
  final double endInset;

  /// 审核状态跨收纳保留，结果锚定当前外显按钮或菜单入口。
  final ComposerReviewBuilder? reviewBuilder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    const submitWidth = 48.0;
    final actions = [
      _HeaderAction.preview,
      if (reviewBuilder != null) _HeaderAction.review,
      if (showDiscard && draftStatus == null) _HeaderAction.discard,
    ];
    // 保留导航和默认标题间距，标题至少容纳常规页面名称。
    final titleWidth = minimumTitleWidth ?? 120 * scaler.scale(22) / 22;
    final slots = math.max(
      1,
      ((availableWidth -
                  56 -
                  NavigationToolbar.kMiddleSpacing * 2 -
                  titleWidth -
                  16 -
                  submitWidth) /
              52)
          .floor(),
    );
    final inlineCount = draftStatus != null
        ? math.min(actions.length, slots - 1)
        : actions.length <= slots
        ? actions.length
        : slots - 1;
    final inline = actions.take(inlineCount).toList();
    final overflow = [
      if (draftStatus != null) _HeaderAction.draft,
      ...actions.skip(inlineCount),
      if (draftStatus != null && showDiscard) _HeaderAction.discard,
    ];
    // 草稿状态与舍弃固定收进菜单，其余操作按剩余空间收纳。
    assert(draftStatus != null || overflow.length != 1);

    String label(_HeaderAction action, bool reviewing) => switch (action) {
      _HeaderAction.preview =>
        previewing ? S.current.common_exitPreview : S.current.common_preview,
      _HeaderAction.review =>
        reviewing
            ? S.current.aiPostReview_reviewing
            : S.current.aiPostReview_button,
      _HeaderAction.discard => S.current.common_discard,
      _HeaderAction.draft => composerDraftStatusLabel(
        context,
        draftStatus!.value,
      ),
    };
    Object icon(_HeaderAction action) => switch (action) {
      _HeaderAction.preview => previewing ? AppIcons.edit : AppIcons.openBook,
      _HeaderAction.review => Symbols.auto_awesome_rounded,
      _HeaderAction.discard => Symbols.delete_rounded,
      _HeaderAction.draft => Symbols.cloud_upload_rounded,
    };
    VoidCallback? callback(_HeaderAction action, VoidCallback? onReview) =>
        switch (action) {
          _HeaderAction.preview => onTogglePreview,
          _HeaderAction.review => onReview,
          _HeaderAction.discard => onDiscard,
          _HeaderAction.draft =>
            [
                  DraftSaveStatus.error,
                  DraftSaveStatus.local,
                  DraftSaveStatus.conflict,
                ].contains(draftStatus?.value)
                ? onRetryDraft
                : null,
        };

    Widget more(
      bool reviewing,
      VoidCallback? onReview,
    ) => SwipeDismissiblePopupMenuButton<_HeaderAction>(
      key: const ValueKey('composer-header-more'),
      tooltip: S.current.common_more,
      requestFocus: PlatformUtils.isDesktop,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      icon: draftStatus == null
          ? const Icon(Symbols.more_horiz_rounded, size: 21)
          : ComposerDraftAttention(
              status: draftStatus!,
              child: const Icon(Symbols.more_horiz_rounded, size: 21),
            ),
      style: ComposerActionButton.buttonStyle,
      onSelected: (action) => callback(action, onReview)?.call(),
      itemBuilder: (_) => [
        for (final action in overflow) ...[
          if (action == _HeaderAction.discard && action != overflow.first ||
              action != _HeaderAction.draft &&
                  overflow.first == _HeaderAction.draft &&
                  overflow.indexOf(action) == 1)
            const PopupMenuDivider(),
          if (action == _HeaderAction.draft)
            ComposerDraftMenuEntry<_HeaderAction>(
              status: draftStatus!,
              retryValue: _HeaderAction.draft,
              canRetry: onRetryDraft != null,
            )
          else
            PopupMenuItem<_HeaderAction>(
              key: ValueKey('composer-header-${action.name}'),
              value: action,
              enabled: callback(action, onReview) != null,
              child: Row(
                children: [
                  if (action == _HeaderAction.review && reviewing)
                    const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    AppIcon(
                      icon(action),
                      size: 21,
                      color:
                          action == _HeaderAction.discard && onDiscard != null
                          ? theme.colorScheme.error
                          : null,
                    ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      label(action, reviewing),
                      style:
                          action == _HeaderAction.discard && onDiscard != null
                          ? TextStyle(color: theme.colorScheme.error)
                          : null,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );

    Widget reviewHost({required bool folded}) => KeyedSubtree(
      key: const ValueKey('composer-header-review-host'),
      child: reviewBuilder!(
        (reviewing, trigger) => folded
            ? more(reviewing, trigger)
            : ComposerActionButton(
                key: const ValueKey('composer-header-review-inline'),
                icon: Symbols.auto_awesome_rounded,
                label: label(_HeaderAction.review, reviewing),
                busy: reviewing,
                onPressed: trigger,
              ),
      ),
    );

    final buttons = [
      for (final action in inline)
        switch (action) {
          _HeaderAction.preview => ComposerPreviewButton(
            key: const ValueKey('composer-header-preview-inline'),
            previewing: previewing,
            onPressed: onTogglePreview,
          ),
          _HeaderAction.review => reviewHost(folded: false),
          _HeaderAction.discard => ComposerActionButton(
            key: const ValueKey('composer-header-discard-inline'),
            icon: Symbols.delete_rounded,
            label: S.current.common_discard,
            onPressed: onDiscard,
          ),
          _HeaderAction.draft => const SizedBox.shrink(),
        },
      if (overflow.isNotEmpty)
        overflow.contains(_HeaderAction.review)
            ? reviewHost(folded: true)
            : more(false, null),
    ];
    final submit = ComposerSubmitButton(
      label: submitLabel,
      icon: submitIcon,
      busy: submitting,
      onPressed: onSubmit,
      compact: floating,
    );
    return TextFieldTapRegion(
      child: Padding(
        padding: EdgeInsets.only(right: endInset),
        child: floating
            // 提交键的 48px 触控外框贴住胶囊右缘，36px 实心圆与胶囊上下右
            // 三边等距
            ? ComposerBarCapsule(
                padding: const EdgeInsetsDirectional.only(start: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [...buttons, submit],
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [...buttons, submit],
              ),
      ),
    );
  }
}
