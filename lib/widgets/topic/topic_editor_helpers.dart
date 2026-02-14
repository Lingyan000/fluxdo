import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:pangutext/pangutext.dart';

import '../../models/category.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/url_helper.dart';
import '../common/category_selection_sheet.dart';
import '../common/tag_selection_sheet.dart';
import '../common/topic_badges.dart';

/// 话题编辑器辅助函数和 Widgets
/// 用于 CreateTopicPage 和 EditTopicPage 的公共逻辑

// ============================================================================
// 文本处理辅助类
// ============================================================================

/// 智能列表续行处理器
class SmartListHandler {
  String _previousText = '';

  /// 处理文本变化，实现智能列表续行
  /// 返回 true 如果已处理（调用者应该 return）
  bool handleTextChange(TextEditingController controller) {
    final currentText = controller.text;
    final selection = controller.selection;

    // 只在文本增加时处理
    if (currentText.length <= _previousText.length) {
      _previousText = currentText;
      return false;
    }

    if (!selection.isValid || selection.start <= 0) {
      _previousText = currentText;
      return false;
    }

    // 检查是否刚输入换行符
    if (currentText[selection.start - 1] != '\n') {
      _previousText = currentText;
      return false;
    }

    // 找到上一行的开始位置
    int prevLineStart = selection.start - 2;
    if (prevLineStart < 0) {
      _previousText = currentText;
      return false;
    }

    // 向前查找上一行的开始
    while (prevLineStart > 0 && currentText[prevLineStart - 1] != '\n') {
      prevLineStart--;
    }

    // 提取上一行的内容
    final prevLine = currentText.substring(prevLineStart, selection.start - 1);

    // 检测无序列表
    final unorderedMatch = RegExp(r'^(\s*)([-*+])\s+(.*)$').firstMatch(prevLine);
    if (unorderedMatch != null) {
      final indent = unorderedMatch.group(1)!;
      final marker = unorderedMatch.group(2)!;
      final content = unorderedMatch.group(3)!;

      if (content.isEmpty) {
        // 空列表项，移除列表标记
        final newText = currentText.replaceRange(prevLineStart, selection.start, '\n');
        _previousText = newText;
        controller.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: prevLineStart + 1),
        );
      } else {
        // 非空列表项，添加新的列表标记
        final prefix = '$indent$marker ';
        final newText = currentText.replaceRange(selection.start, selection.start, prefix);
        _previousText = newText;
        controller.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: selection.start + prefix.length),
        );
      }
      return true;
    }

    // 检测有序列表
    final orderedMatch = RegExp(r'^(\s*)(\d+)\.\s+(.*)$').firstMatch(prevLine);
    if (orderedMatch != null) {
      final indent = orderedMatch.group(1)!;
      final number = int.parse(orderedMatch.group(2)!);
      final content = orderedMatch.group(3)!;

      if (content.isEmpty) {
        // 空列表项，移除列表标记
        final newText = currentText.replaceRange(prevLineStart, selection.start, '\n');
        _previousText = newText;
        controller.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: prevLineStart + 1),
        );
      } else {
        // 非空列表项，添加新的列表标记（数字递增）
        final prefix = '$indent${number + 1}. ';
        final newText = currentText.replaceRange(selection.start, selection.start, prefix);
        _previousText = newText;
        controller.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: selection.start + prefix.length),
        );
      }
      return true;
    }

    _previousText = currentText;
    return false;
  }

  /// 更新前一次文本（用于其他处理后同步状态）
  void updatePreviousText(String text) {
    _previousText = text;
  }

  String get previousText => _previousText;
}

/// Pangu 空格处理器
class PanguSpacingHandler {
  final Pangu _pangu = Pangu();
  bool _isApplying = false;

  bool get isApplying => _isApplying;

