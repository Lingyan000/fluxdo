import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

import 'composer_image_properties.dart';
import 'composer_object_action.dart';
import 'composer_object_adapter.dart';

/// 一个选择会话服务所有块。类型适配器声明能力，通用操作只实现一次。
class ComposerObjectController extends ValueNotifier<ComposerObjectSelection?> {
  ComposerObjectController({
    required this.context,
    required this.editor,
    required this.contentActions,
    required this.resumeEditing,
    required this.focusEditor,
    required this.viewImage,
    required this.editIsland,
    required this.editContainer,
    required this.openLink,
    required this.requestMenu,
  }) : super(null);

  final BuildContext Function() context;
  final EditorState? Function() editor;
  final FluxdoEditorContentActions contentActions;
  final VoidCallback resumeEditing;
  final VoidCallback focusEditor;
  final void Function(ImageRun image, String heroTag) viewImage;
  final ValueChanged<IslandBlock> editIsland;
  final ValueChanged<ContainerFrame> editContainer;
  final ValueChanged<String> openLink;
  final ValueChanged<EditorObjectMenuRequest> requestMenu;
  EditorObjectSelection? _selection;
  bool _transient = false;
  bool _disposed = false;
  int _menuTicket = 0;
  bool menuOpen = false;
  bool get hasObjectSelection => _selection != null;
  Offset? _pointerPosition;
  (EditorObjectTarget, Offset)? _explicitInteraction;
  bool _toolbarSuppressed = false;

  void rememberPointer(Offset position) {
    final hoveredText =
        _explicitInteraction != null &&
        _selection != null &&
        editor()?.textBlockById(_selection!.target.blockId) != null;
    _pointerPosition = position;
    _explicitInteraction = null;
    _toolbarSuppressed = false;
    final selected = _selection;
    if (_disposed || _transient || selected == null || hoveredText) return;
    if (selected.globalRect.inflate(8).contains(position)) {
      value =
          (value ?? presentation(selected.target, rect: selected.globalRect))
              ?.withRect(selected.globalRect, interactionPosition: position);
    }
  }

  void selectObjectAt(
    EditorObjectTarget target,
    Offset position, {
    bool showMenu = false,
  }) {
    if (_disposed) return;
    // The hover handle selects a block without covering its editable contents.
    // Right-clicking that same handle is the direct path to its commands.
    _toolbarSuppressed = true;
    _explicitInteraction = (target, position);
    contentActions.selectObject(target);
    if (showMenu) {
      requestMenu(
        EditorObjectMenuRequest(
          target: target,
          globalPosition: position,
          transient: true,
        ),
      );
    }
  }

  void hideToolbarForScroll() {
    if (_disposed) return;
    _toolbarSuppressed = true;
    value = null;
  }

  Offset? interactionPositionFor(EditorObjectTarget target) {
    if (_explicitInteraction?.$1 == target) return _explicitInteraction!.$2;
    final bounds = contentActions.objectBounds(target);
    if (_pointerPosition != null &&
        bounds?.inflate(8).contains(_pointerPosition!) == true) {
      return _pointerPosition;
    }
    return bounds?.topLeft;
  }

  void update(EditorObjectSelection? selection) {
    if (_disposed) return;
    final previous = _selection;
    _selection = selection;
    // Grid images own their in-place controls; keep the shared action model
    // without replacing the mobile format bar with duplicate image buttons.
    if (selection?.target is EditorGridImageTarget) {
      value = null;
      return;
    }
    if (!_transient &&
        value != null &&
        selection != null &&
        previous?.target == selection.target &&
        previous?.revision == selection.revision) {
      value = value!.withRect(selection.globalRect);
      return;
    }
    value = _transient || _toolbarSuppressed || selection == null
        ? null
        : presentation(selection.target, rect: selection.globalRect);
  }

  ({int ticket, ComposerObjectSelection menu})? beginContextMenu(
    EditorObjectTarget target,
  ) {
    final menu = presentation(
      target,
      rect: _selection?.globalRect ?? Rect.zero,
    );
    if (menu == null) return null;
    _transient = true;
    value = null;
    return (ticket: ++_menuTicket, menu: menu);
  }

