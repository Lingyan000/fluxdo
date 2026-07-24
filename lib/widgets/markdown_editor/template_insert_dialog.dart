import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../services/discourse/discourse_service.dart';
import '../../models/template.dart';
import '../../utils/dialog_utils.dart';
import '../common/app_bottom_sheet.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../../../../../l10n/s.dart';

/// 模板选择底部弹窗
class TemplateInsertDialog extends StatefulWidget {
  const TemplateInsertDialog({super.key});

  @override
  State<TemplateInsertDialog> createState() => _TemplateInsertDialogState();
}

class _TemplateInsertDialogState extends State<TemplateInsertDialog> {
  final _searchController = TextEditingController();
  List<Template>? _templates;
  String? _error;
  String _searchQuery = '';
  int? _expandedId;

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadTemplates() async {
    try {
      final templates = await DiscourseService().getTemplates();
      if (!mounted) return;
      setState(() => _templates = templates);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  List<Template> get _filteredTemplates {
    final templates = _templates;
    if (templates == null) return [];
    if (_searchQuery.isEmpty) {
      // 按使用次数降序
      return List.of(templates)..sort((a, b) => b.usages.compareTo(a.usages));
    }
    final query = _searchQuery.toLowerCase();
    final filtered = templates.where((t) {
      return t.title.toLowerCase().contains(query) ||
          t.content.toLowerCase().contains(query);
    }).toList();
    // 标题匹配优先，然后按使用次数
    filtered.sort((a, b) {
      final aTitle = a.title.toLowerCase().contains(query);
      final bTitle = b.title.toLowerCase().contains(query);
      if (aTitle && !bTitle) return -1;
      if (!aTitle && bTitle) return 1;
      return b.usages.compareTo(a.usages);
    });
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return AppSheetScaffold(
          expandToFill: true,
          showCloseButton: false,
          contentPadding: EdgeInsets.zero,
          title: S.current.template_insertTitle,
          child: Column(
            children: [
              // 搜索框
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: S.current.template_searchHint,
                    prefixIcon: const Icon(Symbols.search_rounded, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    isDense: true,
                  ),
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
              ),
              const SizedBox(height: 4),
              // 内容
              Expanded(child: _buildContent(scrollController, theme)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContent(ScrollController scrollController, ThemeData theme) {
    // 加载中
    if (_templates == null && _error == null) {
      return const Center(child: LoadingSpinner(size: 36));
    }

    // 错误
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              S.current.template_loadError,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                setState(() {
                  _error = null;
                  _templates = null;
                });
                _loadTemplates();
              },
              child: Text(S.current.common_retry),
            ),
          ],
        ),
      );
    }

    final filtered = _filteredTemplates;

    // 空状态
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          S.current.template_empty,
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    // 模板列表
    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final template = filtered[index];
        final isExpanded = _expandedId == template.id;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(template.title),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isExpanded ? Symbols.expand_less_rounded : Symbols.expand_more_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () => _selectTemplate(template),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 32),
                    ),
                    child: Text(S.current.common_confirm),
                  ),
                ],
              ),
              onTap: () {
                setState(() {
                  _expandedId = isExpanded ? null : template.id;
                });
              },
            ),
            if (isExpanded)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    template.content,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 15,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _selectTemplate(Template template) {
    // 异步记录使用次数
    DiscourseService().useTemplate(template.id);
    Navigator.of(context).pop(template);
  }
}

/// 显示模板选择底部弹窗
Future<Template?> showTemplateInsertDialog(BuildContext context) {
  return showAppBottomSheet<Template>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const TemplateInsertDialog(),
  );
}
