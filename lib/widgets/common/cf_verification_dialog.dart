import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/s.dart';
import '../../services/cf_verification_state.dart';
import 'cf_startup_verification.dart';
import 'cloudflare_mark.dart';

enum CfVerificationDialogSection { verification, help, confirmExit }

/// 业务页面共用的居中弹框。等待、操作、帮助和退出都在同一个表面内切换。
class CfVerificationDialog extends StatelessWidget {
  const CfVerificationDialog({
    super.key,
    required this.bounds,
    required this.barrier,
    required this.webView,
    required this.showPage,
    required this.verification,
    required this.section,
    required this.onSectionChanged,
    required this.onReload,
    required this.onExit,
    this.entryAnchor,
  });

  final Rect bounds;
  final Widget barrier;
  final Widget webView;
  final bool showPage;
  final CfVerificationState verification;
  final CfVerificationDialogSection section;
  final ValueChanged<CfVerificationDialogSection> onSectionChanged;
  final VoidCallback? onReload;
  final VoidCallback onExit;
  final Rect? entryAnchor;

  static double _barHeight(BuildContext context, double height) => math.min(
    height * 0.2,
    math.max(56.0, MediaQuery.textScalerOf(context).scale(16) * 1.5 + 16),
  );
  bool get _verifying => section == CfVerificationDialogSection.verification;
  bool get _retrySuggested => switch (verification.stage) {
    CfVerificationStage.widgetError ||
    CfVerificationStage.loadFailed ||
    CfVerificationStage.interactionExpired ||
    CfVerificationStage.timedOut ||
    CfVerificationStage.unconfirmed => true,
    _ => false,
  };

  String _title(BuildContext context) => switch (section) {
    CfVerificationDialogSection.help => context.l10n.cf_helpTitle,
    CfVerificationDialogSection.confirmExit =>
      context.l10n.cf_abandonVerifyTitle,
    _ =>
      verification.stage == CfVerificationStage.checking &&
              verification.interactionRequested
          ? context.l10n.cf_panelCheckingResult
          : verification.label(context.l10n),
  };

