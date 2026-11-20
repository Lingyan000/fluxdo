import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../l10n/s.dart';

/// username/email + password 输入表单。提交逻辑 (调 DiscourseService 登录 +
/// 处理 hcaptcha/2FA/跳转) 由父组件持有,form 本身只负责 UI 和数据校验。
class LoginForm extends StatefulWidget {
  const LoginForm({
    super.key,
    required this.onSubmit,
    this.progressLabel,
    this.onForgotPassword,
    this.savedUsername,
    this.savedPassword,
  });

  /// 提交回调。父组件返 true = 成功 (form 清空 password), false = 失败 (form 保留)。
  final Future<bool> Function({
    required String identifier,
    required String password,
    required bool rememberCredentials,
  })
  onSubmit;

  final String? progressLabel;

  /// 忘记密码点击 (一般跳 webview)。
  final VoidCallback? onForgotPassword;

  /// 上次保存的账号 (来自 [CredentialStoreService])。
  final String? savedUsername;
  final String? savedPassword;

  @override
  State<LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<LoginForm> {
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _passwordCtrl;
  final FocusNode _usernameFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();
  bool _obscure = true;
  bool _remember = false;
  bool _submitting = false;
  Timer? _feedbackDelay;
  String? _visibleProgress;

  @override
  void initState() {
    super.initState();
    _usernameCtrl = TextEditingController(text: widget.savedUsername ?? '');
    _passwordCtrl = TextEditingController(text: widget.savedPassword ?? '');
    _remember =
        (widget.savedPassword != null && widget.savedPassword!.isNotEmpty);
  }

  @override
  void didUpdateWidget(LoginForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.progressLabel == oldWidget.progressLabel) return;
    _feedbackDelay?.cancel();
    final label = widget.progressLabel;
    if (label == null) {
      _visibleProgress = null;
    } else {
      // 仅延迟提示的显示，快速请求直接结束，慢请求仍能说明当前在等什么。
      _feedbackDelay = Timer(const Duration(milliseconds: 250), () {
        if (mounted && _submitting) setState(() => _visibleProgress = label);
      });
    }
  }

  @override
  void dispose() {
    _feedbackDelay?.cancel();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final identifier = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (identifier.isEmpty || password.isEmpty) return;

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _submitting = true);
    try {
      final ok = await widget.onSubmit(
        identifier: identifier,
        password: password,
        rememberCredentials: _remember,
      );
      if (ok && mounted) {
        _passwordCtrl.clear();
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  InputDecoration _inputDecoration(
    ColorScheme scheme, {
    required String label,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: context.shapes.borderRadius(14),
      borderSide: BorderSide(color: color, width: width),
    );
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      prefixIcon: Icon(icon),
      suffixIcon: suffixIcon,
      border: border(Colors.transparent, 0),
      enabledBorder: border(Colors.transparent, 0),
      focusedBorder: border(scheme.primary, 1.5),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = _submitting ? _visibleProgress : null;

    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _usernameCtrl,
            focusNode: _usernameFocus,
            enabled: !_submitting,
            autofillHints: const [AutofillHints.username, AutofillHints.email],
            textInputAction: TextInputAction.next,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: _inputDecoration(
              scheme,
              label: context.l10n.login_identifier,
              icon: Symbols.person_rounded,
            ),
            onSubmitted: (_) => _passwordFocus.requestFocus(),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _passwordCtrl,
            focusNode: _passwordFocus,
            enabled: !_submitting,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.go,
            obscureText: _obscure,
            decoration: _inputDecoration(
              scheme,
              label: context.l10n.login_password,
              icon: Symbols.lock_rounded,
              suffixIcon: IconButton(
                tooltip: _obscure
                    ? context.l10n.login_showPassword
                    : context.l10n.login_hidePassword,
                icon: Icon(
                  _obscure
                      ? Symbols.visibility_rounded
                      : Symbols.visibility_off_rounded,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Checkbox(
                value: _remember,
                onChanged: _submitting
                    ? null
                    : (v) => setState(() => _remember = v ?? false),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _submitting
                      ? null
                      : () => setState(() => _remember = !_remember),
                  child: Text(context.l10n.login_rememberPassword),
                ),
              ),
              if (widget.onForgotPassword != null)
                TextButton(
                  onPressed: _submitting ? null : widget.onForgotPassword,
                  child: Text(context.l10n.login_forgotPassword),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Semantics(
            liveRegion: progress != null,
            child: Stack(
              alignment: Alignment.center,
              children: [
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 56),
                    disabledBackgroundColor: scheme.primary,
                    disabledForegroundColor: scheme.onPrimary,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: context.shapes.borderRadius(28),
                    ),
                    elevation: 8,
                    shadowColor: scheme.primary.withValues(alpha: 0.4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Text(
                      progress ?? context.l10n.common_login,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
                if (progress != null)
                  PositionedDirectional(
                    start: 20,
                    end: 20,
                    bottom: 6,
                    child: ExcludeSemantics(
                      child:
                          MediaQuery.disableAnimationsOf(context) ||
                              MediaQuery.reduceMotionOf(context)
                          ? SizedBox(
                              height: 2,
                              child: ColoredBox(
                                color: scheme.onPrimary.withValues(alpha: 0.35),
                              ),
                            )
                          : LinearProgressIndicator(
                              minHeight: 2,
                              color: scheme.onPrimary,
                              backgroundColor: scheme.onPrimary.withValues(
                                alpha: 0.22,
                              ),
                              borderRadius: context.shapes.borderRadius(2),
                            ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