  /// 自动应用 Pangu 空格（在文本变化时调用）
  /// 返回 true 如果已处理
  bool autoApply(TextEditingController controller, void Function(String) updatePreviousText) {
    if (_isApplying) return false;

    final currentText = controller.text;
    final selection = controller.selection;

    if (currentText.isEmpty || !selection.isValid) return false;

    // 如果正在输入法组合中，不处理
    if (controller.value.composing.isValid && !controller.value.composing.isCollapsed) {
      return false;
    }

    final spacedText = _pangu.spacingText(currentText);
    if (spacedText == currentText) return false;

    _isApplying = true;
    final cursor = selection.start.clamp(0, currentText.length);
    final prefix = currentText.substring(0, cursor);
    final newCursor = _pangu.spacingText(prefix).length;
    final clampedCursor = newCursor.clamp(0, spacedText.length);

    controller.value = TextEditingValue(
      text: spacedText,
      selection: TextSelection.collapsed(offset: clampedCursor),
    );
    updatePreviousText(spacedText);
    _isApplying = false;
    return true;
  }

  /// 手动应用 Pangu 空格
  void manualApply(TextEditingController controller, void Function(String) updatePreviousText) {
    if (_isApplying) return;

    final currentText = controller.text;
    final selection = controller.selection;

    if (currentText.isEmpty || !selection.isValid) return;
    if (controller.value.composing.isValid && !controller.value.composing.isCollapsed) {
      return;
    }

    final spacedText = _pangu.spacingText(currentText);
    if (spacedText == currentText) return;

    _isApplying = true;
    final cursor = selection.start.clamp(0, currentText.length);
    final prefix = currentText.substring(0, cursor);
    final newCursor = _pangu.spacingText(prefix).length;
    final clampedCursor = newCursor.clamp(0, spacedText.length);

    controller.value = TextEditingValue(
      text: spacedText,
      selection: TextSelection.collapsed(offset: clampedCursor),
    );
    updatePreviousText(spacedText);
    _isApplying = false;
  }
}

// ============================================================================
// UI 辅助函数
// ============================================================================

/// 解析十六进制颜色
Color parseHexColor(String hex) {
  hex = hex.replaceAll('#', '');
  if (hex.length == 6) {
    return Color(int.parse('0xFF$hex'));
  }
  return Colors.grey;
}

/// 构建颜色点
Widget buildColorDot(Color color) {
  return Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
    ),
  );
}

// ============================================================================
// 分类选择器 Widget
// ============================================================================

/// 分类选择触发器
class CategoryTrigger extends StatelessWidget {
  final Category? category;
  final List<Category> categories;
  final ValueChanged<Category> onSelected;

  const CategoryTrigger({
    super.key,
    required this.category,
    required this.categories,
    required this.onSelected,
  });

  Future<void> _showPicker(BuildContext context) async {
    final result = await showModalBottomSheet<Category>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CategorySelectionSheet(
        categories: categories,
        selectedCategory: category,
      ),
    );

