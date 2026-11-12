import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../l10n/s.dart';
import '../../../../services/ldc_payment_service.dart';
import '../../../../utils/dialog_utils.dart';
import '../../../../utils/link_launcher.dart';
import '../../../../widgets/common/app_bottom_sheet.dart';
import '../metaverse_payment.dart';
import '../metaverse_plugin_manifest.dart';

Future<bool> showMetaverseConnectConfirmation(
  BuildContext context,
  MetaversePluginManifest manifest,
  String username,
) async {
  return await showAppDialog<bool>(
        context: context,
        builder: (_) =>
            _ConnectConfirmation(manifest: manifest, username: username),
      ) ??
      false;
}

class _ConnectConfirmation extends StatefulWidget {
  const _ConnectConfirmation({required this.manifest, required this.username});
  final MetaversePluginManifest manifest;
  final String username;
  @override
  State<_ConnectConfirmation> createState() => _ConnectConfirmationState();
}

class _ConnectConfirmationState extends State<_ConnectConfirmation> {
  bool _accepted = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.metaverse_nativeLoginTitle(widget.manifest.name)),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.metaverse_nativeLoginAccount(widget.username)),
          const SizedBox(height: 12),
          Text(context.l10n.metaverse_nativeLoginAccess),
          const SizedBox(height: 8),
          Text(
            Uri.parse(widget.manifest.auth.connect!['callback']!).host,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          TextButton(
            onPressed: () => launchExternalLink(
              context,
              widget.manifest.auth.connect!['terms']!,
            ),
            child: Text(context.l10n.metaverse_nativeTerms),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _accepted,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(context.l10n.metaverse_nativeTermsAgree),
            onChanged: (value) => setState(() => _accepted = value ?? false),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(context.l10n.common_cancel),
      ),
      FilledButton(
        onPressed: _accepted ? () => Navigator.pop(context, true) : null,
        child: Text(context.l10n.common_allow),
      ),
    ],
  );
}

Future<Map<String, Object?>?> showMetaversePaymentSheet(
  BuildContext context, {
  required MetaversePayment payment,
  required String orderNo,
  required String username,
  bool needsPassword = false,
}) => AppBottomSheet.show<Map<String, Object?>>(
  context: context,
  title: context.l10n.metaverse_nativePayTitle,
  style: AppSheetStyle.card,
  showCloseButton: false,
  isDismissible: false,
  contentPadding: EdgeInsets.zero,
  builder: (_) => _PaymentContent(
    payment: payment,
    orderNo: orderNo,
    username: username,
    needsPassword: needsPassword,
  ),
);

class _PaymentContent extends StatefulWidget {
  const _PaymentContent({
    required this.payment,
    required this.orderNo,
    required this.username,
    required this.needsPassword,
  });
  final MetaversePayment payment;
  final String orderNo, username;
  final bool needsPassword;
  @override
  State<_PaymentContent> createState() => _PaymentContentState();
}

class _PaymentContentState extends State<_PaymentContent> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  late bool _needsPassword = widget.needsPassword;
  LdcPaymentOrder? _order;
  bool _loading = true, _paying = false, _submitted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    _confirmation.clear();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final order = await widget.payment.prepare(
        widget.orderNo,
        widget.username,
      );
      if (mounted) setState(() => _order = order);
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.metaverse_nativePayLoadFailed);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pay() async {
    if (_paying || _submitted || _order == null || _password.text.length != 6) {
      return;
    }
    setState(() {
      _paying = true;
      _error = null;
    });
    final password = _password.text;
    _password.clear();
    try {
      await widget.payment.pay(_order!, password);
      _submitted = true;
      await _refreshResult();
    } on LdcPaymentException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.message.startsWith('payment_')
              ? context.l10n.metaverse_nativePayLoadFailed
              : error.message,
        );
      }
    } on DioException {
      // 响应丢失时先查原单，禁止在确认页再次发送扣款请求。
      _submitted = true;
      await _refreshResult();
    } catch (_) {
      _submitted = true;
      await _refreshResult();
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  Future<void> _setPassword() async {
    if (_paying ||
        _password.text.length != 6 ||
        _password.text != _confirmation.text) {
      return;
    }
    setState(() {
      _paying = true;
      _error = null;
    });
    final password = _password.text;
    _password.clear();
    _confirmation.clear();
    try {
      await widget.payment.setInitialPassword(password, widget.username);
      if (mounted) setState(() => _needsPassword = false);
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.metaverse_nativePasswordFailed);
      }
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  Future<void> _checkResult() async {
    if (_paying) return;
    setState(() => _paying = true);
    await _refreshResult();
    if (mounted) setState(() => _paying = false);
  }

  Future<void> _refreshResult() async {
    try {
      await widget.payment.request(widget.orderNo, 'refresh');
      if (mounted) {
        Navigator.pop(context, <String, Object?>{'state': 'checking'});
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.metaverse_nativePayPending);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final order = _order;
    return PopScope(
      canPop: !_paying,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: LoadingSpinner()),
                )
              else if (order != null) ...[
                Icon(
                  Symbols.account_balance_wallet_rounded,
                  size: 32,
                  color: context.emphasis.accent,
                ),
                const SizedBox(height: 12),
                Text(
                  '${order.amount} LDC',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  order.name,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 24),
                _DetailRow(
                  context.l10n.metaverse_nativePayMerchant,
                  '${order.merchant} · ${order.payee}',
                ),
                _DetailRow(
                  context.l10n.metaverse_nativePayAccount,
                  order.payer,
                ),
                _DetailRow(
                  context.l10n.metaverse_nativePayOrder,
                  order.orderNo,
                ),
                const SizedBox(height: 20),
                if (_needsPassword)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(context.l10n.metaverse_nativePasswordSetup),
                  ),
                if (!_submitted)
                  TextField(
                    controller: _password,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: context.l10n.metaverse_nativePayPassword,
                      counterText: '',
                      prefixIcon: const Icon(Symbols.lock_rounded),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                if (_needsPassword)
                  TextField(
                    controller: _confirmation,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: context.l10n.metaverse_nativePasswordRepeat,
                      counterText: '',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (!_loading) ...[
                const SizedBox(height: 20),
                if (_submitted)
                  FilledButton(
                    onPressed: _paying ? null : _checkResult,
                    child: Text(context.l10n.metaverse_nativePayCheck),
                  )
                else if (order == null)
                  FilledButton(
                    onPressed: _load,
                    child: Text(context.l10n.common_retry),
                  )
                else if (_needsPassword)
                  FilledButton(
                    onPressed:
                        _paying ||
                            _password.text.length != 6 ||
                            _password.text != _confirmation.text
                        ? null
                        : _setPassword,
                    child: Text(context.l10n.metaverse_nativePasswordSave),
                  )
                else
                  FilledButton.icon(
                    onPressed: _paying || _password.text.length != 6
                        ? null
                        : _pay,
                    icon: _paying
                        ? const LoadingSpinner(size: 18)
                        : const Icon(Symbols.lock_rounded, size: 18),
                    label: Text(
                      context.l10n.metaverse_nativePayConfirm(order.amount),
                    ),
                  ),
              ],
              TextButton(
                onPressed: _paying ? null : () => Navigator.pop(context),
                child: Text(context.l10n.common_cancel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ],
    ),
  );
}
