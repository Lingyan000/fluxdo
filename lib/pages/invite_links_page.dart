import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../constants.dart';
import '../models/invite_link.dart';
import '../models/user.dart';
import '../providers/discourse_providers.dart';
import '../providers/theme_provider.dart';
import '../services/network/exceptions/api_exception.dart';
import '../services/toast_service.dart';
import '../utils/time_utils.dart';
import '../l10n/s.dart';

enum _InviteExpiryPreset { days1, days7, days30, days90, never }

extension on _InviteExpiryPreset {
  String get label {
    switch (this) {
      case _InviteExpiryPreset.days1:
        return S.current.time_days(1);
      case _InviteExpiryPreset.days7:
        return S.current.time_days(7);
      case _InviteExpiryPreset.days30:
        return S.current.time_days(30);
      case _InviteExpiryPreset.days90:
        return S.current.time_days(90);
      case _InviteExpiryPreset.never:
        return S.current.invite_never;
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
  static final String _defaultRateLimitWait = S.current.time_hours(21);
  static const Duration _inviteCooldownDuration = Duration(hours: 24);
  static const String _inviteCacheKeyPrefix = 'invite_link_cache:';

  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _restrictionController = TextEditingController();

  _InviteExpiryPreset _expiryPreset = _InviteExpiryPreset.days1;
  bool _showAdvancedOptions = false;
  bool _isSubmitting = false;
  bool _isLoadingPending = false;
  InviteLinkResponse? _latestInvite;
  ProviderSubscription<AsyncValue<User?>>? _userSub;
  bool _hasRequestedInitialRefresh = false;

  @override
  void initState() {
    super.initState();
    _userSub = ref.listenManual<AsyncValue<User?>>(
      currentUserProvider,
      (_, next) {
        final user = next.value;
        if (user == null) return;
        _applyCachedInvite(user.username);
        if (!_hasRequestedInitialRefresh) {
          _hasRequestedInitialRefresh = true;
          Future.microtask(() => _loadPendingInvites(force: true));
        }
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _restrictionController.dispose();
    _userSub?.close();
    super.dispose();
  }

  DateTime? get _expiresAt {
    final duration = _expiryPreset.duration;
    if (duration == null) return null;
    return DateTime.now().add(duration);
  }

  String get _summaryText {
    if (_expiryPreset == _InviteExpiryPreset.days1) {
      return S.current.invite_summaryDay1;
    }
    if (_expiryPreset == _InviteExpiryPreset.never) {
      return S.current.invite_summaryNever;
    }
    return S.current.invite_summaryExpiry(_expiryPreset.label);
  }

  String? get _effectiveInviteLink {
    final link = _latestInvite?.inviteLink.trim() ?? '';
    if (link.isNotEmpty) return link;
    final key = _latestInvite?.invite?.inviteKey?.trim();
    if (key != null && key.isNotEmpty) {
      return _buildInviteLink(key);
    }
    return null;
  }

  bool get _hasInviteLink => (_effectiveInviteLink?.isNotEmpty ?? false);

  String _buildInviteLink(String key) {
    return '${AppConstants.baseUrl}/invites/$key';
  }

  InviteLinkResponse _resolveInviteLink(InviteLinkResponse invite) {
    final link = invite.inviteLink.trim();
    if (link.isNotEmpty) return invite;
    final key = invite.invite?.inviteKey?.trim();
    if (key != null && key.isNotEmpty) {
      return InviteLinkResponse(
        inviteLink: _buildInviteLink(key),
        invite: invite.invite,
      );
    }
    return invite;
  }

  InviteLinkResponse? _pickLatestInvite(List<InviteLinkResponse> invites) {
    if (invites.isEmpty) return null;
    return invites.reduce((a, b) {
      final aTime =
          a.invite?.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime =
          b.invite?.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.isAfter(aTime) ? b : a;
    });
  }

  String _inviteIdentity(InviteLinkResponse? invite) {
    if (invite == null) return '';
    final key = invite.invite?.inviteKey?.trim();
    if (key != null && key.isNotEmpty) {
      return 'key:$key';
    }
    final link = invite.inviteLink.trim();
    if (link.isNotEmpty) {
      return 'link:$link';
    }
    return '';
  }

  bool _isSameInvite(InviteLinkResponse? a, InviteLinkResponse? b) {
    return _inviteIdentity(a) == _inviteIdentity(b);
  }

  String _inviteCacheKey(String username) {
    return '$_inviteCacheKeyPrefix$username';
  }

  InviteLinkResponse? _readCachedInvite(String username) {
    final prefs = ref.read(sharedPreferencesProvider);
    final cached = prefs.getString(_inviteCacheKey(username));
    if (cached == null || cached.isEmpty) return null;
    try {
      final decoded = jsonDecode(cached);
      if (decoded is Map<String, dynamic>) {
        return _resolveInviteLink(InviteLinkResponse.fromJson(decoded));
      }
      if (decoded is Map) {
        return _resolveInviteLink(
          InviteLinkResponse.fromJson(Map<String, dynamic>.from(decoded)),
        );
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveInviteCache(
    String username,
    InviteLinkResponse invite,
  ) async {
    final prefs = ref.read(sharedPreferencesProvider);
    final payload = jsonEncode(invite.toJson());
    await prefs.setString(_inviteCacheKey(username), payload);
  }

  Future<void> _clearInviteCache(String username) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.remove(_inviteCacheKey(username));
  }

  void _applyCachedInvite(String username) {
    if (_latestInvite != null) return;
    final cached = _readCachedInvite(username);
    if (cached == null || !mounted) return;
    setState(() => _latestInvite = cached);
  }

  Future<void> _loadPendingInvites({bool force = false}) async {
    if (_isLoadingPending) return;
    final user = ref.read(currentUserProvider).value;
    if (user == null) return;

    setState(() => _isLoadingPending = true);
    try {
      final invites = await ref
          .read(discourseServiceProvider)
          .getPendingInvites(user.username);
      final latest = _pickLatestInvite(invites);
      final resolved = latest != null ? _resolveInviteLink(latest) : null;
      if (!_isSameInvite(_latestInvite, resolved) && mounted) {
        setState(() => _latestInvite = resolved);
        if (resolved != null) {
          await _saveInviteCache(user.username, resolved);
        } else {
          await _clearInviteCache(user.username);
        }
      }
    } catch (_) {
      // 忽略失败，避免干扰手动创建流程
    } finally {
      if (mounted) {
        setState(() => _isLoadingPending = false);
      }
    }
  }

  Future<void> _createInviteLink({bool useAdvancedOptions = false}) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) {
      ToastService.showError(S.current.common_pleaseLogin);
      return;
    }
    if (user.trustLevel < 3) {
      ToastService.showError(S.current.invite_trustLevelTooLow);
      return;
    }

    final description = useAdvancedOptions
        ? _descriptionController.text.trim()
        : '';
    final email = useAdvancedOptions ? _restrictionController.text.trim() : '';

    setState(() => _isSubmitting = true);

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
      final resolved = _resolveInviteLink(result);
      if (resolved.inviteLink.trim().isNotEmpty) {
        setState(() => _latestInvite = resolved);
        await _saveInviteCache(user.username, resolved);
      } else {
        await _loadPendingInvites(force: true);
      }
      ToastService.showSuccess(
        resolved.inviteLink.trim().isNotEmpty ? S.current.invite_linkGenerated : S.current.invite_created,
      );
    } catch (error) {
      if (!mounted) return;
      final message = _normalizeErrorMessage(error);
      ToastService.showError(message);
      if (_latestInvite == null) {
        await _loadPendingInvites(force: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _copyInviteLink() async {
    final inviteLink = _effectiveInviteLink;
    if (inviteLink == null || inviteLink.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: inviteLink));
    ToastService.showSuccess(S.current.invite_linkCopied);
  }

  void _shareInviteLink() {
    final inviteLink = _effectiveInviteLink;
    if (inviteLink == null || inviteLink.isEmpty) return;
    SharePlus.instance.share(
      ShareParams(text: inviteLink, subject: S.current.invite_shareSubject),
    );
  }

  String _normalizeErrorMessage(Object error) {
    if (error is RateLimitException) {
      final waitSeconds = error.retryAfterSeconds;
      final waitFromMessage = _extractWaitText(error.toString());
      final estimatedWait = _estimateInviteCooldownWait();
      final waitText = waitSeconds != null && waitSeconds > 0
          ? _formatWaitDuration(waitSeconds)
          : (waitFromMessage ?? estimatedWait ?? _defaultRateLimitWait);
      return S.current.invite_rateLimited(waitText);
    }

    final message = _extractErrorMessage(error);
    final rateLimitMessage = _buildRateLimitMessage(error, message);
    if (rateLimitMessage != null) {
      return rateLimitMessage;
    }
    if (message.contains('You are not permitted') ||
        message.contains('not permitted')) {
      return S.current.invite_permissionDenied;
    }
    return message.isEmpty ? S.current.invite_createFailed : message;
  }

  String _extractErrorMessage(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map &&
          data['errors'] is List &&
          (data['errors'] as List).isNotEmpty) {
        return _cleanErrorMessage((data['errors'] as List).join('\n'));
      }
      if (data is Map && data['message'] is String) {
        return _cleanErrorMessage(data['message'] as String);
      }
      if (data is String && data.trim().isNotEmpty) {
        return _cleanErrorMessage(data.trim());
      }
      return _cleanErrorMessage((error.message ?? error.toString()).trim());
    }
    return _cleanErrorMessage(
      error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '').trim(),
    );
  }

  String _cleanErrorMessage(String message) {
    var result = message.trim();
    result = result.replaceFirst(RegExp(r'^DioException[^:]*:\s*'), '');
    result = result.replaceFirst(RegExp(r'^\s*null\s*Error\s*'), '');
    result = result.replaceFirst(RegExp(r'^\s*Error\s*'), '');
    return result.trim();
  }

  String? _buildRateLimitMessage(Object error, String message) {
    final normalized = message.toLowerCase();
    final dioError = error is DioException ? error : null;
    final isRateLimited =
        normalized.contains('too many times') ||
        normalized.contains('too many requests') ||
        normalized.contains('rate limit') ||
        normalized.contains('rate limited') ||
        normalized.contains('request too many') ||
        normalized.contains('请求过多') ||
        normalized.contains('请求过于频繁') ||
        normalized.contains('请求频繁') ||
        normalized.contains('次数过多') ||
        normalized.contains('请稍候') ||
        dioError?.response?.statusCode == 429;

    if (!isRateLimited) return null;

    if (message.contains('您执行此操作的次数过多')) {
      if (message.startsWith('出错了：')) {
        return message;
      }
      final cleaned = message.replaceFirst(RegExp(r'^[:：]+'), '');
      return '出错了：$cleaned';
    }

    final waitText =
        _extractWaitText(message) ??
        _extractWaitTextFromData(dioError?.response?.data) ??
        _extractWaitTextFromHeaders(dioError?.response?.headers) ??
        _estimateInviteCooldownWait() ??
        _defaultRateLimitWait;
    if (waitText == S.current.time_hours(21)) {
      return S.current.invite_rateLimited(S.current.time_hours(21));
    }
    return S.current.invite_rateLimited(waitText);
  }

  String? _estimateInviteCooldownWait() {
    final createdAt = _latestInvite?.invite?.createdAt;
    if (createdAt == null) return null;
    final elapsed = DateTime.now().difference(createdAt);
    final remaining = _inviteCooldownDuration - elapsed;
    if (remaining.inSeconds <= 0) return null;
    return _formatWaitDuration(remaining.inSeconds);
  }

  String? _extractWaitTextFromHeaders(Headers? headers) {
    if (headers == null) return null;
    final retryAfter =
        headers.value('retry-after') ?? headers.value('Retry-After');
    final retrySeconds = int.tryParse(retryAfter ?? '');
    if (retrySeconds != null && retrySeconds > 0) {
      return _formatWaitDuration(retrySeconds);
    }

    final resetValue = headers.value('x-ratelimit-reset') ??
        headers.value('ratelimit-reset') ??
        headers.value('x-rate-limit-reset') ??
        headers.value('X-RateLimit-Reset');
    final resetSeconds = int.tryParse(resetValue ?? '');
    if (resetSeconds != null && resetSeconds > 0) {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final delta = resetSeconds > 1000000000
          ? (resetSeconds - nowSeconds)
          : resetSeconds;
      if (delta > 0) {
        return _formatWaitDuration(delta);
      }
    }
    return null;
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
      if (unit.startsWith('day')) return S.current.time_days(value);
      if (unit.startsWith('hour')) return S.current.time_hours(value);
      if (unit.startsWith('minute')) return S.current.time_minutes(value);
      return S.current.time_seconds(value);
    }

    return null;
  }

  String _formatWaitDuration(int seconds) {
    if (seconds >= 86400) {
      return S.current.time_days((seconds / 86400).ceil());
    }
    if (seconds >= 3600) {
      return S.current.time_hours((seconds / 3600).ceil());
    }
    if (seconds >= 60) {
      return S.current.time_minutes((seconds / 60).ceil());
    }
    return S.current.time_seconds(seconds);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.invite_title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSummaryCard(theme),
          if (_showAdvancedOptions) ...[
            const SizedBox(height: 16),
            _buildAdvancedOptionsCard(theme),
          ],
          if (_hasInviteLink) ...[
            const SizedBox(height: 16),
            _buildResultCard(theme),
          ] else if (!_isLoadingPending) ...[
            const SizedBox(height: 16),
            _buildEmptyStateCard(theme),
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
              context.l10n.invite_createLink,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
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
              child: Text(_showAdvancedOptions ? context.l10n.invite_collapseOptions : context.l10n.invite_expandOptions),
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
                  label: Text(_isSubmitting ? context.l10n.invite_creating : context.l10n.invite_createLink),
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
              context.l10n.invite_inviteMembers,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              maxLength: 100,
              decoration: InputDecoration(
                labelText: context.l10n.invite_description,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _restrictionController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: context.l10n.invite_restriction,
                helperText: context.l10n.invite_restrictionHelper,
                hintText: context.l10n.invite_restrictionHint,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n.invite_maxRedemptions,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            _buildReadOnlyField(theme, value: '1'),
            const SizedBox(height: 16),
            Text(
              context.l10n.invite_expiryTime,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w500,
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
                label: Text(_isSubmitting ? context.l10n.invite_creating : context.l10n.invite_createLink),
              ),
            ),
          ],
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
            context.l10n.invite_fixed,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard(ThemeData theme) {
    final invite = _latestInvite!;
    final inviteLink = _effectiveInviteLink ?? invite.inviteLink;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.invite_latestResult,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
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
                inviteLink,
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
                      context.l10n.invite_usableCount(invite.invite?.maxRedemptionsAllowed ?? _maxRedemptionsAllowed),
                ),
                if (invite.invite?.expiresAt != null)
                  _MetaChip(
                    icon: Icons.schedule_rounded,
                    label:
                        context.l10n.invite_expiryDate(TimeUtils.formatDetailTime(invite.invite!.expiresAt)),
                  )
                else
                  _MetaChip(
                    icon: Icons.all_inclusive_rounded,
                    label: context.l10n.invite_noExpiry,
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
                    label: Text(context.l10n.common_copyLink),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _shareInviteLink,
                    icon: const Icon(Icons.share_rounded),
                    label: Text(context.l10n.common_share),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyStateCard(ThemeData theme) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          context.l10n.invite_noLinks,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
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
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
