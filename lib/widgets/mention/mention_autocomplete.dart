import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/mention_user.dart';
import '../common/smart_avatar.dart';

/// 搜索用户的数据源类型
typedef MentionDataSource = Future<MentionSearchResult> Function(String term);

/// 用户提及自动补全组件
/// 
/// 监听文本输入中的 @ 符号触发自动补全搜索
/// 通过 [dataSource] 回调获取数据，实现与 API 层解耦
class MentionAutocomplete extends StatefulWidget {
  /// 关联的文本控制器
  final TextEditingController controller;

  /// 焦点节点（用于定位和取消）
  final FocusNode? focusNode;

  /// 数据源（由外部注入，解耦 API 调用）
  final MentionDataSource dataSource;

  /// 选中后的回调（返回完整用户名）
  final ValueChanged<String>? onMentionInserted;

  /// 子组件（通常是输入框）
  final Widget child;

  /// 防抖延迟（毫秒）
  final int debounceMs;

  const MentionAutocomplete({
    super.key,
    required this.controller,
    required this.dataSource,
    required this.child,
    this.focusNode,
    this.onMentionInserted,
    this.debounceMs = 300,
  });

  @override
  State<MentionAutocomplete> createState() => _MentionAutocompleteState();
}

class _MentionAutocompleteState extends State<MentionAutocomplete> {
  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();

  List<MentionItem> _results = [];
  bool _isLoading = false;
  int _selectedIndex = 0;
  String _currentSearchTerm = '';

  Timer? _debounceTimer;

  // @ 触发的起始位置
  int? _mentionStartIndex;
  
