import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/responsive.dart';
import 'skeleton.dart';

/// 手机贴底，宽屏居中。关闭只结束本次验证所在的路由。
Future<T?> showCaptchaSheet<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = false,
  ValueListenable<bool>? challengeExpanded,
  VoidCallback? onDisposed,
}) {
  final compact = MediaQuery.sizeOf(context).width < Breakpoints.mobile;
  Widget shell(BuildContext context) => AppSheetScaffold(
    titleWidget: Row(
      children: [
        Icon(
          Symbols.verified_user_rounded,
          size: 22,
          color: context.emphasis.accent,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
    style: AppSheetStyle.card,
    showDragHandle: compact,
    borderRadius: compact ? null : context.shapes.borderRadius(24),
    maxHeightFactor: 0.95,
    contentPadding: EdgeInsets.zero,
    child: Builder(builder: builder),
  );
  if (compact) {
    return showAppBottomSheet<T>(
      context: context,
      builder: shell,
      useRootNavigator: useRootNavigator,
      isScrollControlled: true,
      isDismissible: barrierDismissible,
      enableDrag: false,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      onDisposed: onDisposed,
    );
  }
  return showAppDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: barrierDismissible,
    onDisposed: onDisposed,
    builder: (context) => Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: challengeExpanded == null
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: shell(context),
              )
            : ValueListenableBuilder<bool>(
                valueListenable: challengeExpanded,
                child: shell(context),
                builder: (_, expanded, child) => ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: expanded ? 560 : 368),
                  child: child,
                ),
              ),
      ),
    ),
  );
}

enum CaptchaPanelPhase { loading, checkbox, challenge, submitting, failed }

/// 只负责呈现状态，调用方持有验证会话。切换阶段时保留同一个平台视图。
class CaptchaPanel extends StatelessWidget {
  const CaptchaPanel({
    super.key,
    required this.phase,
    required this.message,
    this.child,
    this.onRetry,
    this.contentHeight,
    this.expectsCheckbox = false,
  });

  final CaptchaPanelPhase phase;
  final String message;
  final Widget? child;
  final VoidCallback? onRetry;

  /// 可见勾选控件预留同尺寸骨架，直接打开题目的流程显示其准备提示。
  final bool expectsCheckbox;

  /// 当前控件在网页内实际占用的逻辑高度，未知时按可用宽度布局。
  final double? contentHeight;

  /// 横版勾选控件的宽度（含边框）。留白优先让给控件本身。
  static const double normalCheckboxWidth = 304;
  static const _normalCheckbox = Size(302, 76);
  static const _compactCheckbox = Size(158, 138);

  @override
  Widget build(BuildContext context) {
    final interactive =
        phase == CaptchaPanelPhase.checkbox ||
        phase == CaptchaPanelPhase.challenge;
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, bounds) {
        final gutter = bounds.maxWidth < normalCheckboxWidth
            ? 8.0
            : ((bounds.maxWidth - normalCheckboxWidth) / 2).clamp(0.0, 16.0);
        final width = bounds.maxWidth - 2 * gutter;
        final measured = contentHeight;
        final challenge = phase == CaptchaPanelPhase.challenge;
        final compact = width < normalCheckboxWidth;
        final checkbox = compact ? _compactCheckbox : _normalCheckbox;
        final double height;
        final known = measured != null && measured.isFinite && measured > 0;
        if (challenge) {
          height = known
              ? measured + 24
              : (width * 1.35 + 24).clamp(340.0, 580.0);
        } else {
          // 给控件边框及基线差异留余量，常见实测高度落在同一个占位内。
          final reserved = checkbox.height + 8;
          height = math.max(reserved, known ? measured : 0.0) + 12;
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 16),
          child: ClipRRect(
            borderRadius: context.shapes.borderRadius(challenge ? 16 : 8),
            child: SingleChildScrollView(
              primary: false,
              child: Stack(
                children: [
                  if (interactive ||
                      (expectsCheckbox && phase != CaptchaPanelPhase.failed))
                    Semantics(
                      liveRegion: true,
                      label: message,
                      child: SizedBox(
                        width: double.infinity,
                        height: math.min(
                          height,
                          MediaQuery.sizeOf(context).longestSide * 2,
                        ),
                        child: phase == CaptchaPanelPhase.loading
                            ? Center(
                                child: _CheckboxSkeleton(
                                  size: checkbox,
                                  compact: compact,
                                ),
                              )
                            : null,
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          if (phase == CaptchaPanelPhase.failed)
                            Icon(
                              Symbols.error_outline_rounded,
                              color: theme.colorScheme.error,
                            )
                          else
                            const LoadingSpinner(size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                message,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          ),
                          if (phase == CaptchaPanelPhase.failed &&
                              onRetry != null)
                            TextButton(
                              onPressed: onRetry,
                              child: Text(context.l10n.common_retry),
                            ),
                        ],
                      ),
                    ),
                  if (child != null)
                    Positioned.fill(
                      child: ExcludeFocus(
                        excluding: !interactive,
                        child: ExcludeSemantics(
                          excluding: !interactive,
                          child: IgnorePointer(
                            ignoring: !interactive,
                            child: Opacity(
                              opacity: interactive ? 1 : 0,
                              child: child,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CheckboxSkeleton extends StatelessWidget {
  const _CheckboxSkeleton({required this.size, required this.compact});

  final Size size;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = scheme.onSurfaceVariant.withValues(alpha: 0.15);
    final check = SkeletonBox(width: 27, height: 27, color: tint);
    final caption = Flexible(
      child: SkeletonBox(width: 82, height: 10, color: tint),
    );
    final provider = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SkeletonBox(width: 24, height: 24, borderRadius: 6, color: tint),
        const SizedBox(height: 5),
        SkeletonBox(width: 34, height: 5, color: tint),
      ],
    );
    final label = Row(
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      children: [
        check,
        const SizedBox(width: 10),
        caption,
        if (!compact) ...[const Spacer(), provider],
      ],
    );
    final shapes = compact
        ? Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [label, provider],
          )
        : label;
    final still =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context);
    return ExcludeSemantics(
      child: Container(
        width: size.width,
        height: size.height,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: ShapeDecoration(
          color: scheme.surfaceContainerLow,
          shape: RoundedSuperellipseBorder(
            borderRadius: context.shapes.borderRadius(6),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        child: still ? shapes : Skeleton(repeat: false, child: shapes),
      ),
    );
  }
}
