import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/s.dart';
import '../../services/qr_login_service.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/responsive.dart';
import '../../utils/time_utils.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 可选 API Key 有效期预设。
///
/// `null` 表示不过期。自定义时长/截止不在此列表,由 UI 单独处理。
const List<({String labelKey, Duration? duration})> _kExpiryOptions = [
  (labelKey: '1h', duration: Duration(hours: 1)),
  (labelKey: '24h', duration: Duration(hours: 24)),
  (labelKey: '7d', duration: Duration(days: 7)),
  (labelKey: '30d', duration: Duration(days: 30)),
  (labelKey: 'never', duration: null),
];

/// OTP 一次性登录令牌的服务端 TTL(Redis setex 10 分钟,兑换即焚)。
/// 二维码的真实可扫窗口以此为准,与 API Key 有效期无关。
const Duration _kOtpWindow = Duration(minutes: 10);

/// 防截屏通道(Android FLAG_SECURE;其余平台 no-op)。
const MethodChannel _secureScreenChannel = MethodChannel(
  'com.github.lingyan000.fluxdo/browser',
);

Future<void> _setSecureScreen(bool secure) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _secureScreenChannel.invokeMethod('setSecureScreen', {
      'secure': secure,
    });
  } catch (e) {
    debugPrint('[QrLoginSheet] 设置防截屏失败(忽略): $e');
  }
}

/// 展示「登录二维码」弹层:手机 bottom sheet,平板/桌面居中 Dialog。
///
/// 二维码携带新创建的 User API Key + 一次性 OTP;生成前强制二次确认。
Future<void> showQrLoginSheet(BuildContext context, {String? username}) async {
  if (Responsive.isMobile(context)) {
    await showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: _QrLoginPanel(username: username, inSheet: true),
      ),
    );
  } else {
    await showAppDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: SizedBox(
          width: 440,
          child: _QrLoginPanel(username: username, inSheet: false),
        ),
      ),
    );
  }
}

/// 自定义有效期结果:固定时长 或 绝对截止时间,二选一。
class _CustomExpirySelection {
  const _CustomExpirySelection.duration(Duration this.duration)
    : deadline = null;

  const _CustomExpirySelection.deadline(DateTime this.deadline)
    : duration = null;

  final Duration? duration;
  final DateTime? deadline;

  bool get isDeadline => deadline != null;
}

/// 弹层内容:配置态(选有效期 → 生成)⇄ 二维码态(码卡 + OTP 倒计时)。
class _QrLoginPanel extends StatefulWidget {
  const _QrLoginPanel({required this.username, required this.inSheet});

  /// 可选,展示用用户名(不传则服务里再取)
  final String? username;

  /// true = bottom sheet(有 drag handle);false = Dialog(头部带关闭钮)
  final bool inSheet;

  @override
  State<_QrLoginPanel> createState() => _QrLoginPanelState();
}

class _QrLoginPanelState extends State<_QrLoginPanel> {
  String? _raw;
  QrLoginPayload? _payload;
  String? _error;
  bool _loading = false;
  bool _approved = false;

  /// OTP 扫码窗口截止(生成时刻 + 10 分钟)。这是二维码的真实有效期。
  DateTime? _otpDeadline;

  /// 是否选中「自定义」芯片(与预设互斥)。
  bool _isCustomExpiry = false;

  /// 自定义固定时长;非自定义模式下为当前预设(`null` = 不过期)。
  /// 默认 24 小时:二维码含明文 API Key,不过期档位泄露面过大,不作默认。
  Duration? _selectedExpiry = const Duration(hours: 24);

