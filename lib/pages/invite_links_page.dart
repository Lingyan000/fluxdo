import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../models/invite_link.dart';
import '../providers/discourse_providers.dart';
import '../services/toast_service.dart';
import '../utils/time_utils.dart';

enum _InviteExpiryPreset { days1, days7, days30, days90, never }

extension on _InviteExpiryPreset {
  String get label {
    switch (this) {
      case _InviteExpiryPreset.days1:
        return '1 天';
      case _InviteExpiryPreset.days7:
        return '7 天';
      case _InviteExpiryPreset.days30:
        return '30 天';
      case _InviteExpiryPreset.days90:
        return '90 天';
      case _InviteExpiryPreset.never:
        return '从不';
    }
  }

  Duration? get duration {
    switch (this) {
      case _InviteExpiryPreset.days1:
        return const Duration(days: 1);
      case _InviteExpiryPreset.days7:
        return const Duration(days: 7);
      case _InviteExpiryPreset.days30:
        return const Duration(days: 30);
      case _InviteExpiryPreset.days90:
        return const Duration(days: 90);
      case _InviteExpiryPreset.never:
        return null;
    }
  }
}

class InviteLinksPage extends ConsumerStatefulWidget {
  const InviteLinksPage({super.key});

  @override
  ConsumerState<InviteLinksPage> createState() => _InviteLinksPageState();
}

class _InviteLinksPageState extends ConsumerState<InviteLinksPage> {
  static const int _maxRedemptionsAllowed = 1;
  static const String _defaultRateLimitWait = '21 小时';

  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _restrictionController = TextEditingController();

  _InviteExpiryPreset _expiryPreset = _InviteExpiryPreset.days1;
  bool _showAdvancedOptions = false;
  bool _isSubmitting = false;
  String? _error;
  InviteLinkResponse? _latestInvite;

  @override
  void dispose() {
    _descriptionController.dispose();
    _restrictionController.dispose();
    super.dispose();
  }

  DateTime? get _expiresAt {
    final duration = _expiryPreset.duration;
    if (duration == null) return null;
    return DateTime.now().add(duration);
  }

  String get _summaryText {
    if (_expiryPreset == _InviteExpiryPreset.never) {
      return '链接最多可用于 1 个用户，并且永不过期。';
    }
    return '链接最多可用于 1 个用户，并且将在 ${_expiryPreset.label} 后到期。';
  }

  bool get _hasInviteLink =>
      (_latestInvite?.inviteLink.trim().isNotEmpty ?? false);

