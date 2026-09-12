import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../utils/platform_utils.dart';
import 'composer_page_chrome.dart';
import 'composer_view_mode_switcher.dart';

typedef ComposerReviewBuilder =
    Widget Function(
      Widget Function(bool reviewing, VoidCallback? trigger) builder,
    );

enum _HeaderAction { preview, review, discard }

/// 创建、编辑和回复共用的文档操作区。窄屏优先给标题和提交按钮留空间。
class ComposerHeaderActions extends StatelessWidget {
  const ComposerHeaderActions({
    super.key,
    required this.availableWidth,
    required this.submitLabel,
    required this.onSubmit,
    required this.previewing,
    required this.onTogglePreview,
    this.submitting = false,
    this.showDiscard = false,
    this.onDiscard,
    this.reviewBuilder,
  });

  final double availableWidth;
  final String submitLabel;
  final VoidCallback? onSubmit;
  final bool submitting;
  final bool previewing;
  final VoidCallback? onTogglePreview;
  final bool showDiscard;
  final VoidCallback? onDiscard;

  /// 审核状态跨收纳保留，结果锚定当前外显按钮或菜单入口。
  final ComposerReviewBuilder? reviewBuilder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final labelPainter = TextPainter(
      text: TextSpan(
        text: submitLabel,
        style:
            FilledButtonTheme.of(context).style?.textStyle?.resolve({}) ??
            theme.textTheme.labelLarge,
      ),
      textDirection: Directionality.of(context),
      textScaler: scaler,
    )..layout();
    final submitWidth = math.max(64.0, labelPainter.width + 32);
    labelPainter.dispose();
    final actions = [
      _HeaderAction.preview,
      if (reviewBuilder != null) _HeaderAction.review,
      if (showDiscard) _HeaderAction.discard,
    ];
    // 保留导航和默认标题间距，标题至少容纳常规页面名称。
    final titleWidth = 120 * scaler.scale(22) / 22;
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
    final inlineCount = actions.length <= slots ? actions.length : slots - 1;
    final inline = actions.take(inlineCount).toList();
    final overflow = actions.skip(inlineCount).toList();
    // 仅超出容量时才使用菜单；为菜单预留一格后，收纳项必然至少有两项。
    assert(overflow.length != 1);

    String label(_HeaderAction action, bool reviewing) => switch (action) {
      _HeaderAction.preview =>
        previewing ? S.current.common_exitPreview : S.current.common_preview,
      _HeaderAction.review =>
        reviewing
            ? S.current.aiPostReview_reviewing
            : S.current.aiPostReview_button,
      _HeaderAction.discard => S.current.common_discard,
    };
    IconData icon(_HeaderAction action) => switch (action) {
      _HeaderAction.preview =>
        previewing ? Symbols.edit_rounded : AppIcons.book,
      _HeaderAction.review => Symbols.auto_awesome_rounded,
      _HeaderAction.discard => Symbols.delete_rounded,
    };
    VoidCallback? callback(_HeaderAction action, VoidCallback? onReview) =>
        switch (action) {
          _HeaderAction.preview => onTogglePreview,
          _HeaderAction.review => onReview,
          _HeaderAction.discard => onDiscard,
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
      icon: const Icon(Symbols.more_horiz_rounded, size: 21),
      style: ComposerActionButton.buttonStyle,
      onSelected: (action) => callback(action, onReview)?.call(),
      itemBuilder: (_) => [
        for (final action in overflow) ...[
          if (action == _HeaderAction.discard && action != overflow.first)
            const PopupMenuDivider(),
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
                  Icon(
                    icon(action),
                    size: 21,
                    color: action == _HeaderAction.discard && onDiscard != null
                        ? theme.colorScheme.error
                        : null,
                  ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    label(action, reviewing),
                    style: action == _HeaderAction.discard && onDiscard != null
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

    return TextFieldTapRegion(
      child: Padding(
        padding: const EdgeInsets.only(right: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
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
              },
            if (overflow.isNotEmpty)
              overflow.contains(_HeaderAction.review)
                  ? reviewHost(folded: true)
                  : more(false, null),
            SizedBox(
              height: 44,
              child: Align(
                widthFactor: 1,
                child: FilledButton(
                  key: const ValueKey('composer-header-submit'),
                  onPressed: submitting ? null : onSubmit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 36),
                    visualDensity: VisualDensity.standard,
                    tapTargetSize: MaterialTapTargetSize.padded,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    shape: const StadiumBorder(),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Opacity(
                        opacity: submitting ? 0 : 1,
                        alwaysIncludeSemantics: true,
                        child: Text(submitLabel),
                      ),
                      if (submitting)
                        const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
