import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../services/preloaded_data_service.dart';
import '../../../../services/toast_service.dart';
import '../../../../utils/fluxdo_render_callbacks.dart';
import '../../../common/app_bottom_sheet.dart';

typedef BoostFlagTypesLoader = Future<List<FlagType>> Function();
typedef BoostFlagSubmitter =
    Future<void> Function(int flagTypeId, String? message);

bool boostAlreadyReportedByCurrentUser({
  required Boost boost,
  required String? currentUsername,
}) {
  if (currentUsername == null || currentUsername.isEmpty) {
    return false;
  }
  if (currentUsername == boost.user.username) {
    return false;
  }
  return (boost.userFlagStatus ?? 0) > 0;
}

bool canDeleteBoostAction({
  required Boost boost,
  required String? currentUsername,
}) {
  if (currentUsername == null || currentUsername.isEmpty) {
    return false;
  }
  final isOwn = currentUsername == boost.user.username;
  return isOwn || boost.canDelete;
}

bool canFlagBoostAction({
  required Boost boost,
  required String? currentUsername,
}) {
  if (currentUsername == null || currentUsername.isEmpty) {
    return false;
  }
  if (boostAlreadyReportedByCurrentUser(
    boost: boost,
    currentUsername: currentUsername,
  )) {
    return false;
  }
  final isOwn = currentUsername == boost.user.username;
  return !isOwn && boost.canFlag;
}

bool canOpenBoostActionMenu({
  required Boost boost,
  required String? currentUsername,
}) {
  return canDeleteBoostAction(boost: boost, currentUsername: currentUsername) ||
      canFlagBoostAction(boost: boost, currentUsername: currentUsername);
}

bool canViewBoostAuthor({required Boost boost}) {
  return boost.user.username.trim().isNotEmpty;
}

bool canShowBoostActionSheet({
  required Boost boost,
  required String? currentUsername,
}) {
  return canViewBoostAuthor(boost: boost) ||
      canOpenBoostActionMenu(boost: boost, currentUsername: currentUsername);
}

List<FlagType> filterBoostFlagTypes({
  required List<FlagType> allFlagTypes,
  List<String>? availableFlags,
}) {
  final enabledTypes = allFlagTypes
      .where((f) => f.isFlag && f.enabled)
      .toList();
  if (availableFlags == null || availableFlags.isEmpty) {
    return const [];
  }
  final allowedKeys = availableFlags
      .map((flag) => flag.trim())
      .where((flag) => flag.isNotEmpty)
      .toSet();

  List<FlagType> sortTypes(List<FlagType> types) {
    final sorted = [...types];
    sorted.sort((a, b) => a.position.compareTo(b.position));
    return sorted;
  }

  if (allowedKeys.isEmpty) {
    return const [];
  }

  final baseTypes = enabledTypes.isNotEmpty
      ? enabledTypes
      : FlagType.defaultTypes;
  final matchedTypes = baseTypes
      .where((type) => allowedKeys.contains(type.nameKey))
      .toList();
  if (matchedTypes.isNotEmpty) {
    return sortTypes(matchedTypes);
  }

  return sortTypes(
    FlagType.defaultTypes
        .where((type) => allowedKeys.contains(type.nameKey))
        .toList(),
  );
}

/// 举报 Boost 底部弹窗
class BoostFlagSheet extends StatefulWidget {
  final Boost boost;
  final BoostFlagTypesLoader? loadFlagTypes;
  final BoostFlagSubmitter? submitFlag;
  final VoidCallback? onSuccess;

  const BoostFlagSheet({
    super.key,
    required this.boost,
    this.loadFlagTypes,
    this.submitFlag,
    this.onSuccess,
  });

  @override
  State<BoostFlagSheet> createState() => _BoostFlagSheetState();
}

class _BoostFlagSheetState extends State<BoostFlagSheet> {
  FlagType? _selectedType;
  final _messageController = TextEditingController();
  bool _isSubmitting = false;
  List<FlagType> _flagTypes = [];
  bool _isLoading = true;

  List<FlagType> get _notifyUserTypes =>
      _flagTypes.where((f) => f.nameKey == 'notify_user').toList();
  List<FlagType> get _moderatorTypes =>
      _flagTypes.where((f) => f.nameKey != 'notify_user').toList();

