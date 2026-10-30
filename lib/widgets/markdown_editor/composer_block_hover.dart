import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerHoverEvent;
import 'package:flutter/material.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

import 'composer_object_adapter.dart';
import 'composer_object_surface.dart';

/// A single gutter follows block identity, never the pointer's line within it.
/// The same control stays mounted while its anchored menu opens and closes.
class ComposerBlockHover extends StatefulWidget {
  const ComposerBlockHover({
    super.key,
    required this.editor,
    required this.contentActions,
    required this.focusNode,
    required this.onMenu,
    required this.onPicker,
    required this.topInset,
    required this.bottomInset,
    required this.desktop,
    required this.child,
  });
  static const expandedControlWidth = 840.0;
  static double gutterFor(double width, {required bool desktop}) => desktop
      ? 48 + 36 * ((width - 640) / (expandedControlWidth - 640)).clamp(0.0, 1.0)
      : 64;

  final EditorState editor;
  final FluxdoEditorContentActions contentActions;
  final FocusNode focusNode;
  final Future<void> Function(EditorObjectTarget, Rect) onMenu;
  final Future<void> Function(EditorObjectTarget, Rect) onPicker;
  final double topInset;
  final double bottomInset;
  final bool desktop;
  final Widget child;
  @override
  State<ComposerBlockHover> createState() => _ComposerBlockHoverState();
}

class _ComposerBlockHoverState extends State<ComposerBlockHover> {
  final _root = GlobalKey();
  EditorObjectSelection? _hover;
  EditorObjectSelection? _active;
  EditorObjectSelection? _menuTarget;
  Rect? _buttonRect;
  Rect? _visibleBounds;
  bool _scheduled = false;
  bool _dragging = false;
  bool _pressingHandle = false;

