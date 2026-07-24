import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'dart:async';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/tag_search_result.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/toast_service.dart';
import 'package:fluxdo/widgets/common/app_bottom_sheet.dart';
import 'package:fluxdo/widgets/common/topic_badges.dart';

class TagSelectionSheet extends StatefulWidget {
  /// 分类 ID（用于联动过滤标签）
  final int? categoryId;

  /// 初始可用标签（降级使用）
  final List<String> availableTags;

  /// 已选中的标签
  final List<String> selectedTags;

  /// 最大可选标签数
  final int maxTags;

  /// 最小必选标签数（仅 filterForInput=true 时有效）
  final int minTags;

  /// 是否为创建话题模式（true=创建话题，false=筛选/浏览）
  ///
  /// 创建话题时：发送 filterForInput 给 API，显示必选标签组提示和最小标签数约束
  /// 筛选浏览时：不发送 filterForInput，不显示必选标签组和最小标签数约束
  final bool filterForInput;

  const TagSelectionSheet({
    super.key,
    this.categoryId,
    required this.availableTags,
    required this.selectedTags,
    this.maxTags = 5,
    this.minTags = 0,
    this.filterForInput = false,
  });

  @override
  State<TagSelectionSheet> createState() => _TagSelectionSheetState();
}

class _TagSelectionSheetState extends State<TagSelectionSheet> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  late List<String> _currentSelectedTags;

  /// 动态标签搜索结果
  List<TagInfo> _searchResults = [];

  /// 必选标签组信息
  RequiredTagGroup? _requiredTagGroup;

  /// 是否正在加载
  bool _isLoading = false;

  /// 是否已初始化（首次加载完成）
  bool _initialized = false;

  /// 搜索防抖计时器
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _currentSelectedTags = List.from(widget.selectedTags);
    // 初始化加载标签
    _searchTags('');
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// 搜索标签（带防抖）
  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _searchTags(query);
    });
  }

  /// 调用 API 搜索标签
  Future<void> _searchTags(String query) async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final result = await DiscourseService().searchTags(
        query: query,
        categoryId: widget.categoryId,
        selectedTags: _currentSelectedTags,
        limit: 8,
        filterForInput: widget.filterForInput,
      );

      if (!mounted) return;

      setState(() {
        _searchResults = result.results;
        // 仅创建话题模式下处理必选标签组
        _requiredTagGroup = widget.filterForInput
            ? result.requiredTagGroup
            : null;
        _isLoading = false;
        _initialized = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _initialized = true;
        // 降级使用传入的静态标签列表
        if (_searchResults.isEmpty) {
          _searchResults = widget.availableTags
              .where(
                (t) =>
                    query.isEmpty ||
                    t.toLowerCase().contains(query.toLowerCase()),
              )
              .map((t) => TagInfo(name: t, text: t, count: 0))
              .toList();
        }
      });
    }
  }

  void _toggleTag(String tag) {
    setState(() {
      if (_currentSelectedTags.contains(tag)) {
        _currentSelectedTags.remove(tag);
      } else {
        if (_currentSelectedTags.length >= widget.maxTags) {
          ToastService.showInfo(S.current.tag_maxTagsReached(widget.maxTags));
          return;
        }
        _currentSelectedTags.add(tag);
      }
    });

    // 选中后重新搜索以更新 required_tag_group 状态
    _searchTags(_searchController.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 构建提示文本
    final l10n = context.l10n;
    String hintText;
    if (widget.filterForInput && _requiredTagGroup != null) {
      // 创建话题模式：有必选标签组要求
      hintText = l10n.tag_requiredTagGroupHint(
        _requiredTagGroup!.name,
        _requiredTagGroup!.minCount,
      );
    } else if (widget.filterForInput && widget.minTags > 0) {
      if (_currentSelectedTags.length < widget.minTags) {
        hintText = l10n.tag_searchWithMin(
          _currentSelectedTags.length,
          widget.minTags,
        );
      } else {
        hintText = l10n.tag_searchWithMax(
          _currentSelectedTags.length,
          widget.maxTags,
        );
      }
    } else {
      // 筛选模式或无特殊约束
      hintText = _currentSelectedTags.isEmpty
          ? l10n.tag_searchHint
          : l10n.tag_searchWithCount(_currentSelectedTags.length);
    }

    // 过滤出未选中的标签
    final displayTags = _searchResults
        .where((t) => !_currentSelectedTags.contains(t.name))
        .toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return AppSheetScaffold(
          expandToFill: true,
          showCloseButton: false,
          contentPadding: EdgeInsets.zero,
          child: Column(
            children: [
              // 搜索栏区域
              Container(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.5,
                      ),
                      width: 0.5,
                    ),
                  ),
                ),
                child: Column(
                  children: [
                    // 必选标签组提示（仅创建话题模式）
                    if (widget.filterForInput && _requiredTagGroup != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer.withValues(
                            alpha: 0.3,
                          ),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Symbols.info_rounded,
                              size: 16,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l10n.tag_requiredGroupWarning(
                                  _requiredTagGroup!.name,
                                  _requiredTagGroup!.minCount,
                                ),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    // 搜索栏
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 44,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: TextField(
                              controller: _searchController,
                              focusNode: _searchFocusNode,
                              textAlignVertical: TextAlignVertical.center,
                              style: const TextStyle(fontSize: 16),
                              decoration: InputDecoration(
                                hintText: hintText,
                                hintStyle: TextStyle(
                                  color:
                                      (widget.filterForInput &&
                                          _requiredTagGroup != null)
                                      ? theme.colorScheme.primary
                                      : (widget.filterForInput &&
                                                _currentSelectedTags.length <
                                                    widget.minTags
                                            ? theme.colorScheme.error
                                            : theme
                                                  .colorScheme
                                                  .onSurfaceVariant),
                                  fontSize: 14,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.only(
                                  left: 0,
                                  right: 12,
                                ),
                                prefixIconConstraints: const BoxConstraints(
                                  minWidth: 44,
                                  minHeight: 44,
                                ),
                                prefixIcon: _isLoading
                                    ? const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: LoadingSpinner(size: 20),
                                      )
                                    : Icon(
                                        Symbols.search_rounded,
                                        size: 20,
                                        color: theme.colorScheme.onSurface,
                                      ),
                                suffixIcon: _searchController.text.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(
                                          Symbols.cancel_rounded,
                                          size: 18,
                                        ),
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                        onPressed: () {
                                          _searchController.clear();
                                          _searchTags('');
                                        },
                                      )
                                    : null,
                              ),
                              onChanged: _onSearchChanged,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: () =>
                              Navigator.pop(context, _currentSelectedTags),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                          ),
                          child: Text(l10n.common_confirm),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // 已选标签展示区
              if (_currentSelectedTags.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _currentSelectedTags.map((tag) {
                      return RemovableTagBadge(
                        name: tag,
                        onDeleted: () => _toggleTag(tag),
                        size: const BadgeSize(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          radius: 8,
                          iconSize: 12,
                          fontSize: 13,
                        ),
                      );
                    }).toList(),
                  ),
                ),

              // 标签列表
              Expanded(
                child: !_initialized
                    ? const Center(child: LoadingSpinner())
                    : displayTags.isEmpty
                    ? Center(
                        child: Text(
                          _searchController.text.isEmpty
                              ? l10n.tag_noTags
                              : l10n.tag_noTagsFound,
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: displayTags.length,
                        padding: EdgeInsets.only(
                          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                        ),
                        itemBuilder: (context, index) {
                          final tag = displayTags[index];
                          return ListTile(
                            title: TagBadge(
                              name: tag.text,
                              size: const BadgeSize(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                radius: 6,
                                iconSize: 12,
                                fontSize: 12,
                              ),
                              backgroundColor: Colors.transparent,
                            ),
                            subtitle: tag.count > 0
                                ? Text(l10n.tag_topicCount(tag.count))
                                : null,
                            trailing:
                                _currentSelectedTags.length >= widget.maxTags
                                ? Icon(
                                    Symbols.block_rounded,
                                    color: theme.colorScheme.outline,
                                  )
                                : Icon(
                                    Symbols.add_circle_rounded,
                                    color: theme.colorScheme.primary,
                                  ),
                            onTap: () => _toggleTag(tag.name),
                            enabled:
                                _currentSelectedTags.length < widget.maxTags,
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