  String _replaceDescription(String description) {
    return description
        .replaceAll('%{username}', widget.boost.user.username)
        .replaceAll('@%{username}', '@${widget.boost.user.username}');
  }

  @override
  void initState() {
    super.initState();
    _loadFlagTypes();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _loadFlagTypes() async {
    try {
      final types = widget.loadFlagTypes != null
          ? await widget.loadFlagTypes!()
          : await _loadDefaultFlagTypes();
      if (!mounted) return;
      setState(() {
        _flagTypes = filterBoostFlagTypes(
          allFlagTypes: types,
          availableFlags: widget.boost.availableFlags,
        );
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _flagTypes = filterBoostFlagTypes(
          allFlagTypes: const [],
          availableFlags: widget.boost.availableFlags,
        );
        _isLoading = false;
      });
    }
  }

  Future<List<FlagType>> _loadDefaultFlagTypes() async {
    final types = await PreloadedDataService().getPostActionTypes();
    if (types == null || types.isEmpty) {
      return FlagType.defaultTypes;
    }
    return types
        .map((t) => FlagType.fromJson(t))
        .where((f) => f.isFlag && f.enabled)
        .toList();
  }

  Future<void> _submitFlag() async {
    if (_selectedType == null || _isSubmitting) return;
    final submitter = widget.submitFlag;
    if (submitter == null) return;
    final message = _messageController.text.trim();
    if (_selectedType!.requireMessage && message.isEmpty) {
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await submitter(_selectedType!.id, message.isNotEmpty ? message : null);
      if (!mounted) return;
      Navigator.pop(context);
      widget.onSuccess?.call();
    } catch (e) {
      if (!mounted) return;
      final message = e is Exception
          ? e.toString().replaceFirst('Exception: ', '')
          : S.current.post_flagFailed;
      ToastService.showError(message);
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppSheetScaffold(
      style: AppSheetStyle.card,
      maxHeightFactor: 0.7,
      contentPadding: EdgeInsets.zero,
      titleWidget: Row(
        children: [
          Icon(Symbols.flag_rounded, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Text(
            context.l10n.boost_flagTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed:
                _selectedType == null ||
                    _isSubmitting ||
                    _isLoading ||
                    (_selectedType?.requireMessage == true &&
                        _messageController.text.trim().isEmpty) ||
                    widget.submitFlag == null
                ? null
                : _submitFlag,
            child: _isSubmitting
                ? const LoadingSpinner(size: 20)
                : Text(context.l10n.post_submitFlag),
          ),
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_flagTypes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    context.l10n.common_noData,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else ...[
              if (_notifyUserTypes.isNotEmpty) ...[
                _buildSectionHeader(
                  context.l10n.post_flagMessageUser(widget.boost.user.username),
                  theme,
                ),
                ..._notifyUserTypes.map(
                  (type) => _buildFlagOption(type, theme),
                ),
                const SizedBox(height: 16),
                Divider(color: theme.colorScheme.outlineVariant),
                const SizedBox(height: 16),
              ],
              if (_moderatorTypes.isNotEmpty) ...[
                _buildSectionHeader(
                  context.l10n.post_flagNotifyModerators,
                  theme,
                ),
                ..._moderatorTypes.map((type) => _buildFlagOption(type, theme)),
              ],
            ],
            if (_selectedType?.requireMessage == true) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _messageController,
                maxLines: 3,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: context.l10n.post_flagDescriptionHint,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildFlagOption(FlagType type, ThemeData theme) {
    final isSelected = _selectedType?.id == type.id;
    final description = _replaceDescription(type.description);
    return InkWell(
      key: ValueKey('boost-flag-option-${type.nameKey}'),
      onTap: () => setState(() => _selectedType = type),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary : Colors.transparent,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isSelected
                  ? Symbols.radio_button_checked_rounded
                  : Symbols.radio_button_unchecked_rounded,
              size: 20,
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(child: _buildDescriptionText(description, theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildDescriptionText(String description, ThemeData theme) {
    // 只读描述，用新引擎 FluxdoRender 渲染；链接点击由 generic 内置
    // linkHandler(launchContentLink)处理。
    return FluxdoRenderCallbacks.generic(heroTagNamespace: 'boost_flag_desc')
        .render(
          cookedHtml: description,
          baseTextStyle: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          selectionEnabled: false,
        );
  }
}
