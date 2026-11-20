import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../providers/cdk_providers.dart';
import '../../../providers/core_providers.dart';
import '../../../providers/secret_store_provider.dart';
import '../../../providers/theme_provider.dart';
import '../../../utils/link_launcher.dart';
import '../../../utils/time_utils.dart';
import '../../ldc_payment/ldc_payment_flow.dart';
import '../models/cdk_models.dart';
import '../services/cdk_client.dart';
import '../services/cdk_redemption.dart';
import 'cdk_verification_sheet.dart';
import 'cdk_project_widgets.dart';
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
      final token = await showCdkVerification(
        context,
        widget.client,
        p,
        verify: widget.verify,
      );
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
      final account = ref.watch(cdkUserInfoProvider).value;
      if (p == null) {
        return r.loading
            ? const Center(child: LoadingSpinner())
            : CdkError(error: r.error, retry: r.load);
      }
      final eligible =
          account == null ||
          (account.trustLevel >= p.trustLevel &&
              account.score >= p.minimumScore);
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
          : !eligible
          ? l.cdk_notEligible
          : null;
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            children: [
              Expanded(
                child: M3eRefreshIndicator(
                  onRefresh: r.load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (r.loading) const M3eLinearProgress(),
                      CdkProjectHero(project: p),
                      if (message != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Semantics(
                            liveRegion: true,
                            child: SegmentedCardGroup(
                              children: [
                                ListTile(
                                  leading: Icon(
                                    r.delivered
                                        ? Symbols.check_circle_rounded
                                        : Symbols.info_rounded,
                                    color: context.emphasis.accent,
                                  ),
                                  title: Text(message),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (r.delivered) ...[
                        const SizedBox(height: 12),
                        CdkSecretContent(content: r.content ?? p.content),
                      ],
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
                      CdkSectionTitle(l.cdk_eligibility),
                      CdkEligibility(project: p, account: account),
                      CdkSectionTitle(l.cdk_receiveRules),
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
                            subtitle: Text(
                              cdkDistribution(context, p.distribution),
                            ),
                          ),
                          if (!p.allowSameIp)
                            ListTile(title: Text(l.cdk_sameIpLimit)),
                        ],
                      ),
                      if (p.description.isNotEmpty) ...[
                        CdkSectionTitle(l.cdk_description),
                        SelectableText(
                          p.description,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ],
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
              PageBackdrop(
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final compact =
                            box.maxWidth <
                            MediaQuery.textScalerOf(context).scale(340);
                        final refresh = IconButton(
                          tooltip: l.common_refresh,
                          onPressed: _busy || r.loading
                              ? null
                              : () {
                                  _poll?.cancel();
                                  setState(() => _flowError = null);
                                  unawaited(r.load());
                                },
                          icon: const Icon(Symbols.refresh_rounded),
                        );
                        final price = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l.cdk_price,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                            CdkPrice(project: p),
                          ],
                        );
                        final action = FilledButton(
                          onPressed:
                              _busy ||
                                  r.loading ||
                                  r.delivered ||
                                  r.paymentSubmitted
                              ? null
                              : r.payment != null
                              ? _continuePayment
                              : r.canReceive && eligible
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
                                      ? l.cdk_verifyAndContinue
                                      : l.cdk_receive,
                                ),
                        );
                        if (compact) {
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Expanded(child: price),
                                  refresh,
                                ],
                              ),
                              const SizedBox(height: 8),
                              SizedBox(width: double.infinity, child: action),
                            ],
                          );
                        }
                        return Row(
                          children: [
                            refresh,
                            Expanded(child: price),
                            const SizedBox(width: 12),
                            Expanded(child: action),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
