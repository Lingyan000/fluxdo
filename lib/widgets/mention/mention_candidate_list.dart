import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/widgets.dart';

/// 提及候选列表，键盘选择后仅滚动到足以显示整行的位置。
///
/// 候选是一次搜索返回的小集合，全部布局才能定位尚在视口外的选中行，
/// 也能正确处理有无显示名及系统字体缩放带来的不同行高。
class MentionCandidateList extends StatefulWidget {
  const MentionCandidateList({
    super.key,
    required this.selectedIndex,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  final int selectedIndex;
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  State<MentionCandidateList> createState() => _MentionCandidateListState();
}

class _MentionCandidateListState extends State<MentionCandidateList> {
  final _scroll = ScrollController();
  final _selectedKey = GlobalKey();
  bool _revealScheduled = false;

  void _scheduleReveal() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final object = _selectedKey.currentContext?.findRenderObject();
      if (object == null || !object.attached) return;
      final viewport = RenderAbstractViewport.maybeOf(object);
      if (viewport == null) return;
      final position = _scroll.position;
      final top = viewport.getOffsetToReveal(object, 0).offset;
      final bottom = viewport.getOffsetToReveal(object, 1).offset;
      var target = position.pixels;
      if (top < target) {
        target = top;
      } else if (bottom > target) {
        target = bottom;
      }
      final offset = target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (offset != position.pixels) position.jumpTo(offset);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleReveal();
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0) _scheduleReveal();
        return false;
      },
      child: SingleChildScrollView(
        controller: _scroll,
        primary: false,
        padding: widget.padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, child) in widget.children.indexed)
              KeyedSubtree(
                key: index == widget.selectedIndex ? _selectedKey : null,
                child: Semantics(
                  selected: index == widget.selectedIndex,
                  child: child,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
