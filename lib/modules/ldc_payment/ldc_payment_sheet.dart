import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../services/ldc_payment_service.dart';
import '../../services/ldc_biometric_payment.dart';
import '../../widgets/common/app_bottom_sheet.dart';

Future<Map<String, Object?>?> showLdcPaymentSheet(
  BuildContext context, {
  required LdcPaymentDelegate payment,
  required String orderNo,
  required String username,
  bool needsPassword = false,
  LdcBiometricPayment? biometrics,
}) => AppBottomSheet.show<Map<String, Object?>>(
  context: context,
  title: context.l10n.metaverse_nativePayTitle,
  style: AppSheetStyle.card,
  showDragHandle: true,
  showCloseButton: false,
  isDismissible: false,
  contentPadding: EdgeInsets.zero,
  builder: (_) => _PaymentContent(
    payment: payment,
    orderNo: orderNo,
    username: username,
    needsPassword: needsPassword,
    biometrics: biometrics,
  ),
);

class _PaymentContent extends StatefulWidget {
  const _PaymentContent({
    required this.payment,
    required this.orderNo,
    required this.username,
    required this.needsPassword,
    this.biometrics,
  });
  final LdcPaymentDelegate payment;
  final String orderNo, username;
  final bool needsPassword;
  final LdcBiometricPayment? biometrics;
  @override
  State<_PaymentContent> createState() => _PaymentContentState();
}

