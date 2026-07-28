import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/s.dart';
import '../services/qr_login_service.dart';
import '../services/toast_service.dart';
import '../utils/dialog_utils.dart';
import '../utils/time_utils.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 可选 API Key 有效期预设。
///
/// `null` 表示不过期(默认)。自定义时长/截止不在此列表,由 UI 单独处理。
const List<({String labelKey, Duration? duration})> _kExpiryOptions = [
  (labelKey: 'never', duration: null),
  (labelKey: '1h', duration: Duration(hours: 1)),
  (labelKey: '24h', duration: Duration(hours: 24)),
  (labelKey: '7d', duration: Duration(days: 7)),
  (labelKey: '30d', duration: Duration(days: 30)),
];

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

/// 已登录设备:展示用于另一台设备扫码登录的二维码。
///
/// 二维码携带新创建的 User API Key + 一次性 OTP;
/// 生成前必须用户二次确认;可选设置 API Key 过期时间(默认不过期),
/// 支持预设,或自定义「固定时长 / 截止日期」。
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

  /// 是否选中「自定义」芯片(与预设互斥)。
  bool _isCustomExpiry = false;

  /// 自定义固定时长;`null` 在非自定义模式下表示不过期。
  Duration? _selectedExpiry;

  /// 自定义绝对截止时间(本地时区)。生成时再换算为相对 [Duration]。
  DateTime? _customDeadline;

  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

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
    if (_isCustomExpiry &&
        (expiresIn == null || expiresIn.inSeconds <= 0)) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _approved = false;
        _error = S.current.login_qrExpiryDeadlinePast;
        _raw = null;
        _payload = null;
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
                      ChoiceChip(
                        label: Text(_customChipLabel(context)),
                        selected: _isCustomExpiry,
                        onSelected: _loading
                            ? null
                            : (_) {
                                // 已选自定义时再点可重新编辑
                                _selectCustom();
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
                    if (_isCustomExpiry && _customDeadline != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        context.l10n.login_qrExpiryUntil(
                          TimeUtils.formatDetailTime(_customDeadline),
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
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