  /// 自定义绝对截止时间(本地时区)。生成时再换算为相对 [Duration]。
  DateTime? _customDeadline;

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _setSecureScreen(true);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _setSecureScreen(false);
    super.dispose();
  }

  /// 二维码是否已不可扫:OTP 窗口耗尽或 Key 已过期,任一命中。
  bool get _qrExpired {
    final deadline = _otpDeadline;
    if (deadline == null) return false;
    if (!DateTime.now().isBefore(deadline)) return true;
    return _payload?.isExpired ?? false;
  }

  Duration get _otpRemaining {
    final deadline = _otpDeadline;
    if (deadline == null) return Duration.zero;
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  // ---------- 有效期选择 ----------

  /// 预设芯片文案:整单位显示即可。
  String _presetChipLabel(BuildContext context, Duration? duration) {
    if (duration == null) return context.l10n.login_qrExpiryNever;
    if (duration.inDays >= 1 && duration.inHours % 24 == 0) {
      return context.l10n.login_qrExpiryDays(duration.inDays);
    }
    if (duration.inHours >= 1 && duration.inMinutes % 60 == 0) {
      return context.l10n.login_qrExpiryHours(duration.inHours);
    }
    return context.l10n.login_qrExpiryMinutes(duration.inMinutes);
  }

  /// 自定义固定时长文案:拼接非零的天/时/分。
  String _formatCustomDuration(BuildContext context, Duration duration) {
    final days = duration.inDays;
    final hours = duration.inHours % 24;
    final minutes = duration.inMinutes % 60;
    final parts = <String>[];
    if (days > 0) parts.add(context.l10n.login_qrExpiryDays(days));
    if (hours > 0) parts.add(context.l10n.login_qrExpiryHours(hours));
    if (minutes > 0) parts.add(context.l10n.login_qrExpiryMinutes(minutes));
    if (parts.isEmpty) {
      return context.l10n.login_qrExpiryMinutes(0);
    }
    return parts.join(' ');
  }

  String _customChipLabel(BuildContext context) {
    if (!_isCustomExpiry) return context.l10n.common_custom;

    final deadline = _customDeadline;
    if (deadline != null) {
      return context.l10n.login_qrExpiryUntil(
        TimeUtils.formatDetailTime(deadline),
      );
    }

    final custom = _selectedExpiry;
    if (custom != null && custom.inSeconds > 0) {
      return _formatCustomDuration(context, custom);
    }
    return context.l10n.common_custom;
  }

  /// 当前自定义选择是否可直接用于生成。
  bool get _hasValidCustomSelection {
    if (!_isCustomExpiry) return false;
    final deadline = _customDeadline;
    if (deadline != null) {
      return deadline.isAfter(DateTime.now());
    }
    final duration = _selectedExpiry;
    return duration != null && duration.inSeconds > 0;
  }

  /// 把当前 UI 选择换算成服务端需要的相对时长。
  ///
  /// 截止日期在**生成当下**换算,避免选完到点生成之间的时间漂移。
  Duration? _resolveExpiresIn() {
    if (!_isCustomExpiry) return _selectedExpiry;

    final deadline = _customDeadline;
    if (deadline != null) {
      final left = deadline.difference(DateTime.now());
      if (left.inSeconds <= 0) return null;
      return left;
    }
    return _selectedExpiry;
  }

  /// 改有效期后清掉已生成二维码,要求重新确认。
  void _invalidateGeneratedQr() {
    if (!_approved && _raw == null && _payload == null) return;
    _approved = false;
    _raw = null;
    _payload = null;
    _error = null;
    _otpDeadline = null;
    _ticker?.cancel();
  }

  void _selectPreset(Duration? duration) {
    setState(() {
      _isCustomExpiry = false;
      _selectedExpiry = duration;
      _customDeadline = null;
      _invalidateGeneratedQr();
    });
  }

  Future<void> _selectCustom() async {
    final picked = await showAppDialog<_CustomExpirySelection>(
      context: context,
      builder: (ctx) => _CustomExpiryDialog(
        initialDuration: _isCustomExpiry && _customDeadline == null
            ? _selectedExpiry
            : null,
        initialDeadline: _isCustomExpiry ? _customDeadline : null,
      ),
    );
    if (!mounted || picked == null) return;
    setState(() {
      _isCustomExpiry = true;
      if (picked.isDeadline) {
        _customDeadline = picked.deadline;
        _selectedExpiry = null;
      } else {
        _customDeadline = null;
        _selectedExpiry = picked.duration;
      }
      _invalidateGeneratedQr();
    });
  }

  // ---------- 生成 ----------

  /// 每次生成/重新生成前都必须二次确认。
  Future<void> _confirmAndGenerate() async {
    // 自定义模式但尚未填入有效选择时,先弹出自定义对话框
    if (_isCustomExpiry && !_hasValidCustomSelection) {
      await _selectCustom();
      if (!mounted) return;
      if (!_hasValidCustomSelection) return;
    }

    // 截止时间在确认前再校验一次,避免弹确认框时已过期
    if (_isCustomExpiry && _customDeadline != null) {
      if (!_customDeadline!.isAfter(DateTime.now())) {
        ToastService.showError(S.current.login_qrExpiryDeadlinePast);
        await _selectCustom();
        if (!mounted || !_hasValidCustomSelection) return;
      }
    }

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
    final expiresIn = _resolveExpiresIn();
    if (_isCustomExpiry && (expiresIn == null || expiresIn.inSeconds <= 0)) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _approved = false;
        _error = S.current.login_qrExpiryDeadlinePast;
        _raw = null;
        _payload = null;
        _otpDeadline = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await QrLoginService.instance.buildPayload(
        username: widget.username,
        expiresIn: expiresIn,
      );
      if (!mounted) return;
      setState(() {
        _raw = result.raw;
        _payload = result.payload;
        _otpDeadline = DateTime.now().add(_kOtpWindow);
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
        _otpDeadline = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = S.current.login_qrGenerateFailed;
        _loading = false;
        _raw = null;
        _payload = null;
        _otpDeadline = null;
      });
      debugPrint('[QrLoginSheet] 生成失败: $e');
    }
  }

  void _restartTicker() {
    _ticker?.cancel();
    if (_otpDeadline == null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (_qrExpired) _ticker?.cancel();
    });
  }

  String _formatRemaining(Duration d) {
    final total = d.inSeconds;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Key 有效期 chip 文案。
  String _keyExpiryChipLabel(BuildContext context, QrLoginPayload payload) {
    if (payload.neverExpires) return context.l10n.login_qrNeverExpires;
    return context.l10n.login_qrKeyExpiryUntil(
      TimeUtils.formatDetailTime(payload.expiresAt!.toLocal()),
    );
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showQrState = _approved || _loading;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, widget.inSheet ? 0 : 20, 24, 24),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(theme, scheme),
            const SizedBox(height: 4),
            Text(
              context.l10n.login_qrDisplayHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: showQrState
                  ? _buildQrState(theme, scheme)
                  : _buildConfigState(theme, scheme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, ColorScheme scheme) {
    return Row(
      children: [
        Icon(Symbols.qr_code_rounded, size: 22, color: scheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            context.l10n.login_qrDisplayTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (!widget.inSheet)
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Symbols.close_rounded, size: 20),
          ),
      ],
    );
  }

  // ---------- 配置态 ----------

  Widget _buildConfigState(ThemeData theme, ColorScheme scheme) {
    return Column(
      key: const ValueKey('config'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSecurityNote(theme, scheme),
        const SizedBox(height: 20),
        Text(
          context.l10n.login_qrExpiryLabel,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final opt in _kExpiryOptions) ...[
                ChoiceChip(
                  label: Text(_presetChipLabel(context, opt.duration)),
                  selected:
                      !_isCustomExpiry &&
                      _selectedExpiry == opt.duration &&
                      _customDeadline == null,
                  onSelected: _loading
                      ? null
                      : (selected) {
                          if (!selected) return;
                          _selectPreset(opt.duration);
                        },
                ),
                const SizedBox(width: 8),
              ],
              ChoiceChip(
                label: Text(_customChipLabel(context)),
                selected: _isCustomExpiry,
                onSelected: _loading
                    ? null
                    // 已选自定义时再点可重新编辑
                    : (_) => _selectCustom(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          context.l10n.login_qrExpiryHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _confirmAndGenerate,
          icon: const Icon(Symbols.qr_code_rounded),
          label: Text(context.l10n.login_qrGenerateAction),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
        ),
      ],
    );
  }

  Widget _buildSecurityNote(ThemeData theme, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Symbols.warning_rounded, size: 20, color: scheme.error),
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
    );
  }

  // ---------- 二维码态 ----------

  Widget _buildQrState(ThemeData theme, ColorScheme scheme) {
    final payload = _payload;

    return Column(
      key: const ValueKey('qr'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loading)
          const SizedBox(
            height: 288,
            child: Center(child: LoadingSpinner(size: 40)),
          )
        else if (_error != null)
          _buildErrorState(theme, scheme)
        else if (_raw != null) ...[
          Center(
            child: Stack(
              children: [
                _QrCard(data: _raw!, dimmed: _qrExpired),
                if (_qrExpired)
                  Positioned.fill(child: _buildExpiredOverlay(theme, scheme)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (!_qrExpired)
            Center(
              child: Text(
                context.l10n.login_qrOtpWindowRemaining(
                  _formatRemaining(_otpRemaining),
                ),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (payload != null) ...[
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                _InfoChip(
                  icon: payload.neverExpires
                      ? Symbols.all_inclusive_rounded
                      : Symbols.key_rounded,
                  label: _keyExpiryChipLabel(context, payload),
                ),
                if (payload.username.isNotEmpty)
                  _InfoChip(
                    icon: Symbols.person_rounded,
                    label: context.l10n.login_qrAccount(payload.username),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: () => setState(_invalidateGeneratedQr),
                icon: const Icon(Symbols.tune_rounded, size: 18),
                label: Text(context.l10n.login_qrAdjustExpiry),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _confirmAndGenerate,
                icon: const Icon(Symbols.refresh_rounded, size: 18),
                label: Text(context.l10n.login_qrRefresh),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildErrorState(ThemeData theme, ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
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

  Widget _buildExpiredOverlay(ThemeData theme, ColorScheme scheme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Material(
          color: scheme.scrim.withValues(alpha: 0.45),
          child: InkWell(
            onTap: _loading ? null : _confirmAndGenerate,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Symbols.refresh_rounded,
                    color: Colors.white,
                    size: 40,
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      context.l10n.login_qrExpiredTapRegenerate,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
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
}

/// 白底黑码卡片:白色 quiet zone 保证可扫,主题化托盘 + 描边融入深色模式。
class _QrCard extends StatelessWidget {
  const _QrCard({required this.data, required this.dimmed});

  final String data;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // TODO: 码中心 app logo 角标(仓库当前只有 SVG 资产,待有 raster logo 后加
    // QrImageView.embeddedImage)
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(28),
      ),
      child: AnimatedOpacity(
        opacity: dimmed ? 0.4 : 1,
        duration: const Duration(milliseconds: 200),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.4),
            ),
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
            data: data,
            version: QrVersions.auto,
            size: 224,
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
                ToastService.showError(S.current.login_qrGenerateFailed);
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
      ),
    );
  }
}

/// 元信息小胶囊(视觉同 invite_links_page 的 _MetaChip)。
class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

enum _CustomExpiryMode { duration, deadline }

/// 自定义 API Key 有效期对话框:固定时长 / 截止日期可切换。
class _CustomExpiryDialog extends StatefulWidget {
  const _CustomExpiryDialog({this.initialDuration, this.initialDeadline});

  final Duration? initialDuration;
  final DateTime? initialDeadline;

  @override
  State<_CustomExpiryDialog> createState() => _CustomExpiryDialogState();
}

class _CustomExpiryDialogState extends State<_CustomExpiryDialog> {
  late _CustomExpiryMode _mode;
  late final TextEditingController _daysController;
  late final TextEditingController _hoursController;
  late final TextEditingController _minutesController;
  DateTime? _deadline;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final initialDeadline = widget.initialDeadline;
    final initialDuration = widget.initialDuration;

    if (initialDeadline != null) {
      _mode = _CustomExpiryMode.deadline;
      _deadline = initialDeadline;
    } else {
      _mode = _CustomExpiryMode.duration;
      // 默认截止:1 小时后整分,便于用户点开即改
      _deadline = _defaultDeadline();
    }

    final duration = initialDuration;
    final days = duration?.inDays ?? 0;
    final hours = duration == null ? 0 : duration.inHours % 24;
    final minutes = duration == null ? 0 : duration.inMinutes % 60;
    _daysController = TextEditingController(text: days > 0 ? '$days' : '');
    _hoursController = TextEditingController(text: hours > 0 ? '$hours' : '');
    _minutesController = TextEditingController(
      text: minutes > 0 ? '$minutes' : '',
    );
  }

  @override
  void dispose() {
    _daysController.dispose();
    _hoursController.dispose();
    _minutesController.dispose();
    super.dispose();
  }

  DateTime _defaultDeadline() {
    final raw = DateTime.now().add(const Duration(hours: 1));
    // 对齐到分钟,秒清零
    return DateTime(raw.year, raw.month, raw.day, raw.hour, raw.minute);
  }

  int _parseField(TextEditingController controller) {
    final raw = controller.text.trim();
    if (raw.isEmpty) return 0;
    return int.tryParse(raw) ?? -1;
  }

  Duration? _readDuration() {
    final days = _parseField(_daysController);
    final hours = _parseField(_hoursController);
    final minutes = _parseField(_minutesController);
    if (days < 0 || hours < 0 || minutes < 0) return null;
    if (hours > 23 || minutes > 59) return null;
    final total = Duration(days: days, hours: hours, minutes: minutes);
    if (total.inSeconds <= 0) return null;
    return total;
  }

  /// 切换模式时尽量把当前值带过去,减少重填。
  void _switchMode(_CustomExpiryMode next) {
    if (next == _mode) return;
    setState(() {
      _errorText = null;
      if (next == _CustomExpiryMode.deadline) {
        // 时长 → 截止:now + duration
        final duration = _readDuration();
        if (duration != null) {
          final target = DateTime.now().add(duration);
          _deadline = DateTime(
            target.year,
            target.month,
            target.day,
            target.hour,
            target.minute,
          );
        } else {
          _deadline ??= _defaultDeadline();
        }
      } else {
        // 截止 → 时长:剩余量拆成天/时/分(向下取整到分)
        final deadline = _deadline;
        if (deadline != null) {
          var left = deadline.difference(DateTime.now());
          if (left.isNegative) left = Duration.zero;
          final totalMinutes = left.inMinutes;
          final days = totalMinutes ~/ (24 * 60);
          final hours = (totalMinutes % (24 * 60)) ~/ 60;
          final minutes = totalMinutes % 60;
          _daysController.text = days > 0 ? '$days' : '';
          _hoursController.text = hours > 0 ? '$hours' : '';
          _minutesController.text = minutes > 0 ? '$minutes' : '';
        }
      }
      _mode = next;
    });
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final initial = (_deadline != null && _deadline!.isAfter(now))
        ? _deadline!
        : _defaultDeadline();

    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year, now.month, now.day),
      // 站点通常有 max_user_api_key_expiry_days;给足 10 年余量由服务端裁剪
      lastDate: now.add(const Duration(days: 3650)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;

    setState(() {
      _deadline = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      _errorText = null;
    });
  }

  void _submit() {
    if (_mode == _CustomExpiryMode.duration) {
      final total = _readDuration();
      if (total == null) {
        setState(() => _errorText = S.current.login_qrExpiryCustomInvalid);
        return;
      }
      Navigator.pop(context, _CustomExpirySelection.duration(total));
      return;
    }

    final deadline = _deadline;
    if (deadline == null || !deadline.isAfter(DateTime.now())) {
      setState(() => _errorText = S.current.login_qrExpiryDeadlinePast);
      return;
    }
    Navigator.pop(context, _CustomExpirySelection.deadline(deadline));
  }

  Widget _numberField({
    required TextEditingController controller,
    required String unit,
  }) {
    return Expanded(
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.next,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(5),
        ],
        decoration: InputDecoration(
          labelText: unit,
          border: const OutlineInputBorder(),
        ),
        onChanged: (_) {
          if (_errorText != null) {
            setState(() => _errorText = null);
          }
        },
        onSubmitted: (_) => _submit(),
      ),
    );
  }

  Widget _buildDurationBody(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.login_qrExpiryCustomHint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _numberField(
              controller: _daysController,
              unit: l10n.login_qrExpiryUnitDay,
            ),
            const SizedBox(width: 8),
            _numberField(
              controller: _hoursController,
              unit: l10n.login_qrExpiryUnitHour,
            ),
            const SizedBox(width: 8),
            _numberField(
              controller: _minutesController,
              unit: l10n.login_qrExpiryUnitMinute,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDeadlineBody(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final deadline = _deadline;
    final label = deadline == null
        ? l10n.login_qrExpiryPickDeadline
        : TimeUtils.formatDetailTime(deadline);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.login_qrExpiryDeadlineHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _pickDeadline,
          icon: const Icon(Symbols.event_rounded),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.login_qrExpiryCustomTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<_CustomExpiryMode>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: _CustomExpiryMode.duration,
                  label: Text(l10n.login_qrExpiryModeDuration),
                  icon: const Icon(Symbols.timelapse_rounded, size: 18),
                ),
                ButtonSegment(
                  value: _CustomExpiryMode.deadline,
                  label: Text(l10n.login_qrExpiryModeDeadline),
                  icon: const Icon(Symbols.event_rounded, size: 18),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) {
                if (selection.isEmpty) return;
                _switchMode(selection.first);
              },
            ),
            const SizedBox(height: 16),
            if (_mode == _CustomExpiryMode.duration)
              _buildDurationBody(context)
            else
              _buildDeadlineBody(context),
            if (_errorText != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.common_confirm),
        ),
      ],
    );
  }
}