  void endContextMenu(int ticket) {
    if (!_disposed && ticket == _menuTicket) dismiss();
  }

  void dismiss({bool clearSelection = true}) {
    if (_disposed) return;
    _menuTicket++;
    _transient = false;
    _toolbarSuppressed = false;
    menuOpen = false;
    _selection = null;
    _explicitInteraction = null;
    value = null;
    if (clearSelection) contentActions.clearObjectSelection();
  }

  ResolvedEditorObject? _resolve(EditorObjectTarget target) {
    final state = editor();
    return _disposed || state == null
        ? null
        : resolveEditorObject(state, target);
  }

  ComposerObjectSelection? presentation(
    EditorObjectTarget target, {
    Rect rect = Rect.zero,
  }) {
    final object = _resolve(target);
    if (object == null) return null;
    final adapter = ComposerObjectAdapter.forObject(object);
    void beside(bool after) {
      if (_resolve(target) == null) return;
      dismiss();
      placeCaretBesideEditorObject(editor()!, target, after: after);
      resumeEditing();
    }

    ComposerObjectAction command(ComposerObjectCommand command) {
      final (label, icon) = _commandDescription(command, object);
      final enabled =
          command != ComposerObjectCommand.imageSize ||
          (object.image?.origWidth ?? object.image?.width) != null &&
              (object.image?.origHeight ?? object.image?.height) != null;
      return ComposerObjectAction(
        label,
        icon,
        enabled &&
                (command != ComposerObjectCommand.gridMovePrevious ||
                    (target as EditorGridImageTarget).index > 0) &&
                (command != ComposerObjectCommand.gridMoveNext ||
                    (target as EditorGridImageTarget).index <
                        ((object.block as IslandBlock).node as ImageGridNode)
                                .images
                                .length -
                            1)
            ? () => _run(command, target)
            : null,
      );
    }

    final primary = adapter.primary == null ? null : command(adapter.primary!);
    final parents = <(String, EditorObjectTarget)>[
      if (target is EditorImageTarget)
        ('选择所在段落', EditorBlockTarget(target.blockId)),
      if (target is EditorGridImageTarget)
        ('选择图片网格', EditorBlockTarget(target.blockId)),
      for (final frame in object.parentFrames.reversed)
        (
          '选择${composerContainerLabel(frame)}',
          EditorContainerTarget(target.blockId, frame.groupId),
        ),
    ];
    final copyable = object.canCopy;
    return ComposerObjectSelection(
      label: adapter.label,
      contentRects: contentActions.visibleContentRects,
      menuViewport: contentActions.visibleViewportRect,
      interactionPosition: interactionPositionFor(target),
      rect: rect,
      onMenuVisibilityChanged: (visible) => menuOpen = visible,
      onContextMenu: (position) => requestMenu(
        EditorObjectMenuRequest(
          target: target,
          globalPosition: position,
          transient: true,
        ),
      ),
      onMenuRequested: (rect) => requestMenu(
        EditorObjectMenuRequest(
          target: target,
          globalAnchorRect: rect,
          transient: true,
        ),
      ),
      dismiss: dismiss,
      after: () => beside(true),
      primary: primary,
      actions: [
        ComposerObjectAction(
          '在前面输入',
          Icons.vertical_align_top_rounded,
          () => beside(false),
        ),
        ComposerObjectAction(
          '在后面输入',
          Icons.keyboard_return_rounded,
          () => beside(true),
        ),
        ?primary,
        for (final operation in adapter.commands) command(operation),
        for (final parent in parents)
          ComposerObjectAction(
            parent.$1,
            Icons.select_all_rounded,
            () => contentActions.selectObject(parent.$2, showMenu: true),
          ),
        ComposerObjectAction(
          '复制',
          Icons.content_copy_rounded,
          copyable ? () => _copy(target, cut: false) : null,
        ),
        ComposerObjectAction(
          '剪切',
          Icons.content_cut_rounded,
          copyable ? () => _copy(target, cut: true) : null,
        ),
        ComposerObjectAction(
          '删除${object.image == null ? adapter.label : '图片'}',
          Icons.delete_outline_rounded,
          () {
            if (_resolve(target) == null) return;
            dismiss();
            deleteEditorObject(editor()!, target);
          },
          destructive: true,
        ),
      ],
    );
  }

