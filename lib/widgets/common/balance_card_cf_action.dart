import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../services/cf_challenge_service.dart';
import '../../services/toast_service.dart';
import 'balance_card_action_button.dart';

/// 验证与随后的余额刷新共用忙碌状态；取消验证不会清除业务登录态。
class BalanceCardCfAction extends StatefulWidget {
  const BalanceCardCfAction({
    super.key,
    required this.onRetry,
    required this.isLoading,
    this.filled = false,
    this.verify,
  });

  final Future<void> Function() onRetry;
  final bool isLoading;
  final bool filled;
  final Future<bool?> Function(BuildContext)? verify;

  @override
  State<BalanceCardCfAction> createState() => _BalanceCardCfActionState();
}

class _BalanceCardCfActionState extends State<BalanceCardCfAction> {
  bool _verifying = false;

  Future<void> _verify() async {
    if (_verifying || widget.isLoading) return;
    setState(() => _verifying = true);
    try {
      final result =
          await (widget.verify?.call(context) ??
              CfChallengeService().showManualVerifyNow(context, true));
      if (!mounted) return;
      if (result == true) {
        await widget.onRetry();
      } else if (result == false) {
        ToastService.showError(S.current.cf_verifyIncomplete);
      } else {
        ToastService.showError(S.current.cf_cannotOpenVerifyPage);
      }
    } catch (error) {
      if (mounted) ToastService.showError(S.current.cf_failedRetry);
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) => BalanceCardActionButton(
    label: context.l10n.cf_manualVerifyAction,
    onPressed: _verify,
    isLoading: widget.isLoading || _verifying,
    filled: widget.filled,
  );
}
