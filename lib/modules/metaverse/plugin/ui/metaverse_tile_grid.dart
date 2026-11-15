part of 'metaverse_widget_library.dart';

/// 网格的高度策略，布局参数同时用于插件组件与开发中心预览。
enum MetaverseTileGridLayout { natural, equalHeight, masonry }

typedef _TileGridSettings = ({
  MetaverseTileGridLayout layout,
  int columns,
  double minTileWidth,
  double spacing,
  double runSpacing,
  TextDirection direction,
});

class _PluginTileGrid extends MultiChildRenderObjectWidget {
  const _PluginTileGrid({required this.settings, required super.children});
  final _TileGridSettings settings;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPluginTileGrid(settings);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPluginTileGrid renderObject,
  ) {
    renderObject.settings = settings;
  }
}

class _TileGridParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPluginTileGrid extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          _TileGridParentData
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _TileGridParentData
        > {
  _RenderPluginTileGrid(this._settings);
  _TileGridSettings _settings;

  set settings(_TileGridSettings value) {
    if (_settings == value) return;
    _settings = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _TileGridParentData) {
      child.parentData = _TileGridParentData();
    }
  }

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.constrainWidth(
            _settings.minTileWidth > 0 ? _settings.minTileWidth : 160,
          );
    if (childCount == 0) return constraints.constrain(Size(width, 0));
    final gap = _settings.spacing.clamp(0.0, width);
    var columns = _settings.columns;
    if (columns <= 0) {
      columns = _settings.minTileWidth > 0
          ? ((width + gap) / (_settings.minTileWidth + gap)).floor()
          : width >= 720
          ? 3
          : width >= 320
          ? 2
          : 1;
    }
    // 极窄容器中减少列数，确保间距不会挤出负宽度。
    final maxColumns = math.max(1, ((width + gap) / (gap + 1)).floor());
    columns = columns.clamp(1, maxColumns);
    final tileWidth = (width - gap * (columns - 1)) / columns;
    final childConstraints = BoxConstraints.tightFor(width: tileWidth);
    final children = getChildrenAsList();
    final sizes = <Size>[];
    for (final child in children) {
      if (dry) {
        sizes.add(child.getDryLayout(childConstraints));
      } else {
        child.layout(childConstraints, parentUsesSize: true);
        sizes.add(child.size);
      }
    }

    void position(int index, int column, double top) {
      if (dry) return;
      final left = _settings.direction == TextDirection.ltr
          ? column * (tileWidth + gap)
          : width - tileWidth - column * (tileWidth + gap);
      final parentData =
          children[index].parentData! as _TileGridParentData;
      parentData.offset = Offset(left, top);
    }

    var height = 0.0;
    if (_settings.layout == MetaverseTileGridLayout.masonry) {
      final bottoms = List.filled(math.min(columns, children.length), 0.0);
      for (var index = 0; index < children.length; index++) {
        var column = 0;
        for (var candidate = 1; candidate < bottoms.length; candidate++) {
          if (bottoms[candidate] < bottoms[column]) column = candidate;
        }
        final top = bottoms[column];
        position(index, column, top);
        final bottom = top + sizes[index].height;
        height = math.max(height, bottom);
        bottoms[column] = bottom + _settings.runSpacing;
      }
    } else {
      for (var start = 0; start < children.length; start += columns) {
        final end = math.min(start + columns, children.length);
        var rowHeight = 0.0;
        for (var index = start; index < end; index++) {
          rowHeight = math.max(rowHeight, sizes[index].height);
        }
        for (var index = start; index < end; index++) {
          if (!dry && _settings.layout == MetaverseTileGridLayout.equalHeight) {
            children[index].layout(
              BoxConstraints.tight(Size(tileWidth, rowHeight)),
              parentUsesSize: true,
            );
          }
          position(index, index - start, height);
        }
        height += rowHeight;
        if (end < children.length) height += _settings.runSpacing;
      }
    }
    return constraints.constrain(Size(width, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