  void _copy(EditorObjectTarget target, {required bool cut}) {
    final object = _resolve(target);
    if (object == null) return;
    final state = editor();
    if (state == null) return;
    final markdown = state.exportMarkdown(fragment: object.fragment);
    if (markdown.isEmpty) return;
    Clipboard.setData(ClipboardData(text: markdown));
    if (cut) {
      dismiss();
      deleteEditorObject(editor()!, target);
    }
  }

  (String, IconData) _commandDescription(
    ComposerObjectCommand command,
    ResolvedEditorObject object,
  ) => switch (command) {
    ComposerObjectCommand.viewImage => ('查看', Icons.open_in_full_rounded),
    ComposerObjectCommand.imageSize => (
      '图片尺寸',
      Icons.photo_size_select_large_rounded,
    ),
    ComposerObjectCommand.imageAlt => ('替代文本', Icons.text_fields_rounded),
    ComposerObjectCommand.joinGrid => ('加入网格', Icons.grid_view_rounded),
    ComposerObjectCommand.moveOutOfGrid => ('移出网格', Icons.grid_off_rounded),
    ComposerObjectCommand.gridMovePrevious => (
      '前移一张',
      Icons.arrow_back_rounded,
    ),
    ComposerObjectCommand.gridMoveNext => ('后移一张', Icons.arrow_forward_rounded),
    ComposerObjectCommand.gridLayout => (
      ((object.block as IslandBlock).node as ImageGridNode).mode ==
              ImageGridMode.grid
          ? '切换为轮播'
          : '切换为网格',
      Icons.view_carousel_outlined,
    ),
    ComposerObjectCommand.splitGrid => ('拆分图片网格', Icons.grid_off_rounded),
    ComposerObjectCommand.openLink => ('打开', Icons.open_in_new_rounded),
    ComposerObjectCommand.removePreview => (
      '移除预览',
      Icons.close_fullscreen_rounded,
    ),
    ComposerObjectCommand.editSource => ('编辑', Icons.edit_outlined),
    ComposerObjectCommand.editText => ('编辑', Icons.edit_outlined),
    ComposerObjectCommand.editContainer => ('编辑标题', Icons.edit_outlined),
    ComposerObjectCommand.unwrapContainer => (
      '移除外框，保留内容',
      Icons.layers_clear_outlined,
    ),
  };

