import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/chat/chat_message.dart';
import '../../models/topic.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/preloaded_data_service.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../widgets/common/app_bottom_sheet.dart';

/// 举报聊天消息(结构对齐 PostFlagSheet;类型按消息 available_flags 过滤)
Future<void> showChatFlagSheet({
  required BuildContext context,
  required ChatMessage message,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    enableDrag: false, // 举报表单:禁止下滑误关丢失输入
    builder: (context) => _ChatFlagSheet(message: message),
  );
}

class _ChatFlagSheet extends StatefulWidget {
  final ChatMessage message;

  const _ChatFlagSheet({required this.message});

  @override
  State<_ChatFlagSheet> createState() => _ChatFlagSheetState();
}

class _ChatFlagSheetState extends State<_ChatFlagSheet> {
  FlagType? _selectedType;
  final _messageController = TextEditingController();
  bool _isSubmitting = false;
  List<FlagType> _flagTypes = [];
  bool _isLoading = true;

  // 分组:notify_user(私下发消息给作者)与通知管理员两组(PostFlagSheet 同款)
  List<FlagType> get _notifyUserTypes =>
      _flagTypes.where((f) => f.nameKey == 'notify_user').toList();
  List<FlagType> get _moderatorTypes =>
      _flagTypes.where((f) => f.nameKey != 'notify_user').toList();

  String get _username => widget.message.user?.username ?? '';

  /// 替换文案中的 %{username} 占位符(标题/描述都可能带)
  String _replacePlaceholders(String text) =>
      text.replaceAll('%{username}', _username);

  @override
  void initState() {
    super.initState();
    _loadFlagTypes();
    // 补充说明必填时,输入变化要实时解禁提交按钮
    _messageController.addListener(() {
      if (_selectedType?.requireMessage == true) setState(() {});
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _loadFlagTypes() async {
    final preloaded = PreloadedDataService();
    final types = await preloaded.getPostActionTypes();
    if (!mounted) return;
    final allowed = widget.message.availableFlags.toSet();
    setState(() {
      final source = types != null && types.isNotEmpty
          ? types.map((t) => FlagType.fromJson(t)).toList()
          : FlagType.defaultTypes;
      // 服务端 available_flags 是权威口径(已按 DM/权限/是否本人过滤)
      _flagTypes =
          source
              .where(
                (f) => f.isFlag && f.enabled && allowed.contains(f.nameKey),
              )
              .toList()
            ..sort((a, b) => a.position.compareTo(b.position));
      _isLoading = false;
    });
  }

  Future<void> _submit() async {
    final type = _selectedType;
    if (type == null || _isSubmitting) return;
    setState(() => _isSubmitting = true);
    try {
      await DiscourseService().flagChatMessage(
        widget.message.channelId,
        widget.message.id,
        flagTypeId: type.id,
        message: _messageController.text.isNotEmpty
            ? _messageController.text
            : null,
      );
      if (mounted) {
        Navigator.pop(context);
        ToastService.showSuccess(S.current.chat_flagSuccess);
      }
    } catch (e) {
      ToastService.showError(e.toString().replaceFirst('Exception: ', ''));
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needMessage = _selectedType?.requireMessage == true;

    return AppSheetScaffold(
      style: AppSheetStyle.card,
      maxHeightFactor: 0.7,
      contentPadding: EdgeInsets.zero,
      titleWidget: Row(
        children: [
          Icon(Symbols.flag_rounded, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Text(
            context.l10n.chat_flagTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
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
                    (needMessage && _messageController.text.trim().isEmpty)
                ? null
                : _submit,
            child: _isSubmitting
                ? const LoadingSpinner(size: 20)
                : Text(context.l10n.chat_flagSubmit),
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
                  child: LoadingSpinner(),
                ),
              )
            else if (_flagTypes.isEmpty)
              Text(
                context.l10n.chat_flagNoTypes,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else ...[
              if (_notifyUserTypes.isNotEmpty) ...[
                _buildSectionHeader(
                  context.l10n.post_flagMessageUser(_username),
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
            if (needMessage) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _messageController,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: context.l10n.chat_flagMessageHint,
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
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildFlagOption(FlagType type, ThemeData theme) {
    final isSelected = _selectedType?.id == type.id;

    // Material 承载底色+圆角,InkWell hover/水波被同一圆角裁剪,
    // 不会在 margin 区域再画一层矩形高亮(双层感来源)
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isSelected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _selectedType = type),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected
                    ? theme.colorScheme.primary
                    : Colors.transparent,
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
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (type.name.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            _replacePlaceholders(type.name),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      // 描述带 HTML(社区准则/推广规则链接),走新引擎渲染
                      FluxdoRenderCallbacks.generic(
                        heroTagNamespace: 'chat_flag_desc',
                      ).render(
                        cookedHtml: _replacePlaceholders(type.description),
                        baseTextStyle: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        selectionEnabled: false,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
