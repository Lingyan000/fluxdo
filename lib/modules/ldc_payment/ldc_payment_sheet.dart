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
  final _passwordFocus = FocusNode();
  final _confirmationFocus = FocusNode();
  late bool _needsPassword = widget.needsPassword;
  LdcPaymentOrder? _order;
  bool _loading = true, _paying = false, _submitted = false, _paid = false;
  String? _error, _biometricNote;
  bool _biometricAvailable = false, _biometricEnabled = false;
  bool _useBiometric = false, _rememberBiometric = false;
  bool _confirmingPassword = false;

  @override
  void initState() {
    super.initState();
    _passwordFocus.addListener(() {
      if (_passwordFocus.hasFocus) _confirmingPassword = false;
    });
    _confirmationFocus.addListener(() {
      if (_confirmationFocus.hasFocus) _confirmingPassword = true;
    });
    _load();
  }

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    _confirmation.clear();
    _confirmation.dispose();
    _passwordFocus.dispose();
    _confirmationFocus.dispose();
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
      if (mounted) {
        setState(() {
          _needsPassword = false;
          _confirmingPassword = false;
        });
        _passwordFocus.requestFocus();
      }
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

  void _close() {
    if (_paying) return;
    Navigator.pop(
      context,
      _submitted || _paid
          ? <String, Object?>{'state': _paid ? 'paid' : 'pending'}
          : null,
    );
  }

  void _inputDigit(String digit) {
    if (_paying || _submitted) return;
    final controller = _needsPassword && _confirmingPassword
        ? _confirmation
        : _password;
    if (controller.text.length >= 6) return;
    (controller == _confirmation ? _confirmationFocus : _passwordFocus)
        .requestFocus();
    setState(() {
      controller.text += digit;
      controller.selection = TextSelection.collapsed(
        offset: controller.text.length,
      );
    });
    if (_needsPassword &&
        controller == _password &&
        controller.text.length == 6) {
      _confirmingPassword = true;
      _confirmationFocus.requestFocus();
    }
  }

  void _deleteDigit() {
    if (_paying || _submitted) return;
    final controller = _needsPassword && _confirmingPassword
        ? _confirmation
        : _password;
    if (controller.text.isEmpty) return;
    setState(() {
      controller.text = controller.text.substring(
        0,
        controller.text.length - 1,
      );
      controller.selection = TextSelection.collapsed(
        offset: controller.text.length,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final order = _order;
    final showKeyboard =
        !_loading && order != null && !_submitted && !_useBiometric;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                tooltip: _submitted ? l.common_close : l.common_cancel,
                onPressed: _paying ? null : _close,
                icon: const Icon(Symbols.close_rounded),
              ),
              Expanded(
                child: Text(
                  l.metaverse_nativePayTitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
        ),
        if (_paid && order != null)
          Flexible(child: _success(context, order))
        else ...[
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
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
                    Text(
                      '${order.merchant} · ${order.payee}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    Text.rich(
                      TextSpan(
                        text: order.amount,
                        children: [
                          TextSpan(
                            text: ' LDC',
                            style: theme.textTheme.titleMedium,
                          ),
                        ],
                      ),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      order.name,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          Icon(
                            Symbols.account_balance_wallet_rounded,
                            color: context.emphasis.accent,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            l.ldc_paymentMethod,
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'LDC · ${order.payer}',
                              textAlign: TextAlign.end,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _DetailRow(l.metaverse_nativePayOrder, order.orderNo),
                    const SizedBox(height: 16),
                    if (_needsPassword)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(l.metaverse_nativePasswordSetup),
                      ),
                    if (!_submitted && !_useBiometric)
                      PinInput(
                        controller: _password,
                        focusNode: _passwordFocus,
                        keyboardType: TextInputType.none,
                        enabled: !_paying,
                        label: l.metaverse_nativePayPassword,
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
                          focusNode: _confirmationFocus,
                          keyboardType: TextInputType.none,
                          enabled: !_paying,
                          label: l.metaverse_nativePasswordRepeat,
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    if (_useBiometric && !_submitted)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Column(
                          children: [
                            Icon(
                              Symbols.fingerprint_rounded,
                              size: 44,
                              color: context.emphasis.accent,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              l.ldc_biometricHint,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  if (!_loading &&
                      order != null &&
                      !_submitted &&
                      !_needsPassword) ...[
                    if (_biometricAvailable && !_biometricEnabled)
                      CheckboxListTile(
                        value: _rememberBiometric,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(l.ldc_biometricEnable),
                        subtitle: Text(l.ldc_biometricNote),
                        onChanged: _paying
                            ? null
                            : (value) => setState(
                                () => _rememberBiometric = value ?? false,
                              ),
                      ),
                    if (_biometricEnabled)
                      Wrap(
                        alignment: WrapAlignment.center,
                        children: [
                          if (_biometricAvailable)
                            TextButton(
                              onPressed: _paying
                                  ? null
                                  : () => setState(
                                      () => _useBiometric = !_useBiometric,
                                    ),
                              child: Text(
                                _useBiometric
                                    ? l.ldc_usePaymentPassword
                                    : l.ldc_biometricPay,
                              ),
                            ),
                          TextButton(
                            onPressed: _paying ? null : _disableBiometrics,
                            child: Text(l.ldc_biometricDisable),
                          ),
                        ],
                      ),
                  ],
                ],
              ),
            ),
          ),
          if (!_loading)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: SizedBox(
                width: double.infinity,
                child: _primaryAction(context),
              ),
            ),
          if (showKeyboard)
            _PaymentKeypad(
              enabled: !_paying,
              onDigit: _inputDigit,
              onDelete: _deleteDigit,
            ),
        ],
      ],
    );
    return PopScope(
      canPop: !_paying && !_submitted,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_paying) _close();
      },
      child: MediaQuery.disableAnimationsOf(context)
          ? content
          : AnimatedSize(
              duration: const Duration(milliseconds: 240),
              alignment: Alignment.topCenter,
              child: content,
            ),
    );
  }

  Widget _primaryAction(BuildContext context) {
    final l = context.l10n;
    if (_submitted) {
      return FilledButton(
        onPressed: _paying ? null : _checkResult,
        child: Text(l.metaverse_nativePayCheck),
      );
    }
    final order = _order;
    if (order == null) {
      return FilledButton(onPressed: _load, child: Text(l.common_retry));
    }
    if (_needsPassword) {
      return FilledButton(
        onPressed:
            _paying ||
                _password.text.length != 6 ||
                _password.text != _confirmation.text
            ? null
            : _setPassword,
        child: Text(l.metaverse_nativePasswordSave),
      );
    }
    return FilledButton.icon(
      onPressed: _paying || (!_useBiometric && _password.text.length != 6)
          ? null
          : () => _pay(biometric: _useBiometric),
      icon: _paying
          ? const LoadingSpinner(size: 18)
          : Icon(
              _useBiometric
                  ? Symbols.fingerprint_rounded
                  : Symbols.lock_rounded,
              size: 20,
            ),
      label: Text(
        _useBiometric
            ? l.ldc_biometricPay
            : l.metaverse_nativePayConfirm(order.amount),
      ),
    );
  }

  Widget _success(BuildContext context, LdcPaymentOrder order) =>
      SingleChildScrollView(
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
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
              onPressed: _paying ? null : _close,
              child: Text(context.l10n.metaverse_nativePayViewOrder),
            ),
          ],
        ),
      );
}

