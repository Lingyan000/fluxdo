import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:positioned_sliver_list/positioned_sliver_list.dart';
// 0.2.5 的 ListController.jumpToIndex 会停止当前滚动活动。结构更新只需
// 请求引擎的同帧布局修正，使用这个固定版本的布局接口保留拖动和惯性。
// ignore: implementation_imports
import 'package:positioned_sliver_list/src/render_object.dart'
    show RenderSuperSliverList;

/// 按稳定标识保留阅读位置，由列表引擎维护高度和索引定位。
class PositionedStreamList extends StatefulWidget {
  const PositionedStreamList({
    super.key,
    required this.scrollController,
    required this.listController,
    required this.itemKeys,
    required this.itemBuilder,
    required this.initialIndex,
    required this.positionKey,
    required this.cacheExtent,
    this.fallbackAnchorKeys = const {},
    this.physics = const AlwaysScrollableScrollPhysics(
      parent: BouncingScrollPhysics(),
    ),
    this.addAutomaticKeepAlives = true,
    this.reverse = false,
  });

  final ScrollController scrollController;
  final ListController listController;
  final List<String> itemKeys;
  final IndexedWidgetBuilder itemBuilder;
  final int? initialIndex;
  final Object positionKey;
  final double cacheExtent;
  final Map<String, String> fallbackAnchorKeys;
  final ScrollPhysics physics;
  final bool addAutomaticKeepAlives;
  final bool reverse;

  @override
  State<PositionedStreamList> createState() => _PositionedStreamListState();
}

class _PositionedStreamListState extends State<PositionedStreamList> {
  GlobalKey _sliverKey = GlobalKey();
  late Map<String, int> _indices = _indexKeys();

  Map<String, int> _indexKeys() => {
    for (var i = 0; i < widget.itemKeys.length; i++) widget.itemKeys[i]: i,
  };

  @override
  void didUpdateWidget(PositionedStreamList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _indices = _indexKeys();
    if (widget.positionKey != oldWidget.positionKey) {
      _sliverKey = GlobalKey();
      return;
    }
    if (widget.listController != oldWidget.listController ||
        !widget.listController.isAttached ||
        listEquals(widget.itemKeys, oldWidget.itemKeys)) {
      return;
    }

    // 反向消息流贴底时，索引 0 始终代表最新一侧，由原点自然保持贴底。
    if (widget.reverse && widget.listController.stickTarget?.isBottom == true) {
      return;
    }

    // 显式跳楼优先，控制器会按新数据映射更新目标索引。
    final sliver = _sliverKey.currentContext?.findRenderObject();
    if (sliver is RenderSuperSliverList && sliver.hasPendingTarget) return;

    final anchor = widget.listController.anchor;
    if (anchor == null || anchor.index >= oldWidget.itemKeys.length) return;
    final anchorKey = oldWidget.itemKeys[anchor.index];
    final newIndex = _indices[anchorKey];
    if (newIndex != null) {
      // 增删数量相抵时索引可能不变，上方内容的排列和高度仍已变化。
      _restoreDuringLayout(newIndex, anchor.offsetInItem);
      return;
    }

    // 长帖分块被编辑或合并时，回到该帖仍存在的首段。
    final fallbackIndex = _indices[widget.fallbackAnchorKeys[anchorKey]];
    if (fallbackIndex != null) {
      _restoreDuringLayout(fallbackIndex, 0);
      return;
    }

    // 当前项被删除时保留其后最近的存活项，避免误锚到复用同索引的帖子。
    for (var i = anchor.index + 1; i < oldWidget.itemKeys.length; i++) {
      final survivingIndex = _indices[oldWidget.itemKeys[i]];
      if (survivingIndex != null) {
        _restoreDuringLayout(survivingIndex, 0);
        return;
      }
    }
  }

  void _restoreDuringLayout(int index, double offsetInItem) {
    final sliver = _sliverKey.currentContext?.findRenderObject();
    if (sliver is! RenderSuperSliverList ||
        !widget.scrollController.hasClients) {
      return;
    }
    // anchor 来自上一趟布局。惯性本帧可能已推进 pixels，把这段滚动
    // 一并保留；实际新增内容的高度和最终落点仍由列表引擎在布局期处理。
    final scrollDelta =
        widget.scrollController.position.pixels -
        sliver.constraints.scrollOffset;
    unawaited(sliver.jumpToIndex(index, 0, -offsetInItem - scrollDelta));
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: widget.scrollController,
      reverse: widget.reverse,
      scrollCacheExtent: ScrollCacheExtent.pixels(widget.cacheExtent),
      physics: widget.physics,
      slivers: [
        SuperSliverList.builder(
          key: _sliverKey,
          listController: widget.listController,
          initialIndex: widget.initialIndex,
          itemCount: widget.itemKeys.length,
          addAutomaticKeepAlives: widget.addAutomaticKeepAlives,
          findChildIndexCallback: (key) =>
              _indices[(key as ValueKey<String>).value],
          itemBuilder: (context, index) => KeyedSubtree(
            key: ValueKey(widget.itemKeys[index]),
            child: widget.itemBuilder(context, index),
          ),
        ),
      ],
    );
  }
}
