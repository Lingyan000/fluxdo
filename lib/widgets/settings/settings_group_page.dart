import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_model.dart';
import '../../settings/settings_renderer.dart';

/// 通用数据驱动设置页
///
/// 接收 [SettingsGroup] 列表，渲染为 section header + Card + SettingsRenderer 列表。
/// 支持通过 [highlightId] 滚动定位到指定设置项并高亮。
class SettingsGroupPage extends ConsumerStatefulWidget {
  final String title;
  final List<SettingsGroup> Function(BuildContext context) groupsBuilder;

  /// 搜索跳转时传入，用于定位高亮
  final String? highlightId;

  /// AppBar 右侧操作按钮
  final List<Widget>? actions;

  /// 内容最大宽度。为 null 时铺满页面。
  final double? maxContentWidth;

  const SettingsGroupPage({
    super.key,
    required this.title,
    required this.groupsBuilder,
    this.highlightId,
    this.actions,
    this.maxContentWidth,
  });

  @override
  ConsumerState<SettingsGroupPage> createState() => _SettingsGroupPageState();
}

class _SettingsGroupPageState extends ConsumerState<SettingsGroupPage> {
  final Map<String, GlobalKey> _itemKeys = {};
  String? _highlightedId;

  @override
  void initState() {
    super.initState();
    if (widget.highlightId != null) {
      _highlightedId = widget.highlightId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHighlight());
    }
  }

  void _scrollToHighlight() {
    final key = _itemKeys[_highlightedId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: 0.3,
      );
    }
    // 2 秒后清除高亮
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightedId = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groupsBuilder(context);
    final theme = Theme.of(context);
    final listView = ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        for (final group in groups)
          if (_hasVisibleItems(group)) ...[
            _buildSectionHeader(theme, group.title, group.icon),
            const SizedBox(height: 12),
            if (group.wrapInCard)
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildGroupItems(theme, group),
              )
            else
              _buildGroupItems(theme, group),
            const SizedBox(height: 24),
          ],
      ],
    );

    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: widget.actions),
      body: widget.maxContentWidth == null
          ? listView
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.maxContentWidth!),
                child: listView,
              ),
            ),
    );
  }

  Widget _buildGroupItems(ThemeData theme, SettingsGroup group) {
    final effectiveItems = group.items.where((item) {
      if (item is PlatformConditionalModel) return item.shouldShow;
      return true;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < effectiveItems.length; i++) ...[
          _buildItem(theme, effectiveItems[i]),
          if (i < effectiveItems.length - 1)
            if (group.wrapInCard)
              Divider(
                height: 1,
                indent: 56,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
              )
            else
              const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildItem(ThemeData theme, SettingsModel item) {
    final model = item is PlatformConditionalModel ? item.inner : item;
    final key = _itemKeys.putIfAbsent(model.id, () => GlobalKey());
    final isHighlighted = _highlightedId == model.id;

    return AnimatedContainer(
      key: key,
      duration: const Duration(milliseconds: 500),
      color: isHighlighted
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
          : Colors.transparent,
      child: SettingsRenderer(model: model),
    );
  }

  bool _hasVisibleItems(SettingsGroup group) {
    return group.items.any((item) {
      if (item is PlatformConditionalModel) return item.shouldShow;
      return true;
    });
  }

  Widget _buildSectionHeader(ThemeData theme, String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