  void _run(ComposerObjectCommand command, EditorObjectTarget target) {
    final object = _resolve(target);
    final state = editor();
    if (object == null || state == null) return;
    switch (command) {
      case ComposerObjectCommand.viewImage:
        final suffix = switch (target) {
          EditorImageTarget(:final offset) => 'img_${target.blockId}_$offset',
          EditorGridImageTarget(:final index) =>
            'grid_${target.blockId}_$index',
          _ => target.blockId,
        };
        viewImage(object.image!, 'rich_composer_$suffix');
      case ComposerObjectCommand.imageSize:
        _editSize(target);
      case ComposerObjectCommand.imageAlt:
        _editAlt(target);
      case ComposerObjectCommand.joinGrid:
        addImageAtomToGrid(
          state,
          target.blockId,
          (target as EditorImageTarget).offset,
        );
      case ComposerObjectCommand.moveOutOfGrid:
        dismiss();
        moveImageOutsideGrid(
          state,
          target.blockId,
          (target as EditorGridImageTarget).index,
        );
      case ComposerObjectCommand.gridMovePrevious:
      case ComposerObjectCommand.gridMoveNext:
        final imageTarget = target as EditorGridImageTarget;
        final next =
            imageTarget.index +
            (command == ComposerObjectCommand.gridMovePrevious ? -1 : 1);
        if (reorderImageInGrid(
          state,
          target.blockId,
          imageTarget.index,
          next,
        )) {
          contentActions.selectObject(
            EditorGridImageTarget(target.blockId, next, imageTarget.src),
          );
        }
      case ComposerObjectCommand.gridLayout:
        final grid = (object.block as IslandBlock).node as ImageGridNode;
        setImageGridMode(
          state,
          target.blockId,
          grid.mode == ImageGridMode.grid
              ? ImageGridMode.carousel
              : ImageGridMode.grid,
        );
      case ComposerObjectCommand.splitGrid:
        removeImageGrid(state, target.blockId);
      case ComposerObjectCommand.openLink:
        final url = composerObjectLink((object.block as IslandBlock).node);
        if (url != null) openLink(url);
      case ComposerObjectCommand.removePreview:
        final url = composerObjectLink((object.block as IslandBlock).node);
        if (url == null) return;
        state.replaceIsland(target.blockId, [
          TextBlock(
            id: state.nextBlockId(),
            content: EditableTextContent(
              text: url,
              marks: [
                MarkSpan(
                  start: 0,
                  end: url.length,
                  kind: MarkKind.link,
                  attr: url,
                ),
              ],
            ),
          ),
        ]);
      case ComposerObjectCommand.editSource:
        editIsland(object.block as IslandBlock);
      case ComposerObjectCommand.editText:
        dismiss();
        state.updateSelection(
          EditorSelection.collapsed(
            EditorPosition(blockId: target.blockId, offset: 0),
          ),
        );
        resumeEditing();
      case ComposerObjectCommand.editContainer:
        editContainer(object.frame!);
      case ComposerObjectCommand.unwrapContainer:
        dismiss();
        unwrapEditorContainer(state, target as EditorContainerTarget);
    }
  }

  Future<void> _editAlt(EditorObjectTarget target) async {
    final before = _resolve(target);
    final state = editor();
    if (before?.image == null || state == null) return;
    final text = await showComposerAltEditor(context(), before!.image!.alt);
    if (_disposed || text == null || !identical(state, editor())) return;
    final current = _resolve(target);
    if (current?.image == null) return;
    _replaceImage(state, target, current!.image!.copyWith(alt: text));
    focusEditor();
  }

  Future<void> _editSize(EditorObjectTarget target) async {
    final before = _resolve(target);
    final state = editor();
    if (before?.image == null || state == null) return;
    final size = await showDialog<int>(
      context: context(),
      builder: (context) => SimpleDialog(
        title: const Text('图片尺寸'),
        children: [
          for (final size in [50, 75, 100])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, size),
              child: SizedBox(
                height: 40,
                child: Row(
                  children: [
                    Expanded(child: Text('$size%')),
                    if ((before!.image!.scale ?? 100).round() == size)
                      const Icon(Icons.check_rounded),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (_disposed || size == null || !identical(state, editor())) return;
    final image = _resolve(target)?.image;
    if (image == null) return;
    final width = image.origWidth ?? image.width;
    final height = image.origHeight ?? image.height;
    if (width == null || height == null) return;
    _replaceImage(
      state,
      target,
      image.copyWith(
        scale: size.toDouble(),
        origWidth: width,
        origHeight: height,
        width: (width * size / 100).floorToDouble(),
        height: (height * size / 100).floorToDouble(),
      ),
    );
    focusEditor();
  }

  void _replaceImage(
    EditorState state,
    EditorObjectTarget target,
    ImageRun image,
  ) {
    switch (target) {
      case EditorImageTarget(:final offset):
        state.replaceAtomAt(target.blockId, offset, image, reselect: true);
      case EditorGridImageTarget(:final index):
        final object = _resolve(target);
        if (object == null) return;
        final node = (object.block as IslandBlock).node as ImageGridNode;
        final images = [...node.images];
        images[index] = image;
        state.updateIslandNode(
          target.blockId,
          ImageGridNode(
            id: node.id,
            images: images,
            columns: node.columns,
            mode: node.mode,
          ),
        );
      default:
        return;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