class _PaymentContentState extends State<_PaymentContent> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  late bool _needsPassword = widget.needsPassword;
  LdcPaymentOrder? _order;
  bool _loading = true, _paying = false, _submitted = false, _paid = false;
  String? _error, _biometricNote;
  bool _biometricAvailable = false, _biometricEnabled = false;
  bool _useBiometric = false, _rememberBiometric = false;

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
      final available = await widget.biometrics?.available() ?? false;
      if (mounted) {
        setState(() {
          _order = order;
          _biometricAvailable = available;
          _biometricEnabled = widget.biometrics?.enabled == true;
          _useBiometric = available && _biometricEnabled && !_needsPassword;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.metaverse_nativePayLoadFailed);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pay({bool biometric = false}) async {
    if (_paying ||
        _submitted ||
        _order == null ||
        (!biometric && _password.text.length != 6)) {
      return;
    }
    setState(() {
      _paying = true;
      _error = null;
    });
    FocusScope.of(context).unfocus();
    final String password;
    if (biometric) {
      try {
        password = await widget.biometrics!.unlock(
          context.l10n.ldc_biometricReason(_order!.merchant, _order!.amount),
        );
      } catch (_) {
        if (mounted) {
          setState(() {
            _paying = false;
            _useBiometric = false;
            _error = context.l10n.ldc_biometricFailed;
          });
        }
        return;
      }
    } else {
      password = _password.text;
      _password.clear();
    }
    try {
      await widget.payment.pay(_order!, password);
      _submitted = true;
      // 收银台确认成功后保留完成态，商户回调延迟不改变已付款的事实。
      if (mounted) setState(() => _paid = true);
      if (_rememberBiometric && widget.biometrics != null && mounted) {
        try {
          await widget.biometrics!.enable(
            password,
            context.l10n.ldc_biometricEnable,
          );
          if (mounted) {
            setState(() => _biometricNote = context.l10n.ldc_biometricEnabled);
          }
        } catch (_) {
          if (mounted) {
            setState(
              () => _biometricNote = context.l10n.ldc_biometricSaveFailed,
            );
          }
        }
      }
      await _refreshResult();
    } on LdcPaymentException catch (error) {
      if (mounted) {
        setState(() {
          _useBiometric = false;
          _error = error.message.startsWith('payment_')
              ? context.l10n.metaverse_nativePayLoadFailed
              : error.message;
        });
      }
    } on DioException {
      _submitted = true;
      await _refreshResult();
    } catch (_) {
      _submitted = true;
      await _refreshResult();
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  Future<void> _disableBiometrics() async {
    if (_paying) return;
    setState(() => _paying = true);
    try {
      await widget.biometrics!.disable();
      if (mounted) {
        setState(() {
          _biometricEnabled = false;
          _useBiometric = false;
          _rememberBiometric = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.ldc_biometricFailed);
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
      final confirmed = await widget.payment.refreshPayment(widget.orderNo);
      if (mounted) {
        setState(() {
          _paid = _paid || confirmed;
          _error = _paid ? null : context.l10n.metaverse_nativePayPending;
        });
      }
    } catch (_) {
      if (mounted && !_paid) {
        setState(() => _error = context.l10n.metaverse_nativePayPending);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final order = _order;
    final content = _paid && order != null
        ? _success(context, order)
        : Padding(
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
                    if (!_submitted && !_useBiometric)
                      PinInput(
                        controller: _password,
                        enabled: !_paying,
                        label: context.l10n.metaverse_nativePayPassword,
                        textInputAction: _needsPassword
                            ? TextInputAction.next
                            : TextInputAction.done,
                        onChanged: (_) => setState(() {}),
                      ),
                    if (_needsPassword)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: PinInput(
                          controller: _confirmation,
                          enabled: !_paying,
                          label: context.l10n.metaverse_nativePasswordRepeat,
                          onChanged: (_) => setState(() {}),
                        ),
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
                    if (_biometricAvailable &&
                        !_biometricEnabled &&
                        !_needsPassword &&
                        !_submitted &&
                        order != null)
                      CheckboxListTile(
                        value: _rememberBiometric,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(context.l10n.ldc_biometricEnable),
                        subtitle: Text(context.l10n.ldc_biometricNote),
                        onChanged: _paying
                            ? null
                            : (value) => setState(
                                () => _rememberBiometric = value ?? false,
                              ),
                      ),
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
                    else if (_useBiometric)
                      FilledButton.icon(
                        onPressed: _paying ? null : () => _pay(biometric: true),
                        icon: _paying
                            ? const LoadingSpinner(size: 18)
                            : const Icon(Symbols.fingerprint_rounded),
                        label: Text(context.l10n.ldc_biometricPay),
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
                    if (_biometricEnabled &&
                        !_needsPassword &&
                        !_submitted) ...[
                      if (_biometricAvailable)
                        TextButton(
                          onPressed: _paying
                              ? null
                              : () => setState(
                                  () => _useBiometric = !_useBiometric,
                                ),
                          child: Text(
                            _useBiometric
                                ? context.l10n.ldc_usePaymentPassword
                                : context.l10n.ldc_biometricPay,
                          ),
                        ),
                      TextButton(
                        onPressed: _paying ? null : _disableBiometrics,
                        child: Text(context.l10n.ldc_biometricDisable),
                      ),
                    ],
                  ],
                  TextButton(
                    onPressed: _paying ? null : () => Navigator.pop(context),
                    child: Text(
                      _submitted
                          ? context.l10n.common_close
                          : context.l10n.common_cancel,
                    ),
                  ),
                ],
              ),
            ),
          );
    return PopScope(
      canPop: !_paying,
      child: MediaQuery.disableAnimationsOf(context)
          ? content
          : AnimatedSize(
              duration: const Duration(milliseconds: 240),
              alignment: Alignment.topCenter,
              child: content,
            ),
    );
  }

  Widget _success(
    BuildContext context,
    LdcPaymentOrder order,
  ) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: M3eSuccessIndicator()),
        const SizedBox(height: 20),
        Semantics(
          liveRegion: true,
          child: Text(
            context.l10n.metaverse_nativePaySuccess,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${order.amount} LDC',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        Text(
          context.l10n.metaverse_nativePaySuccessMessage,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        if (_biometricNote != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              _biometricNote!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        FilledButton(
          onPressed: _paying
              ? null
              : () =>
                    Navigator.pop(context, <String, Object?>{'state': 'paid'}),
          child: Text(context.l10n.metaverse_nativePayViewOrder),
        ),
      ],
    ),
  );
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
