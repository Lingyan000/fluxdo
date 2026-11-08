import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart' show showInteractionDialog;
import 'package:flutter/services.dart';

/// 二步验证 (TOTP) 输入对话框。返回用户输入的 6 位 code,取消返 null。
///
/// 用法:
/// ```dart
/// final code = await showTwoFactorDialog(context);
/// if (code != null) {
///   // 用 code 重 POST /session.json
/// }
/// ```
Future<String?> showTwoFactorDialog(
  BuildContext context, {
  String? hint,
  VoidCallback? onUseBackupCode,
}) {
  return showInteractionDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TwoFactorDialog(
      hint: hint,
      onUseBackupCode: onUseBackupCode,
    ),
  );
}

class _TwoFactorDialog extends StatefulWidget {
  const _TwoFactorDialog({this.hint, this.onUseBackupCode});

  final String? hint;
  final VoidCallback? onUseBackupCode;

  @override
  State<_TwoFactorDialog> createState() => _TwoFactorDialogState();
}

class _TwoFactorDialogState extends State<_TwoFactorDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _controller.text.trim();
    if (code.length != 6) return;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('二步验证'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.hint ?? '请输入身份验证器 App 显示的 6 位验证码',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            autofillHints: const [AutofillHints.oneTimeCode],
            style: const TextStyle(fontSize: 24, letterSpacing: 8, fontFeatures: [FontFeature.tabularFigures()]),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: const InputDecoration(
              hintText: '000000',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              if (v.length == 6) _submit();
            },
            onSubmitted: (_) => _submit(),
          ),
          if (widget.onUseBackupCode != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onUseBackupCode!();
                },
                child: const Text('改用备用码 / 安全密钥'),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (_, value, _) {
            final enabled = value.text.trim().length == 6;
            return FilledButton(
              onPressed: enabled ? _submit : null,
              child: const Text('验证'),
            );
          },
        ),
      ],
    );
  }
}
