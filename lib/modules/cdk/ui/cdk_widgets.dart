import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../models/cdk_user_info.dart';
import '../../../pages/webview_page.dart';
import '../../../providers/cdk_providers.dart';
import '../../../services/network/exceptions/oauth_exception.dart';
import '../../../services/toast_service.dart';
import '../providers/cdk_providers.dart';
import '../services/cdk_client.dart';
import 'cdk_project_widgets.dart';

String cdkErrorText(BuildContext context, Object? error) {
  if (error is OAuthExpiredException) return context.l10n.common_authExpired;
  if (OAuthErrorPolicy.isCfChallenge(error)) {
    return context.l10n.error_securityChallenge;
  }
  if (error is CdkApiException && !error.message.startsWith('cdk_')) {
    return error.message;
  }
  return context.l10n.common_loadFailed;
}

class CdkSessionGate extends ConsumerWidget {
  const CdkSessionGate({super.key, required this.builder});
  final Widget Function(CdkClient client) builder;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(cdkClientProvider)
      .when(
        skipLoadingOnRefresh: false,
        data: (client) =>
            KeyedSubtree(key: ObjectKey(client), child: builder(client)),
        loading: () => const Center(child: LoadingSpinner()),
        error: (error, _) => CdkError(
          error: error,
          retry: () => ref.invalidate(cdkClientProvider),
        ),
      );
}

/// 根层弹框独立于页面子树，业务会话结束时同步撤下内容。
class CdkSessionContent extends StatelessWidget {
  const CdkSessionContent({
    super.key,
    required this.client,
    required this.builder,
  });
  final CdkClient client;
  final WidgetBuilder builder;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: client.active,
    builder: (context, active, _) => active
        ? builder(context)
        : Padding(
            padding: const EdgeInsets.all(24),
            child: Text(context.l10n.common_authExpired),
          ),
  );
}

class CdkError extends ConsumerStatefulWidget {
  const CdkError({super.key, required this.error, required this.retry});
  final Object? error;
  final FutureOr<void> Function() retry;
  @override
  ConsumerState<CdkError> createState() => _CdkErrorState();
}

class _CdkErrorState extends ConsumerState<CdkError> {
  bool _busy = false;
  Future<void> _retry() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (widget.error is OAuthExpiredException) {
        if (!await ref.read(cdkOAuthServiceProvider).authorize(context)) return;
        if (!mounted) return;
        await ref.read(cdkUserInfoProvider.notifier).refresh();
        if (!mounted) return;
        ref.invalidate(cdkClientProvider);
      } else {
        await widget.retry();
      }
    } catch (error) {
      if (mounted) ToastService.showError(cdkErrorText(context, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: AppEmptyState(
        icon: const Icon(Symbols.error_outline_rounded),
        title: cdkErrorText(context, widget.error),
        action: OAuthErrorPolicy.isCfChallenge(widget.error)
            ? Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: _busy
                        ? null
                        : () => WebViewPage.open<void>(
                            context,
                            '${CdkClient.origin}/dashboard',
                          ),
                    child: Text(context.l10n.cdk_openWebsite),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _retry,
                    child: _busy
                        ? const LoadingSpinner(size: 20)
                        : Text(context.l10n.common_retry),
                  ),
                ],
              )
            : FilledButton.tonal(
                onPressed: _busy ? null : _retry,
                child: _busy
                    ? const LoadingSpinner(size: 20)
                    : Text(
                        widget.error is OAuthExpiredException
                            ? context.l10n.common_reAuth
                            : context.l10n.common_retry,
                      ),
              ),
      ),
    ),
  );
}

class CdkMetrics extends StatelessWidget {
  const CdkMetrics({super.key, required this.values});
  final List<(String, String)> values;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final (label, value) in values)
          SizedBox(
            width: (box.maxWidth - 12) / 2,
            child: SegmentedCardItem(
              index: 0,
              count: 1,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 10),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class CdkAccountCard extends StatelessWidget {
  const CdkAccountCard({super.key, required this.account});
  final CdkUserInfo account;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return Material(
      color: cs.tertiaryContainer,
      shape: RoundedSuperellipseBorder(
        borderRadius: context.shapes.borderRadius(28),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: cs.onTertiaryContainer),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '@${account.username}',
                style: t.textTheme.labelLarge?.copyWith(
                  color: cs.onTertiaryContainer,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 36,
                runSpacing: 16,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${account.score}',
                        style: t.textTheme.displayMedium?.copyWith(
                          color: cs.onTertiaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(context.l10n.cdk_balance),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Lv.${account.trustLevel}',
                        style: t.textTheme.headlineSmall?.copyWith(
                          color: cs.onTertiaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(context.l10n.cdk_requiredTrust),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 20),
              CdkPerforation(
                color: cs.onTertiaryContainer.withValues(alpha: 0.3),
              ),
              const SizedBox(height: 16),
              Text(
                context.l10n.cdk_scoreHint,
                style: t.textTheme.bodySmall?.copyWith(
                  color: cs.onTertiaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 兑换内容只留在页面内存中；复制由用户触发，切后台后重新遮蔽。
class CdkSecretContent extends StatefulWidget {
  const CdkSecretContent({super.key, required this.content});
  final String content;
  @override
  State<CdkSecretContent> createState() => _CdkSecretContentState();
}

class _CdkSecretContentState extends State<CdkSecretContent> {
  bool _revealed = false;
  late final _lifecycle = AppLifecycleListener(
    onInactive: _hide,
    onHide: _hide,
  );
  void _hide() {
    if (mounted) setState(() => _revealed = false);
  }

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void didUpdateWidget(CdkSecretContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) _revealed = false;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SegmentedCardGroup(
    children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Symbols.key_rounded, color: context.emphasis.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    context.l10n.cdk_receivedContent,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            CdkPerforation(color: Theme.of(context).colorScheme.outlineVariant),
            const SizedBox(height: 20),
            if (_revealed)
              SelectableText(
                widget.content.replaceAll('\$\n*', '\n\n'),
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(fontFamily: 'monospace', height: 1.6),
              )
            else ...[
              const ExcludeSemantics(
                child: Text(
                  '••••  ••••  ••••',
                  style: TextStyle(letterSpacing: 3),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.cdk_contentHidden,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Tooltip(
                  message: _revealed
                      ? context.l10n.cdk_hideContent
                      : context.l10n.cdk_showContent,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _revealed = !_revealed),
                    label: Text(
                      _revealed
                          ? context.l10n.cdk_hideContent
                          : context.l10n.cdk_showContent,
                    ),
                    icon: Icon(
                      _revealed
                          ? Symbols.visibility_off_rounded
                          : Symbols.visibility_rounded,
                    ),
                  ),
                ),
                TextButton.icon(
                  label: Text(context.l10n.common_copy),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: widget.content),
                    );
                    if (context.mounted) {
                      ToastService.showSuccess(
                        context.l10n.common_copiedToClipboard,
                      );
                    }
                  },
                  icon: const Icon(Symbols.content_copy_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}
