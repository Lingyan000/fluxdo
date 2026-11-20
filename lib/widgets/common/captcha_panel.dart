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
    title: title,
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
  });

  final CaptchaPanelPhase phase;
  final String message;
  final Widget? child;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final interactive =
        phase == CaptchaPanelPhase.checkbox ||
        phase == CaptchaPanelPhase.challenge;
    final failed = phase == CaptchaPanelPhase.failed;
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, bounds) {
        final height = math.min(
          bounds.maxHeight,
          phase == CaptchaPanelPhase.challenge ? 640.0 : 220.0,
        );
        return SizedBox(
          width: double.infinity,
          height: height,
          child: Column(
            children: [
              if (interactive)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: height * 0.3),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(message, style: theme.textTheme.bodyMedium),
                    ),
                  ),
                ),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (child != null)
                      ExcludeFocus(
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
                    if (!interactive)
                      Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (failed)
                                Icon(
                                  Symbols.error_outline_rounded,
                                  color: theme.colorScheme.error,
                                )
                              else
                                const LoadingSpinner(size: 32),
                              const SizedBox(height: 12),
                              Semantics(
                                liveRegion: true,
                                child: Text(
                                  message,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                              if (failed && onRetry != null) ...[
                                const SizedBox(height: 12),
                                FilledButton.tonal(
                                  onPressed: onRetry,
                                  child: Text(context.l10n.common_retry),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