/// 收银台内的数字键盘，密码输入仅更新宿主控制器。
class _PaymentKeypad extends StatelessWidget {
  const _PaymentKeypad({
    required this.enabled,
    required this.onDigit,
    required this.onDelete,
  });
  final bool enabled;
  final ValueChanged<String> onDigit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = TextButton.styleFrom(
      backgroundColor: theme.colorScheme.surface,
      foregroundColor: theme.colorScheme.onSurface,
      padding: EdgeInsets.zero,
      shape: RoundedSuperellipseBorder(
        borderRadius: context.shapes.borderRadius(8),
      ),
    );
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: GridView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisExtent: 48,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemCount: 12,
          itemBuilder: (context, index) {
            if (index == 9) return const SizedBox.shrink();
            if (index == 11) {
              return Tooltip(
                message: context.l10n.ldc_deleteDigit,
                child: TextButton(
                  key: const ValueKey('ldc-key-delete'),
                  onPressed: enabled ? onDelete : null,
                  style: style,
                  child: const Icon(Symbols.backspace_rounded),
                ),
              );
            }
            final digit = index == 10 ? '0' : '${index + 1}';
            return TextButton(
              key: ValueKey('ldc-key-$digit'),
              onPressed: enabled ? () => onDigit(digit) : null,
              style: style,
              child: FittedBox(
                child: Text(digit, style: theme.textTheme.headlineSmall),
              ),
            );
          },
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
