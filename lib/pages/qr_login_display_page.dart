import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/s.dart';
import '../services/qr_login_service.dart';
import '../services/toast_service.dart';
import '../utils/dialog_utils.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 可选 API Key 有效期预设。
///
/// `null` 表示不过期(默认)。
const List<({String labelKey, Duration? duration})> _kExpiryOptions = [
  (labelKey: 'never', duration: null),
  (labelKey: '1h', duration: Duration(hours: 1)),
  (labelKey: '24h', duration: Duration(hours: 24)),
  (labelKey: '7d', duration: Duration(days: 7)),
  (labelKey: '30d', duration: Duration(days: 30)),
];

/// 已登录设备:展示用于另一台设备扫码登录的二维码。
///
/// 二维码携带新创建的 User API Key + 一次性 OTP;
/// 生成前必须用户二次确认;可选设置 API Key 过期时间(默认不过期)。
class QrLoginDisplayPage extends StatefulWidget {
  const QrLoginDisplayPage({super.key, this.username});

  /// 可选,展示用用户名(不传则服务里再取)
  final String? username;

  @override
  State<QrLoginDisplayPage> createState() => _QrLoginDisplayPageState();
}

class _QrLoginDisplayPageState extends State<QrLoginDisplayPage> {
  String? _raw;
  QrLoginPayload? _payload;
  String? _error;
  bool _loading = false;
  bool _approved = false;
  Duration? _selectedExpiry; // null = 不过期
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _expiryChipLabel(BuildContext context, Duration? duration) {
    if (duration == null) return context.l10n.login_qrExpiryNever;
    if (duration.inDays >= 1) {
      return context.l10n.login_qrExpiryDays(duration.inDays);
    }
    if (duration.inHours >= 1) {
      return context.l10n.login_qrExpiryHours(duration.inHours);
    }
    return context.l10n.login_qrExpiryMinutes(duration.inMinutes);
  }

  /// 每次生成/重新生成前都必须二次确认。
  Future<void> _confirmAndGenerate() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.login_qrConfirmTitle),
        content: Text(ctx.l10n.login_qrConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.login_qrConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _approved = true);
    await _generate();
  }

  Future<void> _generate() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await QrLoginService.instance.buildPayload(
        username: widget.username,
        expiresIn: _selectedExpiry,
      );
      if (!mounted) return;
      setState(() {
        _raw = result.raw;
        _payload = result.payload;
        _loading = false;
      });
      _restartTicker();
    } on QrLoginException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
        _raw = null;
        _payload = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = S.current.login_qrGenerateFailed;
        _loading = false;
        _raw = null;
        _payload = null;
      });
      debugPrint('[QrLoginDisplay] 生成失败: $e');
    }
  }

  void _restartTicker() {
    _ticker?.cancel();
    final payload = _payload;
    if (payload == null || payload.neverExpires) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final p = _payload;
      if (p == null || p.neverExpires) {
        _ticker?.cancel();
        return;
      }
      if (p.isExpired) {
        setState(() {});
        _ticker?.cancel();
        return;
      }
      setState(() {});
    });
  }

  String _formatRemaining(Duration d) {
    final total = d.inSeconds;
    if (total >= 86400) {
      final days = total ~/ 86400;
      final hours = (total % 86400) ~/ 3600;
      return '${days}d ${hours.toString().padLeft(2, '0')}h';
    }
    if (total >= 3600) {
      final h = total ~/ 3600;
      final m = (total % 3600) ~/ 60;
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    }
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final payload = _payload;
    final expired = payload?.isExpired ?? false;
    final hasQr = _raw != null && payload != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.login_qrDisplayTitle),
        actions: [
          if (_approved)
            IconButton(
              tooltip: context.l10n.login_qrRefresh,
              onPressed: _loading ? null : _confirmAndGenerate,
              icon: const Icon(Symbols.refresh_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.l10n.login_qrDisplayHint,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      context.l10n.login_qrExpiryLabel,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final opt in _kExpiryOptions)
                        ChoiceChip(
                          label: Text(_expiryChipLabel(context, opt.duration)),
                          selected: _selectedExpiry == opt.duration,
                          onSelected: _loading
                              ? null
                              : (selected) {
                                  if (!selected) return;
                                  setState(() {
                                    _selectedExpiry = opt.duration;
                                    // 改有效期后需重新确认生成
                                    if (_approved && hasQr) {
                                      _approved = false;
                                      _raw = null;
                                      _payload = null;
                                      _ticker?.cancel();
                                    }
                                  });
                                },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.login_qrExpiryHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (!_approved && !_loading) ...[
                    FilledButton.icon(
                      onPressed: _confirmAndGenerate,
                      icon: const Icon(Symbols.qr_code_rounded),
                      label: Text(context.l10n.login_qrGenerateAction),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  if (_approved || _loading) _buildQrCard(theme, scheme, expired),
                  if (payload != null && !expired && !payload.neverExpires) ...[
                    const SizedBox(height: 20),
                    Text(
                      context.l10n.login_qrExpiresIn(
                        _formatRemaining(payload.remaining),
                      ),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (payload != null && payload.neverExpires && !expired) ...[
                    const SizedBox(height: 20),
                    Text(
                      context.l10n.login_qrNeverExpires,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (payload != null && expired) ...[
                    const SizedBox(height: 20),
                    Text(
                      context.l10n.login_qrExpired,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _loading ? null : _confirmAndGenerate,
                      icon: const Icon(Symbols.refresh_rounded),
                      label: Text(context.l10n.login_qrRefresh),
                    ),
                  ],
                  if (payload != null && payload.username.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      context.l10n.login_qrAccount(payload.username),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Symbols.warning_rounded,
                          size: 20,
                          color: scheme.error,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            context.l10n.login_qrSecurityWarning,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQrCard(ThemeData theme, ColorScheme scheme, bool expired) {
    if (_loading) {
      return const SizedBox(
        height: 280,
        child: Center(child: LoadingSpinner(size: 40)),
      );
    }
    if (_error != null) {
      return Column(
        children: [
          Icon(Symbols.error_rounded, size: 48, color: scheme.error),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _confirmAndGenerate,
            child: Text(context.l10n.common_retry),
          ),
        ],
      );
    }
    final raw = _raw;
    if (raw == null) {
      return const SizedBox.shrink();
    }

    return AnimatedOpacity(
      opacity: expired ? 0.35 : 1,
      duration: const Duration(milliseconds: 200),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.35 : 0.08,
              ),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: QrImageView(
          data: raw,
          version: QrVersions.auto,
          size: 260,
          backgroundColor: Colors.white,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Colors.black,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Colors.black,
          ),
          errorStateBuilder: (context, error) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                ToastService.showError(S.current.login_qrGenerateFailed);
              }
            });
            return Center(
              child: Text(
                S.current.login_qrGenerateFailed,
                style: const TextStyle(color: Colors.red),
              ),
            );
          },
        ),
      ),
    );
  }
}
