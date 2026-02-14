import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import '../../../../utils/url_helper.dart';
import '../../../../models/topic.dart';
import '../../../../services/preloaded_data_service.dart';
import '../../../../services/discourse/discourse_service.dart';

/// 举报底部弹窗
class PostFlagSheet extends StatefulWidget {
  final int postId;
  final String postUsername;
  final DiscourseService service;
  final VoidCallback? onSuccess;

  const PostFlagSheet({
    super.key,
    required this.postId,
    required this.postUsername,
    required this.service,
    this.onSuccess,
  });

  @override
  State<PostFlagSheet> createState() => _PostFlagSheetState();
}

class _PostFlagSheetState extends State<PostFlagSheet> {
  FlagType? _selectedType;
  final _messageController = TextEditingController();
  bool _isSubmitting = false;
  List<FlagType> _flagTypes = [];
  bool _isLoading = true;

  // 分组：notify_user 类型单独一组
  List<FlagType> get _notifyUserTypes =>
      _flagTypes.where((f) => f.nameKey == 'notify_user').toList();
  List<FlagType> get _moderatorTypes =>
      _flagTypes.where((f) => f.nameKey != 'notify_user').toList();

  /// 替换描述中的占位符
  String _replaceDescription(String description) {
    return description
        .replaceAll('%{username}', widget.postUsername)
        .replaceAll('@%{username}', '@${widget.postUsername}');
  }

  @override
  void initState() {
    super.initState();
    _loadFlagTypes();
  }

  Future<void> _loadFlagTypes() async {
    final preloaded = PreloadedDataService();
    final types = await preloaded.getPostActionTypes();

    if (mounted) {
      setState(() {
        if (types != null && types.isNotEmpty) {
          _flagTypes = types
              .map((t) => FlagType.fromJson(t))
              .where((f) => f.isFlag && f.enabled && f.appliesToPost)
              .toList()
            ..sort((a, b) => a.position.compareTo(b.position));
        } else {
          _flagTypes = FlagType.defaultTypes;
        }
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submitFlag() async {
    if (_selectedType == null) return;
    if (_isSubmitting) return;

    setState(() => _isSubmitting = true);

    try {
      await widget.service.flagPost(
        widget.postId,
        _selectedType!.id,
        message: _messageController.text.isNotEmpty ? _messageController.text : null,
      );

      if (mounted) {
        Navigator.pop(context);
        widget.onSuccess?.call();
      }
    } catch (e) {
      if (mounted) {
        final message = e is Exception ? e.toString().replaceFirst('Exception: ', '') : '举报失败，请稍后重试';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.all(16),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题（固定）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.flag_outlined, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Text(
                    '举报帖子',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),

            // 可滚动内容
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 加载状态
                    if (_isLoading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else ...[
                      // 向用户发送消息分组
                      if (_notifyUserTypes.isNotEmpty) ...[
                        _buildSectionHeader(
                          '向 @${widget.postUsername} 发送消息',
                          theme,
                        ),
                        ..._notifyUserTypes.map((type) => _buildFlagOption(type, theme)),
                        const SizedBox(height: 16),
                        Divider(color: theme.colorScheme.outlineVariant),
                        const SizedBox(height: 16),
                      ],
                      // 私下通知管理人员分组
                      if (_moderatorTypes.isNotEmpty) ...[
                        _buildSectionHeader('私下通知管理人员', theme),
                        ..._moderatorTypes.map((type) => _buildFlagOption(type, theme)),
                      ],
                    ],

                    // 补充说明输入框
                    if (_selectedType?.requireMessage == true) ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: _messageController,
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: '请描述具体问题...',
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
            ),

            // 提交按钮（固定在底部）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _selectedType == null || _isSubmitting || _isLoading ? null : _submitFlag,
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('提交举报'),
                ),
              ),
            ),
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
      onTap: () => setState(() => _selectedType = type),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
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
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20,
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildDescriptionText(description, theme),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建描述文本，支持 HTML 链接
  Widget _buildDescriptionText(String description, ThemeData theme) {
    return HtmlWidget(
      description,
      textStyle: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      customStylesBuilder: (element) {
        if (element.localName == 'a') {
          return {'text-decoration': 'none'};
        }
        return null;
      },
      onTapUrl: (url) {
        final fullUrl = UrlHelper.resolveUrl(url);
        debugPrint('Open URL: $fullUrl');
        return true;
      },
    );
  }
}