  // 记录上次的文本，用于判断是否真的有变化
  String _lastText = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    widget.focusNode?.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    widget.focusNode?.removeListener(_onFocusChanged);
    _debounceTimer?.cancel();
    _removeOverlay();
    super.dispose();
  }

  void _onFocusChanged() {
    if (widget.focusNode?.hasFocus != true) {
      _removeOverlay();
    }
  }

  void _onTextChanged() {
    final text = widget.controller.text;
    final selection = widget.controller.selection;

    // 1. 检查光标位置 (即使文本没变，光标移出范围也应关闭)
    if (_overlayEntry != null && _mentionStartIndex != null) {
      if (!selection.isValid || selection.baseOffset <= _mentionStartIndex!) {
        _removeOverlay();
        return;
      }
    }

    // 2. 避免重复搜索
    if (text == _lastText) {
      return;
    }
    _lastText = text;

    if (!selection.isValid || !selection.isCollapsed) {
      _removeOverlay();
      return;
    }

    final cursorPos = selection.baseOffset;
    if (cursorPos == 0) {
      _removeOverlay();
      return;
    }

    // 查找光标前的 @ 符号
    final textBeforeCursor = text.substring(0, cursorPos);

    // 使用正则匹配 @用户名 模式（@ 后面跟字母数字下划线）
    final match = RegExp(r'@([\w_-]*)$').firstMatch(textBeforeCursor);

    if (match == null) {
      _removeOverlay();
      return;
    }

    // 检查 @ 前面是否是合法的边界（空格、换行或开头）
    final atIndex = match.start;
    if (atIndex > 0) {
      final charBefore = textBeforeCursor[atIndex - 1];
      if (!RegExp(r'[\s\n]').hasMatch(charBefore)) {
        _removeOverlay();
        return;
      }
    }

    _mentionStartIndex = atIndex;
    final searchTerm = match.group(1) ?? '';
    _currentSearchTerm = searchTerm;

    // 防抖搜索（空字符串也会触发请求，与官方行为一致）
    _debounceTimer?.cancel();
    _debounceTimer = Timer(Duration(milliseconds: widget.debounceMs), () {
      if (mounted) _performSearch(searchTerm);
    });
  }

  Future<void> _performSearch(String term) async {
    if (!mounted) return;

    setState(() => _isLoading = true);
    _showOverlay();

    try {
      final result = await widget.dataSource(term);
      if (!mounted) return;

      setState(() {
        _results = result.items;
        _isLoading = false;
        _selectedIndex = 0;
      });

      _updateOverlay();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _results = [];
        _isLoading = false;
      });
      _updateOverlay();
    }
  }

  void _showOverlay() {
    if (_overlayEntry != null) return;

    _overlayEntry = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _updateOverlay() {
    _overlayEntry?.markNeedsBuild();
  }

  void _removeOverlay() {
    _debounceTimer?.cancel();
    _overlayEntry?.remove();
    _overlayEntry = null;
    _results = [];
    _mentionStartIndex = null;
    _currentSearchTerm = '';
  }

  void _selectItem(MentionItem item) {
    if (_mentionStartIndex == null) return;

    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final cursorPos = selection.isValid ? selection.baseOffset : text.length;

    // 替换 @xxx 为 @username + 空格
    final mentionText = '@${item.mentionName} ';
    final newText = text.replaceRange(_mentionStartIndex!, cursorPos, mentionText);
    final newCursorPos = _mentionStartIndex! + mentionText.length;

    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorPos),
    );

    widget.onMentionInserted?.call(item.mentionName);
    _removeOverlay();
  }

  void _handleKeyEvent(KeyEvent event) {
    if (_overlayEntry == null || _results.isEmpty) return;

    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() {
          _selectedIndex = (_selectedIndex + 1) % _results.length;
        });
        _updateOverlay();
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() {
          _selectedIndex = (_selectedIndex - 1 + _results.length) % _results.length;
        });
        _updateOverlay();
      } else if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.tab) {
        _selectItem(_results[_selectedIndex]);
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        _removeOverlay();
      }
    }
  }

  Widget _buildOverlay(BuildContext context) {
    final theme = Theme.of(context);

    // 计算显示位置
    var showAbove = false; // 默认向下
    double anchorY = 0; // 锚点 Y 坐标（相对于组件顶部）
    double effectiveMaxHeight = 250.0; // 默认最大高度
    
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox != null) {
      final pos = renderBox.localToGlobal(Offset.zero);
      final size = renderBox.size;
      final mediaQuery = MediaQuery.of(context);
      final screenHeight = mediaQuery.size.height;
      final keyboardHeight = mediaQuery.viewInsets.bottom;
      final padding = mediaQuery.padding;

      // 1. 估算光标位置
      double cursorY = 0;
      double lineHeight = 20; // 默认行高
      
      final text = widget.controller.text;
      final selection = widget.controller.selection;
      
      if (selection.isValid) {
        // 使用 bodyLarge 估算 (Material 3 TextField 默认样式)
        // 减去水平 padding (假设左右各 12)
        final maxWidth = size.width - 24; 
        final style = theme.textTheme.bodyLarge?.copyWith(fontSize: 16) ?? const TextStyle(fontSize: 16);
        
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
          maxLines: null,
        );
        
        painter.layout(maxWidth: maxWidth > 0 ? maxWidth : size.width);
        
        // 获取光标位置
        final caretOffset = painter.getOffsetForCaret(selection.base, Rect.zero);
        cursorY = caretOffset.dy;
        lineHeight = painter.preferredLineHeight;
      }
      
      // 添加垂直 padding 偏移
      const verticalPadding = 12.0;
      cursorY += verticalPadding;

      // 2. 限制在组件可视范围内
      final clampedCursorTop = cursorY.clamp(0.0, size.height);
      final clampedCursorBottom = (cursorY + lineHeight).clamp(0.0, size.height);

      // 3. 计算可用空间
      const menuHeight = 220.0; // 稍微调小阈值 (因列表项变小了)
      
      final globalBottomY = pos.dy + clampedCursorBottom;
      final spaceBelow = screenHeight - keyboardHeight - padding.bottom - globalBottomY;
      
      final globalTopY = pos.dy + clampedCursorTop;
      final spaceAbove = globalTopY - padding.top - kToolbarHeight;

      final isBottomHalf = (pos.dy + size.height / 2) > (screenHeight / 2);

      // 4. 决策方向
      // 策略优化：如果位于屏幕下半部分，且上方空间充足，优先显示在上方
      // 这可以有效解决键盘高度检测延迟或为0时，弹窗被遮挡的问题
      if (isBottomHalf && spaceAbove >= menuHeight) {
        showAbove = true;
        anchorY = clampedCursorTop;
      } else if (spaceBelow >= menuHeight) {
        showAbove = false;
        anchorY = clampedCursorBottom;
      } else if (spaceAbove >= menuHeight) {
         // 下半部分空间不够，但上半部分不在优先也不够？不对，如果 enters here, means !isBottomHalf or spaceAbove < menuHeight
         // Wait, logic:
         // If isBottomHalf && spaceAbove OK -> Up.
         // Else if spaceBelow OK -> Down.
         // Else if spaceAbove OK -> Up. (This catches TopHalf where Below is bad but Above is OK).
        showAbove = true;
        anchorY = clampedCursorTop;
      } else {
        // 空间都不够时，选择空间大的一侧
        showAbove = spaceAbove > spaceBelow;
        anchorY = showAbove ? clampedCursorTop : clampedCursorBottom;
      }
      
      // 计算实际可用高度
      final availableHeight = showAbove ? spaceAbove : spaceBelow;
      effectiveMaxHeight = availableHeight < 250.0 ? availableHeight : 250.0;

      return Positioned(
        width: 280,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: Offset(0, anchorY + (showAbove ? -4 : 4)), // 根据光标位置偏移
          followerAnchor: showAbove ? Alignment.bottomLeft : Alignment.topLeft,
          targetAnchor: Alignment.topLeft, 
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: effectiveMaxHeight),
                child: _buildContent(theme),
              ),
            ),
          ),
        ),
      );
    }
    
    return const SizedBox.shrink(); // Fallback if renderBox is null
  }

  Widget _buildContent(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部 Loading 条 (保留旧数据时显示)
        if (_isLoading)
          LinearProgressIndicator(
            minHeight: 2,
            backgroundColor: Colors.transparent,
            color: theme.colorScheme.primary,
          ),
          
        if (_results.isEmpty && !_isLoading)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _currentSearchTerm.isEmpty ? '输入用户名搜索' : '未找到匹配用户',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        else if (_results.isNotEmpty)
          Flexible(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final item = _results[index];
                  final isSelected = index == _selectedIndex;

                  return _MentionItemTile(
                    item: item,
                    isSelected: isSelected,
                    onTap: () => _selectItem(item),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: FocusNode(skipTraversal: true),
      onKeyEvent: _handleKeyEvent,
      child: CompositedTransformTarget(
        link: _layerLink,
        child: widget.child,
      ),
    );
  }
}