  @override
  void initState() {
    super.initState();
    widget.editor.addListener(_changed);
    widget.focusNode.addListener(_changed);
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(ComposerBlockHover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editor != widget.editor) {
      oldWidget.editor.removeListener(_changed);
      widget.editor.addListener(_changed);
      _hover = null;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_changed);
      widget.focusNode.addListener(_changed);
    }
    _scheduleRefresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    MediaQuery.sizeOf(context);
    _scheduleRefresh();
  }

  @override
  void dispose() {
    widget.editor.removeListener(_changed);
    widget.focusNode.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (_menuTarget == null) _hover = null;
    _scheduleRefresh();
  }

  EditorObjectSelection? _snapshot(EditorObjectTarget target) {
    final object = resolveEditorObject(widget.editor, target);
    if (object == null) return null;
    // A standalone image has image commands; mixed text keeps paragraph commands.
    if (target is EditorBlockTarget && object.block is TextBlock) {
      final block = object.block as TextBlock;
      if (block.content.length == 1 && block.content.atoms[0] is ImageRun) {
        target = EditorImageTarget(
          block.id,
          0,
          (block.content.atoms[0] as ImageRun).src,
        );
      }
    }
    final rect = widget.contentActions.objectBounds(target);
    return rect == null
        ? null
        : EditorObjectSelection(
            target: target,
            globalRect: rect,
            revision: widget.editor.docRevision,
          );
  }

  void _scheduleRefresh() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      EditorObjectSelection? active;
      final object = widget.contentActions.objectSelection;
      final caret = widget.editor.selection;
      if (object != null) {
        active = _snapshot(object.target);
      } else if (widget.focusNode.hasFocus &&
          caret != null &&
          caret.isCollapsed) {
        active = _snapshot(EditorBlockTarget(caret.extent.blockId));
      }
      final hover = _hover == null ? null : _snapshot(_hover!.target);
      if (active != _active || hover != _hover) {
        setState(() {
          _active = active;
          _hover = hover;
        });
      }
    });
  }

  void _onHover(PointerHoverEvent event) {
    if (!widget.desktop ||
        event.kind != PointerDeviceKind.mouse ||
        _menuTarget != null ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final point = event.position;
    if (_visibleBounds?.contains(point) != true) return;
    if (_buttonRect?.contains(point) == true) return;
    final old = _hover ?? _active;
    // Preserve the child paragraph while crossing its gutter inside a container.
    if (old != null &&
        _buttonRect != null &&
        point.dx < old.globalRect.left &&
        old.globalRect.expandToInclude(_buttonRect!).contains(point)) {
      return;
    }
    final hit = widget.contentActions.blockAt(point, leadingSlop: 72);
    final next = hit == null ? null : _snapshot(hit.target);
    if (next != _hover) setState(() => _hover = next);
  }

  Future<void> _open(
    EditorObjectSelection target,
    Rect anchor, {
    required bool picker,
  }) async {
    if (_menuTarget != null) return;
    setState(() => _menuTarget = target);
    try {
      await (picker ? widget.onPicker : widget.onMenu)(target.target, anchor);
    } finally {
      if (mounted) {
        setState(() {
          _menuTarget = null;
          _hover = null;
        });
        _scheduleRefresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final box = _root.currentContext?.findRenderObject();
      final origin = box is RenderBox && box.hasSize
          ? box.localToGlobal(Offset.zero)
          : Offset.zero;
      final visible = Rect.fromLTRB(
        8,
        widget.topInset + 8,
        bounds.maxWidth - 8,
        bounds.maxHeight - widget.bottomInset - 8,
      );
      _visibleBounds = visible.shift(origin);
      final target = _menuTarget ?? _hover ?? _active;
      final object = target == null
          ? null
          : resolveEditorObject(widget.editor, target.target);
      final block = object?.block;
      final empty =
          target?.target is EditorBlockTarget &&
          block is TextBlock &&
          block.content.length == 0;
      final rect = target?.globalRect.shift(-origin);
      final size = widget.desktop ? 32.0 : 48.0;
      final compact =
          widget.desktop &&
          bounds.maxWidth < ComposerBlockHover.expandedControlWidth;
      final canChangeType =
          target?.target is EditorBlockTarget &&
          block is TextBlock &&
          object?.image == null;
      final splitControls = canChangeType && !compact;
      final width = empty || compact ? size : size * 2;
      final show =
          !_dragging &&
          object != null &&
          rect != null &&
          (widget.desktop || empty) &&
          rect.overlaps(visible) &&
          rect.left >= width + 16 &&
          visible.height >= size;
      // Anchor to the block's first line; only clamp while its top is offscreen.
      final handle = show
          ? Rect.fromLTWH(
              rect.left - width - 8,
              (rect.top + 4).clamp(visible.top, visible.bottom - size),
              width,
              size,
            )
          : null;
      _buttonRect = handle?.shift(origin);
      final label = object == null
          ? ''
          : ComposerObjectAdapter.forObject(object).label;
      final colors = Theme.of(context).colorScheme;
      Widget button({
        required Key key,
        required String tooltip,
        required Widget icon,
        required bool picker,
      }) => Builder(
        builder: (buttonContext) => IconButton(
          key: key,
          tooltip: tooltip,
          style: IconButton.styleFrom(
            minimumSize: Size.square(size),
            maximumSize: Size.square(size),
            padding: const EdgeInsets.all(5),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            foregroundColor: picker ? colors.primary : colors.onSurfaceVariant,
          ),
          onPressed: target == null
              ? null
              : () {
                  final buttonBox =
                      buttonContext.findRenderObject() as RenderBox;
                  _open(
                    target,
                    buttonBox.localToGlobal(Offset.zero) & buttonBox.size,
                    picker: picker,
                  );
                },
          icon: icon,
        ),
      );
      Widget unifiedMenuButton() => Builder(
        builder: (buttonContext) => Tooltip(
          message: '$label操作',
          child: TextButton(
            key: const ValueKey('composer-block-hover-select'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.standard,
              minimumSize: Size(width, size),
              maximumSize: Size(width, size),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: colors.onSurfaceVariant,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
              ),
            ),
            onPressed: target == null
                ? null
                : () {
                    final buttonBox =
                        buttonContext.findRenderObject() as RenderBox;
                    _open(
                      target,
                      buttonBox.localToGlobal(Offset.zero) & buttonBox.size,
                      picker: false,
                    );
                  },
            child: ExcludeSemantics(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _BlockTypeIcon(object: object),
                  if (!compact)
                    const Icon(Icons.drag_indicator_rounded, size: 20),
                ],
              ),
            ),
          ),
        ),
      );
      return MouseRegion(
        key: _root,
        onHover: _onHover,
        onExit: (_) {
          if (_hover != null && _menuTarget == null) {
            setState(() => _hover = null);
          }
        },
        child: Listener(
          onPointerDown: (event) {
            _pressingHandle = _buttonRect?.contains(event.position) == true;
            if (!_pressingHandle && _hover != null) {
              setState(() => _hover = null);
            }
          },
          onPointerMove: (_) {
            if (!_pressingHandle && !_dragging) {
              setState(() => _dragging = true);
            }
          },
          onPointerUp: (_) {
            _pressingHandle = false;
            if (_dragging) setState(() => _dragging = false);
          },
          onPointerCancel: (_) {
            _pressingHandle = false;
            if (_dragging) setState(() => _dragging = false);
          },
          child: NotificationListener<ScrollUpdateNotification>(
            onNotification: (_) {
              _scheduleRefresh();
              return false;
            },
            child: Stack(
              children: [
                Positioned.fill(child: widget.child),
                Positioned.fromRect(
                  key: const ValueKey('composer-block-hover-handle-position'),
                  rect: handle ?? Rect.fromLTWH(0, 0, width, size),
                  child: Visibility(
                    visible: handle != null,
                    maintainState: true,
                    child: GestureDetector(
                      onSecondaryTapUp: target == null
                          ? null
                          : (details) => _open(
                              target,
                              details.globalPosition & Size.zero,
                              picker: false,
                            ),
                      child: TextFieldTapRegion(
                        child: ComposerObjectSurface(
                          key: const ValueKey('composer-block-control-surface'),
                          compact: true,
                          radius: 8,
                          child: Material(
                            color: _menuTarget != null
                                ? colors.primary.withValues(alpha: .12)
                                : Colors.transparent,
                            child: Row(
                              children: [
                                if (empty)
                                  button(
                                    key: const ValueKey('composer-block-add'),
                                    tooltip: '添加块',
                                    icon: const Icon(
                                      Icons.add_rounded,
                                      size: 22,
                                    ),
                                    picker: true,
                                  )
                                else if (!splitControls)
                                  unifiedMenuButton()
                                else ...[
                                  button(
                                    key: const ValueKey('composer-block-type'),
                                    tooltip: '切换$label类型',
                                    icon: _BlockTypeIcon(object: object),
                                    picker: true,
                                  ),
                                  button(
                                    key: const ValueKey(
                                      'composer-block-hover-select',
                                    ),
                                    tooltip: '$label操作',
                                    icon: const Icon(
                                      Icons.drag_indicator_rounded,
                                      size: 20,
                                    ),
                                    picker: false,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _BlockTypeIcon extends StatelessWidget {
  const _BlockTypeIcon({required this.object});
  final ResolvedEditorObject? object;
  @override
  Widget build(BuildContext context) {
    final object = this.object;
    if (object == null) return const Icon(Icons.title_rounded, size: 20);
    final block = object.block;
    if (object.target is EditorBlockTarget &&
        block is TextBlock &&
        block.isHeading) {
      return Text(
        'H${block.headingLevel}',
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      );
    }
    final icon = object.image != null
        ? Icons.image_outlined
        : switch (object.frame) {
            DetailsFrame() => Icons.expand_more_rounded,
            QuoteFrame() || QuoteCardFrame() => Icons.format_quote_rounded,
            CalloutFrame() => Icons.info_outline_rounded,
            SpoilerFrame() => Icons.blur_on_rounded,
            null => switch (block) {
              TextBlock(:final isListItem, :final ordered) when isListItem =>
                ordered
                    ? Icons.format_list_numbered_rounded
                    : Icons.format_list_bulleted_rounded,
              TextBlock() => Icons.title_rounded,
              IslandBlock(:final node) => switch (node) {
                ParagraphNode() || HeadingNode() => Icons.title_rounded,
                ListNode() => Icons.format_list_bulleted_rounded,
                BlockquoteNode() ||
                QuoteCardNode() => Icons.format_quote_rounded,
                SpoilerBlockNode() => Icons.blur_on_rounded,
                OneboxNode() => Icons.link_rounded,
                CalloutNode() => Icons.info_outline_rounded,
                DetailsNode() => Icons.expand_more_rounded,
                ImageGridNode(:final mode) =>
                  mode == ImageGridMode.carousel
                      ? Icons.view_carousel_outlined
                      : Icons.grid_view_rounded,
                TableNode() => Icons.table_chart_outlined,
                CodeBlockNode(:final language) =>
                  language == 'mermaid'
                      ? Icons.account_tree_outlined
                      : Icons.code_rounded,
                HorizontalRuleNode() => Icons.horizontal_rule_rounded,
                BlankLineNode() => Icons.space_bar_rounded,
                FootnotesSectionNode() => Icons.superscript_rounded,
                VideoNode() || LazyVideoNode() => Icons.videocam_outlined,
                AudioNode(:final voice) =>
                  voice ? Icons.mic_rounded : Icons.audiotrack_rounded,
                IframeNode() => Icons.web_asset_rounded,
                PolicyNode() => Icons.fact_check_outlined,
                MathBlockNode() => Icons.functions_rounded,
                SvgNode() => Icons.draw_outlined,
                PollNode() => Icons.poll_outlined,
                ChatTranscriptNode() => Icons.forum_outlined,
                DefinitionListNode() => Icons.menu_book_outlined,
              },
            },
          };
    return Icon(icon, size: 20);
  }
}
