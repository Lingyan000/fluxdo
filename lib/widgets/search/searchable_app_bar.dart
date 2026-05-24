import 'package:flutter/material.dart';
import '../../l10n/s.dart';

/// 可搜索的 AppBar
/// 支持正常模式（显示标题）和搜索模式（显示输入框）之间的切换
class SearchableAppBar extends StatefulWidget implements PreferredSizeWidget {
  /// 正常模式下显示的标题
  final String title;

  /// 是否处于搜索模式
  final bool isSearchMode;

  /// 点击搜索按钮时的回调
  final VoidCallback onSearchPressed;

  /// 点击关闭搜索按钮时的回调
  final VoidCallback onCloseSearch;

  /// 提交搜索时的回调
  final ValueChanged<String> onSearch;

  /// 搜索框文字变化时的回调
  final ValueChanged<String>? onSearchChanged;

  /// 点击过滤器按钮时的回调
  final VoidCallback? onFilterPressed;

  /// 是否显示过滤器按钮
  final bool showFilterButton;

  /// 过滤器是否激活（显示指示点）
  final bool filterActive;

  /// 搜索框的初始值
  final String? initialSearchText;

  /// 搜索框提示文字
  final String searchHint;

  /// 返回按钮回调（为 null 则使用默认返回逻辑）
  final VoidCallback? onBackPressed;

  /// 非搜索模式下是否显示搜索按钮
  final bool showSearchButton;

  /// 注入到 actions 末尾的额外按钮（仅在非搜索模式生效）。
  final List<Widget> trailingActions;

  const SearchableAppBar({
    super.key,
    required this.title,
    required this.isSearchMode,
    required this.onSearchPressed,
    required this.onCloseSearch,
    required this.onSearch,
    this.onSearchChanged,
    this.onFilterPressed,
    this.showFilterButton = false,
    this.filterActive = false,
    this.initialSearchText,
    this.searchHint = '',
    this.onBackPressed,
    this.showSearchButton = true,
    this.trailingActions = const [],
  });

  @override
  State<SearchableAppBar> createState() => _SearchableAppBarState();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

class _SearchableAppBarState extends State<SearchableAppBar>
    with SingleTickerProviderStateMixin {
  late TextEditingController _searchController;
  late FocusNode _focusNode;
  late AnimationController _animationController;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialSearchText);
    _focusNode = FocusNode();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _animation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );

    if (widget.isSearchMode) {
      _animationController.value = 1.0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(SearchableAppBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSearchMode != oldWidget.isSearchMode) {
      if (widget.isSearchMode) {
        _animationController.forward();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _focusNode.requestFocus();
        });
      } else {
        _animationController.reverse();
        _searchController.clear();
        _focusNode.unfocus();
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _handleSubmit(String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      widget.onSearch(trimmed);
    }
  }

  void _handleClear() {
    _searchController.clear();
    widget.onSearchChanged?.call('');
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppBar(
      leading: widget.isSearchMode
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: widget.onCloseSearch,
            )
          : (widget.onBackPressed != null
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: widget.onBackPressed,
                  )
                : null),
      titleSpacing: widget.isSearchMode ? 0 : null,
      title: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          if (!widget.isSearchMode && _animation.value == 0) {
            return Text(widget.title);
          }
          return Opacity(
            opacity: _animation.value,
            child: TextField(
              controller: _searchController,
              focusNode: _focusNode,
              onSubmitted: _handleSubmit,
              onChanged: widget.onSearchChanged,
              textInputAction: TextInputAction.search,
              textAlignVertical: TextAlignVertical.center,
              style: theme.textTheme.bodyLarge,
              decoration: InputDecoration(
                hintText: widget.searchHint.isEmpty
                    ? context.l10n.common_searchHint
                    : widget.searchHint,
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: _handleClear,
                      )
                    : null,
              ),
            ),
          );
        },
      ),
      actions: widget.isSearchMode
          ? [
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () => _handleSubmit(_searchController.text),
                tooltip: context.l10n.common_search,
              ),
              if (widget.showFilterButton) _buildFilterButton(theme),
            ]
          : [
              if (widget.showSearchButton)
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: widget.onSearchPressed,
                  tooltip: context.l10n.common_search,
                ),
              if (widget.showFilterButton) _buildFilterButton(theme),
              ...widget.trailingActions,
            ],
    );
  }

  Widget _buildFilterButton(ThemeData theme) {
    return Stack(
      children: [
        IconButton(
          icon: const Icon(Icons.tune),
          onPressed: widget.onFilterPressed,
          tooltip: context.l10n.common_filter,
        ),
        if (widget.filterActive)
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}
