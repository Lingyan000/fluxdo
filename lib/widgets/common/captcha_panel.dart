import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/responsive.dart';

/// 手机贴底，宽屏居中。关闭只结束本次验证所在的路由。
Future<T?> showCaptchaSheet<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = false,
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
    );
  }
  return showAppDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: barrierDismissible,
    builder: (context) => Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: shell(context),
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
  });

  final CaptchaPanelPhase phase;
  final String message;
  final Widget? child;
  final VoidCallback? onRetry;

  /// 当前控件在网页内实际占用的逻辑高度，未知时按可用宽度布局。
  final double? contentHeight;

  /// 横版勾选控件的宽度（含边框）。留白优先让给控件本身。
  static const double normalCheckboxWidth = 304;

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
        final double height;
        if (measured != null && measured.isFinite && measured > 0) {
          height = measured + (challenge ? 24 : 12);
        } else if (challenge) {
          height = (width * 1.35 + 24).clamp(340.0, 580.0);
        } else {
          height = width >= normalCheckboxWidth ? 92 : 158;
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 16),
          child: ClipRRect(
            borderRadius: context.shapes.borderRadius(challenge ? 16 : 8),
            child: SingleChildScrollView(
              primary: false,
              child: Stack(
                children: [
                  if (interactive)
                    Semantics(
                      liveRegion: true,
                      label: message,
                      child: SizedBox(
                        width: double.infinity,
                        height: math.min(
                          height,
                          MediaQuery.sizeOf(context).longestSide * 2,
                        ),
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