/// 单个提及项 Tile
class _MentionItemTile extends StatelessWidget {
  final MentionItem item;
  final bool isSelected;
  final VoidCallback onTap;

  const _MentionItemTile({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), // 调小 Padding (16/12 -> 12/8)
          color: isSelected ? theme.colorScheme.primaryContainer.withValues(alpha: 0.1) : null,
          child: Row(
            children: [
              _buildAvatar(theme),
              const SizedBox(width: 8), // 调小间距 (12 -> 8)
              Expanded(child: _buildInfo(theme)),
              if (item.isGroup) _buildGroupBadge(theme),
            ],
          ),
        ),
      );
  }

  Widget _buildAvatar(ThemeData theme) {
    if (item.isUser) {
      final avatarUrl = item.user?.getAvatarUrl(size: 40);
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        return SmartAvatar(
          imageUrl: avatarUrl,
          radius: 12,
          fallbackText: item.mentionName,
        );
      }
    }

    // 群组或无头像时显示首字母
    final initial = item.mentionName.isNotEmpty ? item.mentionName[0].toUpperCase() : '?';
    return CircleAvatar(
      radius: 12,
      backgroundColor: item.isGroup
          ? theme.colorScheme.secondaryContainer
          : theme.colorScheme.primaryContainer,
      child: Text(
        initial,
        style: TextStyle(
          color: item.isGroup
              ? theme.colorScheme.onSecondaryContainer
              : theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
          fontSize: 12, // 调小 (14->12)
        ),
      ),
    );
  }

  Widget _buildInfo(ThemeData theme) {
    final username = item.mentionName;
    final displayName = item.displayName;
    final showDisplayName = displayName.isNotEmpty && displayName != username;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '@$username',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (showDisplayName)
          Text(
            displayName,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  Widget _buildGroupBadge(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '群组',
        style: TextStyle(
          fontSize: 10,
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
