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
import 'package:m3e_ui/m3e_ui.dart';

/// OTP 一次性登录令牌的服务端 TTL(Redis setex 10 分钟,兑换即焚)。
/// 二维码的真实可扫窗口以此为准。
///
/// 注:服务端 user_api_keys#create 不支持任何过期参数(表里只有
/// revoked_at,无 expires_at),API Key 本身不过期,回收只能靠站点级
/// 定时任务或用户手动 revoke。因此 UI 不提供"有效期"选择——那只会是
/// 客户端幻觉。
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

/// 弹层内容:配置态(安全说明 → 生成)⇄ 二维码态(码卡 + OTP 倒计时)。
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

  /// 扫码端已完成登录(分享 key 从本人 Apps 列表消失)。
  bool _consumed = false;

  /// OTP 扫码窗口截止(生成时刻 + 10 分钟)。这是二维码的真实有效期。
  DateTime? _otpDeadline;

  Timer? _ticker;

  /// 轮询扫码结果:分享 key 消失 = 对方已登录并自我吊销。
  Timer? _pollTimer;
  bool _pollInFlight = false;

  @override
  void initState() {
    super.initState();
    _setSecureScreen(true);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pollTimer?.cancel();
    // 码未被消费就关闭弹层:尽力撤销刚创建的 key,不留孤儿凭据。
    // (重新生成无需处理——同 client_id 再 create 时服务端 destroy_all 旧 key)
    final leftoverKey = _payload?.apiKey;
    if (!_consumed && leftoverKey != null && leftoverKey.isNotEmpty) {
      unawaited(QrLoginService.instance.revokeSharedKey(leftoverKey));
    }
    _setSecureScreen(false);
    super.dispose();
  }

  /// 二维码是否已不可扫(OTP 窗口耗尽)。
  bool get _qrExpired {
    final deadline = _otpDeadline;
    if (deadline == null) return false;
    return !DateTime.now().isBefore(deadline);
  }

  Duration get _otpRemaining {
    final deadline = _otpDeadline;
    if (deadline == null) return Duration.zero;
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  // ---------- 生成 ----------

  /// 每次生成/重新生成前都必须二次确认。
  Future<void> _confirmAndGenerate() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.login_qrConfirmTitle),
        // 桌面宽窗口下 AlertDialog 会被长文案撑满,限宽保持可读行长
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Text(ctx.l10n.login_qrConfirmMessage),
        ),
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
      );
      if (!mounted) return;
      setState(() {
        _raw = result.raw;
        _payload = result.payload;
        _otpDeadline = DateTime.now().add(_kOtpWindow);
        _loading = false;
        _consumed = false;
      });
      _restartTicker();
      _restartPolling();
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
      if (_qrExpired) {
        _ticker?.cancel();
        _pollTimer?.cancel();
      }
    });
  }

  /// 每 3 秒查一次分享 key 是否仍存活;消失 = 扫码端已登录并自我吊销。
  /// (Discourse 无扫码回执机制,轮询本人 /u/:username.json 的
  /// user_api_keys 是唯一可用信号;仅本人可见,无隐私外泄)
  void _restartPolling() {
    _pollTimer?.cancel();
    final username = _payload?.username ?? '';
    if (username.isEmpty) return;
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted || _pollInFlight || _consumed || _qrExpired) return;
      _pollInFlight = true;
      try {
        final alive = await QrLoginService.instance.isSharedKeyAlive(
          username: username,
        );
        if (!mounted || alive != false) return;
        _pollTimer?.cancel();
        _ticker?.cancel();
        setState(() => _consumed = true);
      } finally {
        _pollInFlight = false;
      }
    });
  }

  String _formatRemaining(Duration d) {
    final total = d.inSeconds;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
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
                _QrCard(data: _raw!, dimmed: _qrExpired || _consumed),
                if (_consumed)
                  Positioned.fill(child: _buildConsumedOverlay(theme, scheme))
                else if (_qrExpired)
                  Positioned.fill(child: _buildExpiredOverlay(theme, scheme)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_consumed)
            Center(
              child: Text(
                context.l10n.login_qrScannedSuccess,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else if (!_qrExpired)
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
          if (payload != null && payload.username.isNotEmpty) ...[
            const SizedBox(height: 12),
            Center(
              child: _InfoChip(
                icon: Symbols.person_rounded,
                label: context.l10n.login_qrAccount(payload.username),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Center(
            child: _consumed
                ? FilledButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(context.l10n.common_done),
                  )
                : TextButton.icon(
                    onPressed: _confirmAndGenerate,
                    icon: const Icon(Symbols.refresh_rounded, size: 18),
                    label: Text(context.l10n.login_qrRefresh),
                  ),
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

  /// 扫码成功覆盖层:对方设备已用此码完成登录。
  Widget _buildConsumedOverlay(ThemeData theme, ColorScheme scheme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Material(
          color: scheme.scrim.withValues(alpha: 0.45),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Symbols.check_circle_rounded,
                  color: Colors.white,
                  size: 40,
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    context.l10n.login_qrScannedSuccess,
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
