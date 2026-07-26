import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../../../l10n/s.dart';
import '../../../utils/dialog_utils.dart';
import '../../../services/toast_service.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../../../widgets/common/smart_avatar.dart';
import '../providers/ldc_reward_provider.dart';

/// 打赏目标用户信息
class RewardTargetInfo {
  final int userId;
  final String username;
  final String? name;
  final String avatarUrl;
  final int topicId;
  final int postId;

  const RewardTargetInfo({
    required this.userId,
    required this.username,
    this.name,
    required this.avatarUrl,
    required this.topicId,
    required this.postId,
  });
}

/// 显示打赏底部弹窗
void showLdcRewardSheet(BuildContext context, RewardTargetInfo target) {
  showAppBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    enableDrag: false, // 打赏表单(card):禁止下滑误关
    builder: (ctx) => _LdcRewardSheet(target: target),
  );
}

class _LdcRewardSheet extends ConsumerStatefulWidget {
  final RewardTargetInfo target;

  const _LdcRewardSheet({required this.target});

  @override
  ConsumerState<_LdcRewardSheet> createState() => _LdcRewardSheetState();
}

class _LdcRewardSheetState extends ConsumerState<_LdcRewardSheet> {
  static const List<double> _quickAmounts = [1, 5, 10, 50];
  static const double _minAmount = 0.01;
  static const double _maxAmount = 10000;

  final _amountController = TextEditingController();
  final _remarkController = TextEditingController();
  double? _selectedQuickAmount;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _amountController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  double? get _currentAmount {
    if (_selectedQuickAmount != null) return _selectedQuickAmount;
    final text = _amountController.text.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }

  bool get _isAmountValid {
    final amount = _currentAmount;
    return amount != null && amount >= _minAmount && amount <= _maxAmount;
  }

  void _selectQuickAmount(double amount) {
    setState(() {
      _selectedQuickAmount = amount;
      _amountController.clear();
    });
  }

  void _onCustomAmountChanged(String _) {
    setState(() {
      _selectedQuickAmount = null;
    });
  }

  Future<void> _submit() async {
    if (!_isAmountValid || _isSubmitting) return;

    final amount = _currentAmount!;
    final target = widget.target;

    // 二次确认
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.reward_confirmTitle),
        content: Text(
          context.l10n.reward_confirmMessage(
            target.name ?? target.username,
            amount.toInt(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.l10n.common_confirm),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isSubmitting = true);

    try {
      final credentials = await ref.read(ldcRewardCredentialsProvider.future);
      if (credentials == null) {
        ToastService.showError(S.current.toast_rewardNotConfigured);
        return;
      }

      final result = await executeReward(
        credentials: credentials,
        userId: target.userId,
        username: target.username,
        amount: amount,
        topicId: target.topicId,
        postId: target.postId,
        remark: _remarkController.text.trim().isNotEmpty
            ? _remarkController.text.trim()
            : null,
      );

      if (!mounted) return;

      if (result.success) {
        ToastService.showSuccess(S.current.toast_rewardSuccess);
        Navigator.pop(context);
      } else {
        ToastService.showError(result.errorMsg ?? S.current.toast_rewardFailed);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.toast_rewardError(e.toString()));
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = widget.target;

    return AppSheetScaffold(
      style: AppSheetStyle.card,
      showCloseButton: false,
      contentPadding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Center(
            child: Text(
              context.l10n.reward_sheetTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 目标用户信息
          Row(
            children: [
              SmartAvatar(
                imageUrl: target.avatarUrl,
                radius: 20,
                fallbackText: target.username,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (target.name != null && target.name!.isNotEmpty)
                      Text(
                        target.name!,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    Text(
                      '@${target.username}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // 快捷金额
          Text(
            context.l10n.reward_selectAmount,
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Row(
            children: _quickAmounts.map((amount) {
              final isSelected = _selectedQuickAmount == amount;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: amount == _quickAmounts.last ? 0 : 8,
                  ),
                  child: ChoiceChip(
                    label: SizedBox(
                      width: double.infinity,
                      child: Text(
                        '${amount.toInt()} LDC',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.w600 : null,
                        ),
                      ),
                    ),
                    selected: isSelected,
                    onSelected: (_) => _selectQuickAmount(amount),
                    showCheckmark: false,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // 自定义金额输入
          TextField(
            controller: _amountController,
            onChanged: _onCustomAmountChanged,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
            ],
            decoration: InputDecoration(
              labelText: context.l10n.reward_customAmount,
              hintText: '$_minAmount - $_maxAmount',
              suffixText: 'LDC',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),

          // 备注
          TextField(
            controller: _remarkController,
            maxLength: 50,
            decoration: InputDecoration(
              labelText: context.l10n.reward_noteLabel,
              hintText: context.l10n.reward_noteHint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),

          // 确认按钮
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _isAmountValid && !_isSubmitting ? _submit : null,
              child: _isSubmitting
                  ? const LoadingSpinner(size: 20, color: Colors.white)
                  : Text(
                      _isAmountValid
                          ? context.l10n.reward_submitWithAmount(
                              _currentAmount!.toInt(),
                            )
                          : context.l10n.reward_selectOrInputAmount,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
