import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../providers/core_providers.dart';
import '../../../providers/secret_store_provider.dart';
import '../../../providers/theme_provider.dart';
import '../../../utils/dialog_utils.dart';
import '../../../utils/link_launcher.dart';
import '../../../utils/time_utils.dart';
import '../../ldc_payment/ldc_payment_flow.dart';
import '../models/cdk_models.dart';
import '../services/cdk_client.dart';
import '../services/cdk_redemption.dart';
import 'cdk_verification_sheet.dart';
import 'cdk_widgets.dart';

class CdkProjectPage extends StatelessWidget {
  const CdkProjectPage({super.key, required this.projectId});
  final String projectId;
  static Future<void> open(BuildContext context, String id) =>
      Navigator.of(context).push(
        InteractionPageRoute<void>(
          builder: (_) => CdkProjectPage(projectId: id),
        ),
      );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.l10n.cdk_projectDetail),
      actions: [
        IconButton(
          tooltip: context.l10n.cdk_openWebsite,
          onPressed: () => launchExternalLink(
            context,
            '${CdkClient.origin}/receive/${Uri.encodeComponent(projectId)}',
            mode: LinkOpenMode.inApp,
          ),
          icon: const Icon(Symbols.open_in_browser_rounded),
        ),
      ],
    ),
    body: CdkSessionGate(
      builder: (client) =>
          CdkProjectContent(client: client, projectId: projectId),
    ),
  );
}

class CdkProjectContent extends ConsumerStatefulWidget {
  const CdkProjectContent({
    super.key,
    required this.client,
    required this.projectId,
    this.verify,
    this.pay,
  });
  final CdkClient client;
  final String projectId;
  final Future<String?> Function()? verify;
  final Future<Map<String, Object?>?> Function(CdkPaymentIntent)? pay;
  @override
  ConsumerState<CdkProjectContent> createState() => _CdkProjectContentState();
}