    if (result != null) {
      onSelected(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (category == null) {
      return Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () => _showPicker(context),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.category_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  '选择分类',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.arrow_drop_down, size: 18, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      );
    }

    final color = parseHexColor(category!.color);
    IconData? faIcon = FontAwesomeHelper.getIcon(category!.icon);
    String? logoUrl = category!.uploadedLogo;

    return Material(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: () => _showPicker(context),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: color.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (faIcon != null)
                FaIcon(faIcon, size: 14, color: color)
              else if (logoUrl != null && logoUrl.isNotEmpty)
                Image(
                  image: discourseImageProvider(
                    UrlHelper.resolveUrl(logoUrl),
                  ),
                  width: 16,
                  height: 16,
                  fit: BoxFit.contain,
                  errorBuilder: (context, e, s) => buildColorDot(color),
                )
              else
                buildColorDot(color),
              const SizedBox(width: 8),
              Text(
                category!.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.arrow_drop_down, size: 18, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 标签区域 Widget
// ============================================================================

/// 标签选择区域
class TagsArea extends StatelessWidget {
  final Category? selectedCategory;
  final List<String> selectedTags;
  final List<String> allTags;
  final ValueChanged<List<String>> onTagsChanged;

  const TagsArea({
    super.key,
    required this.selectedCategory,
    required this.selectedTags,
    required this.allTags,
    required this.onTagsChanged,
  });

  Future<void> _showPicker(BuildContext context, List<String> availableTags) async {
    final minTags = selectedCategory?.minimumRequiredTags ?? 0;
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TagSelectionSheet(
        categoryId: selectedCategory?.id,
        availableTags: availableTags,
        selectedTags: selectedTags,
        maxTags: 5,
        minTags: minTags,
      ),
    );

    if (result != null) {
      onTagsChanged(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final minTags = selectedCategory?.minimumRequiredTags ?? 0;
    final currentCount = selectedTags.length;

    // 根据选中的分类过滤可用标签
    List<String> availableTags = allTags;
    if (selectedCategory != null) {
      final category = selectedCategory!;
      if (category.allowedTags.isNotEmpty || category.allowedTagGroups.isNotEmpty) {
        availableTags = allTags.where((tag) {
          if (category.allowedTags.contains(tag)) return true;
          if (category.allowGlobalTags) return true;
          return false;
        }).toList();
      }
    }

    // 检查标签组要求
    final missingRequirements = <String>[];
    bool isGroupsSatisfied = true;

    if (selectedCategory != null && selectedCategory!.requiredTagGroups.isNotEmpty) {
      if (selectedTags.isEmpty) {
        for (final req in selectedCategory!.requiredTagGroups) {
          isGroupsSatisfied = false;
          missingRequirements.add('从 ${req.name} 选择 ${req.minCount} 个');
        }
      }
    }

    final isSatisfied = currentCount >= minTags && isGroupsSatisfied;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...selectedTags.map((tag) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.1),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tag, size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                tag,
                style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () {
                  final newTags = List<String>.from(selectedTags)..remove(tag);
                  onTagsChanged(newTags);
                },
                child: Icon(Icons.close, size: 14, color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        )),

        // 添加/编辑标签按钮
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _showPicker(context, availableTags),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(
                  color: isSatisfied
                      ? theme.colorScheme.outline.withValues(alpha: 0.2)
                      : theme.colorScheme.error.withValues(alpha: 0.5),
                  style: BorderStyle.solid,
                ),
                color: isSatisfied ? null : theme.colorScheme.errorContainer.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selectedTags.isEmpty ? Icons.add : Icons.edit_outlined,
                    size: 16,
                    color: isSatisfied ? theme.colorScheme.primary : theme.colorScheme.error,
                  ),
                  if (selectedTags.isEmpty || !isSatisfied) ...[
                    const SizedBox(width: 4),
                    Text(
                      _getButtonText(minTags, currentCount, missingRequirements),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: isSatisfied
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _getButtonText(int minTags, int currentCount, List<String> missingReqs) {
    if (missingReqs.isNotEmpty) {
      return missingReqs.first;
    }
    if (currentCount < minTags) {
      final remaining = minTags - currentCount;
      return selectedTags.isEmpty
          ? '至少选择 $minTags 个标签'
          : '还需 $remaining 个标签';
    }
    return '添加标签';
  }
}

// ============================================================================
// 预览模式下的标签展示
// ============================================================================

/// 预览模式下的标签列表
class PreviewTagsList extends StatelessWidget {
  final List<String> tags;

  const PreviewTagsList({super.key, required this.tags});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: tags.map((t) => TagBadge(
        name: t,
        size: const BadgeSize(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          radius: 6,
          iconSize: 12,
          fontSize: 13,
        ),
        backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        textStyle: theme.textTheme.bodyMedium?.copyWith(
          fontSize: 13,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      )).toList(),
    );
  }
}
