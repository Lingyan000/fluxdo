import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/dialog_utils.dart';
import '../../../../../l10n/s.dart';

/// 话题进度指示器，类似 Discourse 的 topic-progress 组件
/// 显示当前索引/总数（基于 stream 索引，不是 post_number）
class TopicProgress extends StatelessWidget {
  /// 当前 stream 索引（1-based）
  final int currentIndex;

  /// stream 总数（实际存在的帖子数量）
  final int totalCount;

  /// 阅读进度百分比 (0.0 - 1.0)
  final double progressPercent;

  /// 点击回调，展开时间线
  final VoidCallback? onTap;

  const TopicProgress({
    super.key,
    required this.currentIndex,
    required this.totalCount,
    this.progressPercent = 0.0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 4,
      shadowColor: Colors.black26,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 40,
          width: 120, // 固定宽度或根据内容调整
          child: Stack(
            children: [
              // 进度条背景
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: progressPercent.clamp(0.0, 1.0),
                  child: Container(
                    color: theme.colorScheme.primary.withValues(alpha:0.12),
                  ),
                ),
              ),
              // 楼层数字
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '$currentIndex',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        '/',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(alpha:0.5),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      '$totalCount',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 全屏时间线组件，用于快速跳转到指定楼层
/// 通过拖动滑块或点击轨道来选择目标位置（基于 stream 索引）
class TopicTimelineSheet extends StatefulWidget {
  /// 当前 stream 索引（1-based）
  final int currentIndex;

  /// stream 数组（帖子 ID 列表）
  final List<int> stream;

  /// 跳转回调，参数是帖子 ID
  final void Function(int postId) onJumpToPostId;

  /// 话题标题
  final String? title;

  /// 状态栏高度（从父 context 传入，避免 modal 内部 padding 被清零）
  final double topPadding;

  const TopicTimelineSheet({
    super.key,
    required this.currentIndex,
    required this.stream,
    required this.onJumpToPostId,
    required this.topPadding,
    this.title,
  });

  @override
  State<TopicTimelineSheet> createState() => _TopicTimelineSheetState();
}

class _TopicTimelineSheetState extends State<TopicTimelineSheet> {
  late int _selectedIndex;
  bool _isDragging = false;
  bool _isEditing = false;
  late TextEditingController _textController;
  final FocusNode _focusNode = FocusNode();

  int get _totalCount => widget.stream.length;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.currentIndex.clamp(1, _totalCount);
    _textController = TextEditingController();
  }

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _enterEditMode() {
    setState(() {
      _isEditing = true;
      _textController.text = '$_selectedIndex';
      _textController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _textController.text.length,
      );
    });
    // 延迟请求焦点，确保 TextField 已构建
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  void _commitEdit() {
    final value = int.tryParse(_textController.text);
    if (value != null && value >= 1 && value <= _totalCount) {
      if (value != _selectedIndex) {
        HapticFeedback.selectionClick();
      }
      setState(() {
        _selectedIndex = value;
        _isEditing = false;
      });
    } else {
      // 无效输入，恢复原值
      setState(() => _isEditing = false);
    }
    _focusNode.unfocus();
  }

  void _cancelEdit() {
    setState(() => _isEditing = false);
    _focusNode.unfocus();
  }

  void _updateIndex(double percent) {
    final newIndex = (percent * (_totalCount - 1) + 1).round().clamp(1, _totalCount);
    if (newIndex != _selectedIndex) {
      HapticFeedback.selectionClick();
      setState(() => _selectedIndex = newIndex);
    }
  }

  void _handleDragStart(DragStartDetails details, BoxConstraints constraints) {
    if (_isEditing) _cancelEdit();
    setState(() => _isDragging = true);
    _updateIndexFromOffset(details.localPosition.dy, constraints.maxHeight);
  }

  void _handleDragUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    _updateIndexFromOffset(details.localPosition.dy, constraints.maxHeight);
  }

  void _handleDragEnd(DragEndDetails details) {
    setState(() => _isDragging = false);
  }

  void _handleTap(TapUpDetails details, BoxConstraints constraints) {
    if (_isEditing) _cancelEdit();
    _updateIndexFromOffset(details.localPosition.dy, constraints.maxHeight);
  }

  void _updateIndexFromOffset(double dy, double maxHeight) {
    const padding = 32.0;
    final trackHeight = maxHeight - padding * 2;
    final clampedY = (dy - padding).clamp(0.0, trackHeight);
    final percent = clampedY / trackHeight;
    _updateIndex(percent);
  }

  void _commitJump() {
    if (_selectedIndex >= 1 && _selectedIndex <= _totalCount) {
      final postId = widget.stream[_selectedIndex - 1];
      widget.onJumpToPostId(postId);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = _totalCount > 1
        ? (_selectedIndex - 1) / (_totalCount - 1)
        : 0.0;

    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.viewInsets.bottom;
    final screenHeight = mediaQuery.size.height;
    // 内容区高度：键盘弹出时收缩，确保不超过屏幕顶部状态栏
    // topPadding 从父 context 传入，因为 showModalBottomSheet 内部会清零 padding.top
    final contentHeight = (screenHeight * 0.6)
        .clamp(0.0, screenHeight - widget.topPadding - bottomInset);

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: contentHeight,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha:0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (widget.title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Text(
                  widget.title!,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
                child: Row(
                  children: [
                    // 左侧楼层信息展示
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            S.current.topic_currentFloor,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (_isEditing)
                            // 输入模式
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                SizedBox(
                                  width: 90,
                                  child: TextField(
                                    controller: _textController,
                                    focusNode: _focusNode,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly,
                                    ],
                                    style: theme.textTheme.displayMedium?.copyWith(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w900,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                                      border: UnderlineInputBorder(
                                        borderSide: BorderSide(
                                          color: theme.colorScheme.primary,
                                        ),
                                      ),
                                      focusedBorder: UnderlineInputBorder(
                                        borderSide: BorderSide(
                                          color: theme.colorScheme.primary,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                    onSubmitted: (_) => _commitEdit(),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '/ $_totalCount',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha:0.4),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            )
                          else
                            // 显示模式：点击进入输入
                            GestureDetector(
                              onTap: _enterEditMode,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    '$_selectedIndex',
                                    style: theme.textTheme.displayMedium?.copyWith(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '/ $_totalCount',
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha:0.4),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Icon(
                                    Icons.edit_outlined,
                                    size: 16,
                                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha:0.4),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 16),
                          if (_isEditing)
                            Row(
                              children: [
                                SizedBox(
                                  height: 32,
                                  child: TextButton(
                                    onPressed: _cancelEdit,
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    child: Text(S.current.common_cancel),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  height: 32,
                                  child: FilledButton.tonal(
                                    onPressed: _commitEdit,
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    child: Text(S.current.common_confirm),
                                  ),
                                ),
                              ],
                            )
                          else
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer.withValues(alpha:0.4),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _selectedIndex == widget.currentIndex ? S.current.topic_atCurrentPosition : S.current.topic_readyToJump,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    // 右侧垂直轨道
                    Container(
                      width: 80,
                      alignment: Alignment.centerRight,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          const padding = 32.0;
                          final trackHeight = constraints.maxHeight - padding * 2;
                          final handleSize = _isDragging ? 56.0 : 48.0;
                          final scrollerTop = padding + (percent * trackHeight) - (handleSize / 2);

                          return GestureDetector(
                            onVerticalDragStart: (d) => _handleDragStart(d, constraints),
                            onVerticalDragUpdate: (d) => _handleDragUpdate(d, constraints),
                            onVerticalDragEnd: _handleDragEnd,
                            onTapUp: (d) => _handleTap(d, constraints),
                            behavior: HitTestBehavior.opaque,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                // 轨道背景
                                Positioned(
                                  right: 20,
                                  top: padding,
                                  bottom: padding,
                                  child: Container(
                                    width: 6,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                                // 激活进度
                                Positioned(
                                  right: 20,
                                  top: padding,
                                  height: percent * trackHeight,
                                  child: Container(
                                    width: 6,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary.withValues(alpha:0.5),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                                // 起点标记 (直接放在轨道顶端)
                                Positioned(
                                  right: 18,
                                  top: padding - 5,
                                  child: _buildMark(theme, true),
                                ),
                                // 终点标记 (直接放在轨道底端)
                                Positioned(
                                  right: 18,
                                  bottom: padding - 5,
                                  child: _buildMark(theme, false),
                                ),
                                // 拖动手柄
                                AnimatedPositioned(
                                  duration: _isDragging ? Duration.zero : const Duration(milliseconds: 200),
                                  curve: Curves.easeOutCubic,
                                  right: 0,
                                  top: scrollerTop,
                                  child: _buildHandle(theme),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 底部操作按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: Text(S.current.common_cancel),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: FilledButton(
                      onPressed: _commitJump,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text(S.current.topic_jump, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildMark(ThemeData theme, bool isStart) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: isStart ? theme.colorScheme.primary : theme.colorScheme.surface,
        border: Border.all(
          color: theme.colorScheme.primary,
          width: 2,
        ),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha:0.05),
            blurRadius: 2,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }

  Widget _buildHandle(ThemeData theme) {
    final size = _isDragging ? 52.0 : 44.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha:0.3),
            blurRadius: _isDragging ? 12 : 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: const Icon(Icons.unfold_more, color: Colors.white),
    );
  }
}

/// 显示时间线底部弹窗的便捷方法
Future<void> showTopicTimelineSheet({
  required BuildContext context,
  required int currentIndex,
  required List<int> stream,
  required void Function(int postId) onJumpToPostId,
  String? title,
}) {
  // 在 modal 外部获取状态栏高度，因为 showModalBottomSheet 会清零 padding.top
  final topPadding = MediaQuery.of(context).padding.top;
  return showAppBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => TopicTimelineSheet(
      currentIndex: currentIndex,
      stream: stream,
      onJumpToPostId: onJumpToPostId,
      title: title,
      topPadding: topPadding,
    ),
  );
}