  Future<void> _createInviteLink({bool useAdvancedOptions = false}) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) {
      ToastService.showError('请先登录');
      return;
    }
    if (user.trustLevel < 3) {
      ToastService.showError('当前账号尚未达到 L3，无法创建邀请链接');
      return;
    }

    final description = useAdvancedOptions
        ? _descriptionController.text.trim()
        : '';
    final email = useAdvancedOptions ? _restrictionController.text.trim() : '';

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      final result = await ref
          .read(discourseServiceProvider)
          .createInviteLink(
            maxRedemptionsAllowed: _maxRedemptionsAllowed,
            expiresAt: _expiresAt,
            description: description,
            email: email.isEmpty ? null : email,
          );
      if (!mounted) return;
      setState(() {
        _latestInvite = result.inviteLink.trim().isEmpty ? null : result;
      });
      ToastService.showSuccess(
        result.inviteLink.trim().isNotEmpty ? '邀请链接已生成' : '邀请已创建',
      );
    } catch (error) {
      if (!mounted) return;
      final message = _normalizeErrorMessage(error);
      setState(() => _error = message);
      ToastService.showError(message);
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _copyInviteLink() async {
    final inviteLink = _latestInvite?.inviteLink;
    if (inviteLink == null || inviteLink.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: inviteLink));
    ToastService.showSuccess('邀请链接已复制');
  }

  void _shareInviteLink() {
    final inviteLink = _latestInvite?.inviteLink;
    if (inviteLink == null || inviteLink.isEmpty) return;
    SharePlus.instance.share(
      ShareParams(text: inviteLink, subject: 'Linux.do 邀请链接'),
    );
  }

  String _normalizeErrorMessage(Object error) {
    final message = _extractErrorMessage(error);
    final rateLimitMessage = _buildRateLimitMessage(error, message);
    if (rateLimitMessage != null) {
      return rateLimitMessage;
    }
    if (message.contains('You are not permitted') ||
        message.contains('not permitted')) {
      return '服务端拒绝了当前账号的邀请权限';
    }
    return message.isEmpty ? '生成邀请链接失败' : message;
  }

  String _extractErrorMessage(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map &&
          data['errors'] is List &&
          (data['errors'] as List).isNotEmpty) {
        return (data['errors'] as List).join('\n');
      }
      if (data is Map && data['message'] is String) {
        return data['message'] as String;
      }
      if (data is String && data.trim().isNotEmpty) {
        return data.trim();
      }
      return (error.message ?? error.toString()).trim();
    }
    return error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '').trim();
  }

  String? _buildRateLimitMessage(Object error, String message) {
    final normalized = message.toLowerCase();
    final dioError = error is DioException ? error : null;
    final isRateLimited =
        normalized.contains('too many times') ||
        normalized.contains('rate limit') ||
        normalized.contains('request too many') ||
        message.contains('请求过多') ||
        message.contains('次数过多') ||
        dioError?.response?.statusCode == 429;

    if (!isRateLimited) return null;

    if (message.contains('您执行此操作的次数过多')) {
      return message.startsWith('出错了：') ? message : '出错了：$message';
    }

    final waitText =
        _extractWaitText(message) ??
        _extractWaitTextFromData(dioError?.response?.data) ??
        _defaultRateLimitWait;
    return '出错了：您执行此操作的次数过多。请等待 $waitText 后再试。';
  }

  String? _extractWaitTextFromData(dynamic data) {
    if (data is Map) {
      final errors = data['errors'];
      if (errors is List) {
        for (final item in errors) {
          final text = _extractWaitText(item.toString());
          if (text != null) return text;
        }
      }
      final extras = data['extras'];
      if (extras is Map) {
        final waitSecondsRaw = extras['wait_seconds'] ?? extras['time_left'];
        final waitSeconds = int.tryParse(waitSecondsRaw?.toString() ?? '');
        if (waitSeconds != null && waitSeconds > 0) {
          return _formatWaitDuration(waitSeconds);
        }
      }
    }
    if (data is String) {
      return _extractWaitText(data);
    }
    return null;
  }

  String? _extractWaitText(String message) {
    final chineseMatch = RegExp(
      r'请等待\s*([0-9]+\s*(?:小时|分钟|天|秒))\s*后再试',
    ).firstMatch(message);
    if (chineseMatch != null) {
      return chineseMatch.group(1);
    }

    final englishMatch = RegExp(
      r'Please wait\s+(\d+)\s+(second|seconds|minute|minutes|hour|hours|day|days)\s+before trying again',
      caseSensitive: false,
    ).firstMatch(message);
    if (englishMatch != null) {
      final value = int.tryParse(englishMatch.group(1) ?? '');
      final unit = englishMatch.group(2)?.toLowerCase();
      if (value == null || unit == null) return null;
      if (unit.startsWith('day')) return '$value 天';
      if (unit.startsWith('hour')) return '$value 小时';
      if (unit.startsWith('minute')) return '$value 分钟';
      return '$value 秒';
    }

    return null;
  }

  String _formatWaitDuration(int seconds) {
    if (seconds >= 86400) {
      return '${(seconds / 86400).ceil()} 天';
    }
    if (seconds >= 3600) {
      return '${(seconds / 3600).ceil()} 小时';
    }
    if (seconds >= 60) {
      return '${(seconds / 60).ceil()} 分钟';
    }
    return '$seconds 秒';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('邀请链接')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSummaryCard(theme),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _buildErrorCard(theme),
          ],
          if (_showAdvancedOptions) ...[
            const SizedBox(height: 16),
            _buildAdvancedOptionsCard(theme),
          ],
          if (_hasInviteLink) ...[
            const SizedBox(height: 16),
            _buildResultCard(theme),
          ],
        ],
      ),
    );
  }

  Widget _buildSummaryCard(ThemeData theme) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '创建邀请链接',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _summaryText,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () =>
                  setState(() => _showAdvancedOptions = !_showAdvancedOptions),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              child: Text(_showAdvancedOptions ? '收起链接选项' : '编辑链接选项或通过电子邮件发送。'),
            ),
            if (!_showAdvancedOptions) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isSubmitting ? null : () => _createInviteLink(),
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link_rounded),
                  label: Text(_isSubmitting ? '创建中...' : '创建链接'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAdvancedOptionsCard(ThemeData theme) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '邀请成员',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              maxLength: 100,
              decoration: const InputDecoration(
                labelText: '描述 (可选)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _restrictionController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: '限制为 (可选)',
                hintText: 'name@example.com 或者 example.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '最大使用次数',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _buildReadOnlyField(theme, value: '1'),
            const SizedBox(height: 16),
            Text(
              '有效截止时间',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _InviteExpiryPreset.values.map((preset) {
                return ChoiceChip(
                  label: Text(preset.label),
                  selected: _expiryPreset == preset,
                  onSelected: (_) => setState(() => _expiryPreset = preset),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isSubmitting
                    ? null
                    : () => _createInviteLink(useAdvancedOptions: true),
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link_rounded),
                label: Text(_isSubmitting ? '创建中...' : '创建链接'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _error!,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }

  Widget _buildReadOnlyField(ThemeData theme, {required String value}) {
    return InputDecorator(
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      ),
      child: Row(
        children: [
          Expanded(child: Text(value, style: theme.textTheme.bodyLarge)),
          Text(
            '固定',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard(ThemeData theme) {
    final invite = _latestInvite!;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '最新生成结果',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.45,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                invite.inviteLink,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MetaChip(
                  icon: Icons.repeat_rounded,
                  label:
                      '可用 ${invite.invite?.maxRedemptionsAllowed ?? _maxRedemptionsAllowed} 次',
                ),
                if (invite.invite?.expiresAt != null)
                  _MetaChip(
                    icon: Icons.schedule_rounded,
                    label:
                        '截止 ${TimeUtils.formatDetailTime(invite.invite!.expiresAt)}',
                  )
                else
                  const _MetaChip(
                    icon: Icons.all_inclusive_rounded,
                    label: '无过期时间',
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _copyInviteLink,
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('复制链接'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _shareInviteLink,
                    icon: const Icon(Icons.share_rounded),
                    label: const Text('分享'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MetaChip({required this.icon, required this.label});

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
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