  Widget _indicator(BuildContext context, double size) {
    final icon = switch (section) {
      CfVerificationDialogSection.help => Symbols.help_outline_rounded,
      CfVerificationDialogSection.confirmExit => Symbols.logout_rounded,
      _ => switch (verification.stage) {
        CfVerificationStage.interactionRequired => Symbols.touch_app_rounded,
        CfVerificationStage.widgetError ||
        CfVerificationStage.loadFailed => Symbols.error_outline_rounded,
        CfVerificationStage.timedOut ||
        CfVerificationStage.interactionExpired => Symbols.schedule_rounded,
        CfVerificationStage.unconfirmed => Symbols.help_outline_rounded,
        CfVerificationStage.noChallengeObserved ||
        CfVerificationStage.challengeCleared => Symbols.check_rounded,
        CfVerificationStage.cancelled => Symbols.close_rounded,
        _ => null,
      },
    };
    final scheme = Theme.of(context).colorScheme;
    final color =
        _verifying &&
            (verification.stage == CfVerificationStage.widgetError ||
                verification.stage == CfVerificationStage.loadFailed)
        ? scheme.error
        : scheme.onSurfaceVariant;
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context);
    return ExcludeSemantics(
      child: icon != null || reduceMotion
          ? Icon(
              icon ?? Symbols.hourglass_empty_rounded,
              color: color,
              size: size,
            )
          : LoadingSpinner(size: size, color: context.emphasis.accent),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 20, end: 8),
      child: Row(
        children: [
          const ExcludeSemantics(child: CloudflareMark(width: 30)),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                context.l10n.cfVerify_title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (_verifying)
            IconButton(
              tooltip: context.l10n.common_exit,
              onPressed: () =>
                  onSectionChanged(CfVerificationDialogSection.confirmExit),
              icon: const Icon(Symbols.close_rounded, size: 20),
            ),
        ],
      ),
    );
  }

  Widget _message(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final help = section == CfVerificationDialogSection.help;
    return Center(
      child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: ShapeDecoration(
                shape: context.shapes.circle(),
                color: theme.colorScheme.surfaceContainerHigh,
              ),
              child: SizedBox.square(
                dimension: 52,
                child: Center(child: _indicator(context, 26)),
              ),
            ),
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Text(
                _title(context),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              help ? l10n.cf_helpContent : l10n.cf_abandonVerifyMessage,
              textAlign: help ? TextAlign.start : TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _notice(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            _indicator(context, 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(_title(context), style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }

  Widget _waitingState(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final checking =
        verification.stage == CfVerificationStage.opening ||
        verification.stage == CfVerificationStage.checking;
    final motion =
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.reduceMotionOf(context);
    final hint = switch (verification.stage) {
      CfVerificationStage.checking when !verification.interactionRequested =>
        l10n.cf_panelCheckingHint,
      CfVerificationStage.opening ||
      CfVerificationStage.checking ||
      CfVerificationStage.interactionRequired => l10n.cf_verifyOpeningMessage,
      CfVerificationStage.timedOut => l10n.cf_verifyTimedOutMessage,
      CfVerificationStage.unconfirmed ||
      CfVerificationStage.interactionExpired ||
      CfVerificationStage.loadFailed ||
      CfVerificationStage.widgetError => l10n.cf_panelRetryHint,
      CfVerificationStage.noChallengeObserved => l10n.cf_noChallengeMessage,
      CfVerificationStage.challengeCleared => l10n.cf_verifyCompletingMessage,
      CfVerificationStage.cancelled => null,
    };
    return Semantics(
      liveRegion: true,
      child: AppEmptyState(
        animate: false,
        icon: ExcludeSemantics(
          child: SizedBox.square(
            dimension: 88,
            child: Stack(
              alignment: Alignment.center,
              children: [
                DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: context.shapes.circle(),
                    color: checking
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHigh,
                  ),
                  child: SizedBox.square(
                    dimension: 70,
                    child: Center(
                      child: checking
                          ? Icon(
                              Symbols.shield_rounded,
                              size: 34,
                              color: scheme.onPrimaryContainer,
                            )
                          : _indicator(context, 34),
                    ),
                  ),
                ),
                if (checking && motion)
                  M3eCircularProgress(
                    size: 88,
                    strokeWidth: 3,
                    color: context.emphasis.accent,
                    trackColor: scheme.surfaceContainerHighest,
                  ),
              ],
            ),
          ),
        ),
        title: _title(context),
        message: hint,
      ),
    );
  }

  Widget _body(BuildContext context) {
    final visible = _verifying && showPage;
    return Stack(
      fit: StackFit.expand,
      children: [
        Column(
          children: [
            if (visible)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: bounds.height * .38),
                child: SingleChildScrollView(
                  primary: false,
                  child: _notice(context),
                ),
              ),
            Expanded(
              child: CfVerificationWebView(
                visible: visible,
                loadingBackground: Theme.of(context).colorScheme.surface,
                child: webView,
              ),
            ),
          ],
        ),
        if (!_verifying)
          _message(context)
        else if (!showPage)
          _waitingState(context),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    final l10n = context.l10n;
    void back() => onSectionChanged(CfVerificationDialogSection.verification);
    final children = switch (section) {
      CfVerificationDialogSection.help => <Widget>[
        FilledButton.tonal(onPressed: back, child: Text(l10n.common_gotIt)),
      ],
      CfVerificationDialogSection.confirmExit => <Widget>[
        TextButton(onPressed: onExit, child: Text(l10n.common_exit)),
        FilledButton.tonal(
          onPressed: back,
          child: Text(l10n.cf_continueVerify),
        ),
      ],
      CfVerificationDialogSection.verification => <Widget>[
        Tooltip(
          message: l10n.common_help,
          child: TextButton.icon(
            onPressed: () => onSectionChanged(CfVerificationDialogSection.help),
            icon: const Icon(Symbols.help_outline_rounded, size: 18),
            label: Text(l10n.common_help),
          ),
        ),
        if (onReload != null)
          Tooltip(
            message: l10n.common_refresh,
            child: _retrySuggested
                ? FilledButton.tonalIcon(
                    onPressed: onReload,
                    icon: const Icon(Symbols.refresh_rounded, size: 18),
                    label: Text(l10n.cf_retryVerify),
                  )
                : TextButton.icon(
                    onPressed: onReload,
                    icon: const Icon(Symbols.refresh_rounded, size: 18),
                    label: Text(l10n.cf_retryVerify),
                  ),
          ),
      ],
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        // 极窄或放大字号时，操作仍可滚动到达，不会盖到网页上。
        return SingleChildScrollView(
          primary: false,
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: children.length == 1
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.spaceBetween,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bar = _barHeight(context, bounds.height);
    final panel = Material(
      elevation: 5,
      color: scheme.surface,
      shadowColor: scheme.shadow.withValues(alpha: 0.35),
      // macOS 会按 Flutter 前景绘制的外接矩形屏蔽原生视图的点击。
      // 描边要画在 WebView 下方，否则整个网页都会被挡住。
      borderOnForeground: false,
      shape: RoundedSuperellipseBorder(
        borderRadius: context.shapes.borderRadius(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.65)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SizedBox(height: bar, child: _header(context)),
          Expanded(child: _body(context)),
          SizedBox(height: bar, child: _actions(context)),
        ],
      ),
    );
    final from = entryAnchor;
    if (from != null) {
      return CfVerificationPanelReveal(
        from: from,
        bounds: bounds,
        barrier: barrier,
        child: panel,
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: barrier),
        Positioned.fromRect(rect: bounds, child: panel),
      ],
    );
  }
}
