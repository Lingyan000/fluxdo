import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import 'mini_app.dart';
import 'mini_app_card_surface.dart';
import 'mini_app_icon.dart';
import 'mini_app_identity.dart';

class MiniAppPermissionRequest {
  const MiniAppPermissionRequest({
    required this.signature,
    required this.title,
    required this.action,
    required this.notice,
    required this.reject,
    required this.allow,
  });
  final String signature, title, action, notice, reject, allow;

  static MiniAppPermissionRequest? parse(Object? value) {
    if (value is! Map) return null;
    const keys = ['signature', 'title', 'action', 'notice', 'reject', 'allow'];
    if (keys.any((key) => value[key] is! String)) return null;
    if ((value['signature'] as String).isEmpty ||
        (value['action'] as String).trim().isEmpty ||
        (value['reject'] as String).trim().isEmpty ||
        (value['allow'] as String).trim().isEmpty) {
      return null;
    }
    return MiniAppPermissionRequest(
      signature: value['signature'],
      title: value['title'],
      action: value['action'],
      notice: value['notice'],
      reject: value['reject'],
      allow: value['allow'],
    );
  }
}

/// 网页文档进度和应用包进度含义不同；这里只展示宿主报告的阶段与进度。
class MiniAppLaunchSurface extends StatelessWidget {
  const MiniAppLaunchSurface({
    super.key,
    required this.app,
    this.stage = '',
    this.detail = '',
    this.progress,
    this.failed = false,
    this.onRetry,
    this.onUseWebEngine,
  });
  final MiniApp app;
  final String stage, detail;
  final double? progress;
  final bool failed;
  final VoidCallback? onRetry;
  final VoidCallback? onUseWebEngine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l = context.l10n;
    return ColoredBox(
      color: colors.surface,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 400),
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 104,
                      child: SegmentedCardItem(
                        index: 0,
                        count: 1,
                        outerRadius: 30,
                        child: MiniAppCardSurface(
                          app: app,
                          prominent: true,
                          watermark: false,
                          child: Center(child: MiniAppIcon(app, size: 72)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      app.name,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      failed
                          ? l.miniApp_launchFailed
                          : l.miniApp_launchPreparing,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 28),
                    if (!failed) ...[
                      SizedBox(
                        width: 220,
                        child: M3eLinearProgress(value: progress),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (stage.isNotEmpty)
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          stage,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: failed ? colors.error : colors.primary,
                          ),
                        ),
                      ),
                    if (detail.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        detail,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (failed) ...[
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Symbols.refresh_rounded),
                        label: Text(l.miniApp_retry),
                      ),
                      if (onUseWebEngine != null)
                        TextButton(
                          onPressed: onUseWebEngine,
                          child: Text(l.miniApp_engineFallback),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 只呈现已核对的宿主提示，按钮文案和用途完全来自当前官方请求。
class MiniAppPermissionSurface extends StatelessWidget {
  const MiniAppPermissionSurface({
    super.key,
    required this.app,
    required this.request,
    required this.onAnswer,
    this.busy = false,
  });
  final MiniApp app;
  final MiniAppPermissionRequest request;
  final ValueChanged<bool> onAnswer;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).height < 500;
    final allowButton = FilledButton(
      key: const ValueKey('mini-app-permission-allow'),
      onPressed: busy ? null : () => onAnswer(true),
      child: Text(request.allow, textAlign: TextAlign.center),
    );
    final rejectButton = TextButton(
      key: const ValueKey('mini-app-permission-reject'),
      autofocus: true,
      onPressed: busy ? null : () => onAnswer(false),
      child: Text(request.reject, textAlign: TextAlign.center),
    );
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: request.title,
      child: ColoredBox(
        color: colors.scrim.withValues(alpha: .35),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: compact ? 720 : 480),
            child: MediaQuery.removeViewInsets(
              context: context,
              removeBottom: true,
              child: AppSheetScaffold(
                style: AppSheetStyle.card,
                titleWidget: MiniAppIdentity(app: app, compact: compact),
                showCloseButton: false,
                contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                footer: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: compact
                      ? Row(
                          children: [
                            Expanded(child: rejectButton),
                            const SizedBox(width: 12),
                            Expanded(child: allowButton),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            allowButton,
                            const SizedBox(height: 8),
                            rejectButton,
                          ],
                        ),
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!compact)
                          Icon(
                            Symbols.shield_rounded,
                            size: 36,
                            color: colors.primary,
                          ),
                        if (!compact) const SizedBox(height: 16),
                        Text(
                          request.action,
                          style: compact
                              ? theme.textTheme.titleMedium
                              : theme.textTheme.headlineSmall,
                        ),
                        if (request.notice.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            request.notice,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (!compact) const SizedBox(height: 20),
                        if (!compact)
                          Text(
                            context.l10n.miniApp_permissionChoice,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