class _CdkProjectContentState extends ConsumerState<CdkProjectContent> {
  late final _redemption = CdkRedemption(widget.client, widget.projectId);
  Timer? _poll;
  bool _busy = false, _foreground = true;
  int _attempts = 0;
  Object? _flowError;
  late final _lifecycle = AppLifecycleListener(
    onStateChange: (state) {
      _foreground = state == AppLifecycleState.resumed;
      if (!_foreground) _poll?.cancel();
    },
  );
  @override
  void initState() {
    super.initState();
    _lifecycle;
    unawaited(_redemption.load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _lifecycle.dispose();
    _redemption.dispose();
    super.dispose();
  }

  Future<void> _receive() async {
    if (_busy || !_redemption.canReceive) return;
    setState(() {
      _busy = true;
      _flowError = null;
    });
    try {
      final p = _redemption.project!;
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            p.paid ? ctx.l10n.cdk_confirmPaid : ctx.l10n.cdk_confirmReceive,
          ),
          content: Text(
            p.paid
                ? ctx.l10n.cdk_paidHint(p.name, p.price)
                : ctx.l10n.cdk_freeHint(p.name),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(ctx.l10n.common_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ctx.l10n.common_confirm),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      final token =
          await (widget.verify?.call() ??
              showCdkVerification(context, widget.client, widget.projectId));
      if (!mounted || token == null) return;
      await _redemption.receive(token);
      if (!mounted) return;
      if (_redemption.payment != null) await _pay(_redemption.payment!);
      if (_redemption.uncertain) await _redemption.load();
    } catch (error) {
      if (mounted) setState(() => _flowError = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continuePayment() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _flowError = null;
    });
    try {
      // 继续付款先重查原单，库存不足时也不再调用领取接口。
      await _redemption.load();
      if (mounted && _redemption.error == null && _redemption.payment != null) {
        await _pay(_redemption.payment!);
      }
    } catch (error) {
      if (mounted) setState(() => _flowError = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pay(CdkPaymentIntent intent) async {
    final Map<String, Object?>? result;
    if (widget.pay != null) {
      result = await widget.pay!(intent);
    } else {
      final account = ref.read(currentUserProvider).value;
      if (account == null) return;
      result = await requestLdcPayment(
        context,
        url: intent.url,
        reference: intent.reference,
        amount: intent.amount,
        accountId: account.id,
        username: account.username,
        secretStore: ref.read(secretStoreProvider),
        preferences: ref.read(sharedPreferencesProvider),
        checkSession: () async {
          await widget.client.check();
          if (!mounted ||
              ref.read(currentUserProvider).value?.id != account.id) {
            throw const CdkApiException('cdk_session_changed');
          }
        },
      );
    }
    if (!mounted || result == null) return;
    _redemption.markPaymentSubmitted();
    _attempts = 0;
    await _checkDelivery();
  }

  Future<void> _checkDelivery() async {
    _poll?.cancel();
    if (!mounted ||
        !_foreground ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    await _redemption.load();
    if (!mounted ||
        !_foreground ||
        _redemption.delivered ||
        ++_attempts >= 15 ||
        _redemption.error != null) {
      return;
    }
    _poll = Timer(
      const Duration(seconds: 2),
      () => unawaited(_checkDelivery()),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _redemption,
    builder: (context, _) {
      final r = _redemption;
      final p = r.project;
      final l = context.l10n;
      if (p == null) {
        return r.loading
            ? const Center(child: LoadingSpinner())
            : CdkError(error: r.error, retry: r.load);
      }
      final message = r.delivered
          ? l.cdk_received
          : r.paymentSubmitted
          ? l.cdk_waitingDelivery
          : r.uncertain
          ? l.cdk_receiveUncertain
          : r.payment != null
          ? l.cdk_pendingPayment
          : !p.openNow
          ? l.cdk_outsideWindow
          : p.available == 0
          ? l.cdk_noStock
          : null;
      return Column(
        children: [
          Expanded(
            child: M3eRefreshIndicator(
              onRefresh: r.load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (r.loading) const M3eLinearProgress(),
                  Text(
                    p.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  if (p.creator.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('@${p.creator}'),
                    ),
                  if (p.tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final tag in p.tags) Chip(label: Text(tag)),
                        ],
                      ),
                    ),
                  CdkMetrics(
                    values: [
                      (l.cdk_price, p.paid ? '${p.price} LDC' : l.cdk_free),
                      (l.cdk_stock, '${p.available ?? '—'} / ${p.total}'),
                      (l.cdk_requiredTrust, 'Lv.${p.trustLevel}'),
                      (l.cdk_requiredScore, '${p.minimumScore}'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SegmentedCardGroup(
                    children: [
                      ListTile(
                        title: Text(l.cdk_start),
                        subtitle: Text(TimeUtils.formatDetailTime(p.start)),
                      ),
                      ListTile(
                        title: Text(l.cdk_end),
                        subtitle: Text(TimeUtils.formatDetailTime(p.end)),
                      ),
                      ListTile(
                        title: Text(l.cdk_distribution),
                        subtitle: Text(switch (p.distribution) {
                          0 => l.cdk_oneEach,
                          1 => l.cdk_lottery,
                          2 => l.cdk_invitation,
                          _ => l.cdk_distribution,
                        }),
                      ),
                      if (!p.allowSameIp)
                        ListTile(title: Text(l.cdk_sameIpLimit)),
                    ],
                  ),
                  if (p.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: SelectableText(
                        p.description,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  if (message != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        message,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  if (r.delivered)
                    CdkSecretContent(content: r.content ?? p.content),
                  if (r.error != null || _flowError != null)
                    CdkError(
                      error: _flowError ?? r.error,
                      retry: () async {
                        setState(() => _flowError = null);
                        await r.load();
                      },
                    ),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  IconButton(
                    tooltip: l.common_refresh,
                    onPressed: _busy || r.loading
                        ? null
                        : () {
                            _poll?.cancel();
                            setState(() => _flowError = null);
                            unawaited(r.load());
                          },
                    icon: const Icon(Symbols.refresh_rounded),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed:
                          _busy ||
                              r.loading ||
                              r.delivered ||
                              r.paymentSubmitted
                          ? null
                          : r.payment != null
                          ? _continuePayment
                          : r.canReceive
                          ? _receive
                          : null,
                      child: _busy
                          ? const LoadingSpinner(size: 20)
                          : Text(
                              r.delivered
                                  ? l.cdk_received
                                  : r.payment != null
                                  ? l.cdk_continuePayment
                                  : p.paid
                                  ? l.cdk_payAndReceive(p.price)
                                  : l.cdk_receive,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}
