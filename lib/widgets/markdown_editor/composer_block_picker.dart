import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';

import 'composer_anchored_panel.dart';
import 'composer_chrome.dart';
import '../../utils/platform_utils.dart';

class ComposerBlockChoice {
  const ComposerBlockChoice({
    required this.id,
    required this.label,
    required this.icon,
    this.keywords = const [],
    this.description,
    this.glyph,
    this.group = '基础',
  });
  final String id;
  final String label;
  final IconData icon;
  final List<String> keywords;
  final String? description;
  final String? glyph;
  final String group;

  bool matches(String query) {
    final words = query
        .trim()
        .toLowerCase()
        .replaceFirst(RegExp(r'^/'), '')
        .split(RegExp(r'\s+'));
    final haystack = [
      id,
      label,
      ...keywords,
      description ?? '',
    ].join(' ').toLowerCase();
    return words.every(haystack.contains);
  }
}

/// One session owns filtering, keyboard selection, focus and dismissal for all
/// entry points. Slash input may feed its query without moving the editor focus.
class ComposerBlockPickerController extends ChangeNotifier {
  ComposerBlockPickerController({
    required this.choices,
    required this.selectedId,
    String query = '',
    this.autofocusSearch = false,
  }) : search = TextEditingController(text: query) {
    search.addListener(_filter);
    _filter();
  }
  final List<ComposerBlockChoice> choices;
  final String selectedId;
  final bool autofocusSearch;
  final TextEditingController search;
  final searchFocus = FocusNode(debugLabel: 'block-picker-search');
  List<ComposerBlockChoice> _results = [];
  List<ComposerBlockChoice> get results => _results;
  int _active = 0;
  int get activeIndex => _active;
  bool isClosing = false;
  bool restoreFocus = true;
  bool suppressReopen = true;
  VoidCallback? onClosing;
  OverlayEntry? _entry;
  LocalHistoryEntry? _history;
  VoidCallback? _animateClose;
  final _completion = Completer<ComposerBlockChoice?>();
  ComposerBlockChoice? _chosen;
  bool _disposed = false;

  void _filter() {
    _results = choices.where((choice) => choice.matches(search.text)).toList();
    _active = 0;
    notifyListeners();
  }

  void updateQuery(String value) {
    if (_disposed || isClosing || search.text == value) return;
    search.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void activate(int index) {
    if (isClosing || index == _active || index < 0 || index >= results.length) {
      return;
    }
    _active = index;
    notifyListeners();
  }

  bool handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    return handleLogicalKey(event.logicalKey);
  }

  bool handleLogicalKey(LogicalKeyboardKey key) {
    if (isClosing) {
      return const [
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.escape,
      ].contains(key);
    }
    if (search.value.composing.isValid && !search.value.composing.isCollapsed) {
      return false;
    }
    switch (key) {
      case LogicalKeyboardKey.arrowDown:
        if (results.isNotEmpty) activate((_active + 1) % results.length);
        return true;
      case LogicalKeyboardKey.arrowUp:
        if (results.isNotEmpty) {
          activate((_active - 1 + results.length) % results.length);
        }
        return true;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
      case LogicalKeyboardKey.tab:
        if (results.isNotEmpty) choose(results[_active]);
        return true;
      case LogicalKeyboardKey.escape:
        dismiss();
        return true;
    }
    return false;
  }

  Future<ComposerBlockChoice?> show({
    required BuildContext context,
    required Rect Function() anchor,
    required Rect? Function() viewport,
  }) {
    _releaseChrome = ComposerChromeScope.maybeOf(context)?.hold();
    final overlay = Overlay.of(context);
    _history = LocalHistoryEntry(
      impliesAppBarDismissal: false,
      onRemove: () {
        if (_history == null) return;
        _history = null;
        dismiss();
      },
    );
    ModalRoute.of(context)?.addLocalHistoryEntry(_history!);
    final themes = InheritedTheme.capture(from: context, to: overlay.context);
    _entry = OverlayEntry(
      builder: (_) => themes.wrap(
        _BlockPickerPopover(
          controller: this,
          overlay: overlay,
          anchor: anchor,
          viewport: viewport,
        ),
      ),
    );
    overlay.insert(_entry!);
    return _completion.future;
  }

  void refreshAnchor() {
    if (!_disposed && !isClosing) _entry?.markNeedsBuild();
  }

  void choose(ComposerBlockChoice choice) {
    _chosen = choice;
    dismiss();
  }

  void dismiss({
    bool restoreFocus = true,
    bool immediate = false,
    bool suppressReopen = true,
  }) {
    if (_disposed) return;
    if (!isClosing) {
      isClosing = true;
      this.restoreFocus = restoreFocus;
      this.suppressReopen = suppressReopen;
      onClosing?.call();
      notifyListeners();
    }
    if (immediate || _animateClose == null) {
      _finish();
    } else {
      _animateClose!();
    }
  }

  VoidCallback? _releaseChrome;

  void _finish() {
    _releaseChrome?.call();
    _releaseChrome = null;
    final history = _history;
    _history = null;
    history?.remove();
    final entry = _entry;
    _entry = null;
    entry?.remove();
    entry?.dispose();
    if (!_completion.isCompleted) _completion.complete(_chosen);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finish();
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }
}

class _BlockPickerPopover extends StatefulWidget {
  const _BlockPickerPopover({
    required this.controller,
    required this.overlay,
    required this.anchor,
    required this.viewport,
  });
  final ComposerBlockPickerController controller;
  final OverlayState overlay;
  final Rect Function() anchor;
  final Rect? Function() viewport;
  @override
  State<_BlockPickerPopover> createState() => _BlockPickerPopoverState();
}

class _BlockPickerPopoverState extends State<_BlockPickerPopover>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 160),
  );
  bool _started = false;
  bool _closing = false;
  bool _reduced = false;
  @override
  void initState() {
    super.initState();
    widget.controller._animateClose = _close;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (!_started) {
      _started = true;
      if (_reduced) {
        _animation.value = 1;
      } else {
        _animation.forward();
      }
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      if (!_reduced) await _animation.reverse().orCancel;
      if (mounted) widget.controller._finish();
    } on TickerCanceled {
      /* Owner removed the editor while closing. */
    }
  }

  @override
  void dispose() {
    widget.controller._animateClose = null;
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = widget.overlay.context.findRenderObject()! as RenderBox;
    Rect local(Rect value) => Rect.fromPoints(
      box.globalToLocal(value.topLeft),
      box.globalToLocal(value.bottomRight),
    );
    final viewport = widget.viewport();
    return ComposerAnchoredSurface(
      anchor: local(widget.anchor()),
      viewport: viewport == null ? null : local(viewport),
      animation: _animation,
      reduceMotion: _reduced,
      width: 336,
      maxHeight: 440,
      fitBesideAnchor: PlatformUtils.isDesktop,
      child: TapRegion(
        groupId: widget.controller,
        onTapOutside: (_) => widget.controller.dismiss(restoreFocus: false),
        child: TextFieldTapRegion(
          child: ComposerBlockPicker(controller: widget.controller),
        ),
      ),
    );
  }
}

/// A searchable grouped list, shared unchanged by `/`, add and change-type.
class ComposerBlockPicker extends StatefulWidget {
  const ComposerBlockPicker({super.key, required this.controller});
  final ComposerBlockPickerController controller;
  static const formatIds = {'paragraph', 'h1', 'h2', 'h3', 'h4', 'ul', 'ol'};
  @override
  State<ComposerBlockPicker> createState() => _ComposerBlockPickerState();
}

class _ComposerBlockPickerState extends State<ComposerBlockPicker> {
  final _scroll = ScrollController();
  final _rows = <String, GlobalKey>{};
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.controller.isClosing ||
          widget.controller.results.isEmpty) {
        return;
      }
      final id = widget.controller.results[widget.controller.activeIndex].id;
      final object = _rows[id]?.currentContext?.findRenderObject();
      if (object == null || !object.attached || !_scroll.hasClients) return;
      final viewport = RenderAbstractViewport.maybeOf(object);
      if (viewport == null) return;
      final position = _scroll.position;
      final top = viewport.getOffsetToReveal(object, 0).offset;
      final bottom = viewport.getOffsetToReveal(object, 1).offset;
      // Move only the list, and only far enough to reveal the hidden edge.
      // One-sided keepVisibleAtEnd cannot reveal an item above the viewport.
      final target = top < position.pixels
          ? top
          : bottom > position.pixels
          ? bottom
          : position.pixels;
      final offset = target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (offset != position.pixels) position.jumpTo(offset);
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final colors = Theme.of(context).colorScheme;
    final entries = controller.results;
    final searching = controller.search.text.isNotEmpty;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown): _PickerKeyIntent(
          LogicalKeyboardKey.arrowDown,
        ),
        SingleActivator(LogicalKeyboardKey.arrowUp): _PickerKeyIntent(
          LogicalKeyboardKey.arrowUp,
        ),
        SingleActivator(LogicalKeyboardKey.enter): _PickerKeyIntent(
          LogicalKeyboardKey.enter,
        ),
        SingleActivator(LogicalKeyboardKey.numpadEnter): _PickerKeyIntent(
          LogicalKeyboardKey.enter,
        ),
        SingleActivator(LogicalKeyboardKey.tab): _PickerKeyIntent(
          LogicalKeyboardKey.tab,
        ),
        SingleActivator(LogicalKeyboardKey.escape): _PickerKeyIntent(
          LogicalKeyboardKey.escape,
        ),
      },
      child: Actions(
        actions: {_PickerKeyIntent: _PickerKeyAction(controller)},
        child: IgnorePointer(
          ignoring: controller.isClosing,
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              key: const ValueKey('composer-block-picker'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  key: const ValueKey('composer-block-search-header'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(
                          Icons.search_rounded,
                          key: ValueKey('composer-block-search-icon'),
                          size: 20,
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('composer-block-search'),
                          controller: controller.search,
                          focusNode: controller.searchFocus,
                          autofocus: controller.autofocusSearch,
                          textAlignVertical: TextAlignVertical.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                          decoration: const InputDecoration(
                            hintText: '搜索块类型…',
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('composer-block-search-close'),
                        tooltip: '关闭',
                        style: IconButton.styleFrom(
                          minimumSize: const Size.square(48),
                          maximumSize: const Size.square(48),
                          visualDensity: VisualDensity.standard,
                        ),
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => controller.dismiss(),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  color: colors.outlineVariant.withValues(alpha: .5),
                ),
                Flexible(
                  fit: FlexFit.loose,
                  child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      key: const ValueKey('composer-block-results'),
                      padding: const EdgeInsets.all(6),
                      child: entries.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(
                                '没有匹配的块类型\n试试“图片”“标题”或“表格”',
                                key: const ValueKey(
                                  'composer-block-empty-results',
                                ),
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0; i < entries.length; i++) ...[
                                  if (!searching &&
                                      (i == 0 ||
                                          entries[i - 1].group !=
                                              entries[i].group))
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        10,
                                        10,
                                        10,
                                        4,
                                      ),
                                      child: Text(
                                        entries[i].group,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              color: colors.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  _row(context, entries[i], i),
                                ],
                              ],
                            ),
                    ),
                  ),
                ),
                if (PlatformUtils.isDesktop || constraints.maxHeight >= 320)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                    child: Text(
                      switch (Theme.of(context).platform) {
                        TargetPlatform.android ||
                        TargetPlatform.iOS ||
                        TargetPlatform.fuchsia => '输入名称查找，点选插入',
                        _ => '↑↓ 选择   Enter 确认   Esc 关闭',
                      },
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, ComposerBlockChoice item, int index) {
    final colors = Theme.of(context).colorScheme;
    final active = index == widget.controller.activeIndex;
    return KeyedSubtree(
      key: _rows.putIfAbsent(item.id, GlobalKey.new),
      child: MouseRegion(
        onHover: (_) => widget.controller.activate(index),
        child: Semantics(
          selected: active,
          child: TextButton(
            key: ValueKey('composer-block-choice-${item.id}'),
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              minimumSize: const Size(0, 48),
              visualDensity: VisualDensity.standard,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              backgroundColor: active
                  ? colors.primary.withValues(alpha: .10)
                  : Colors.transparent,
              foregroundColor: colors.onSurface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
              ),
            ),
            onPressed: () => widget.controller.choose(item),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: item.glyph == null
                      ? Icon(item.icon, size: 20)
                      : Text(
                          item.glyph!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.label),
                      if (item.description != null)
                        Text(
                          item.description!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                if (item.id == widget.controller.selectedId)
                  Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PickerKeyIntent extends Intent {
  const _PickerKeyIntent(this.key);
  final LogicalKeyboardKey key;
}

class _PickerKeyAction extends Action<_PickerKeyIntent> {
  _PickerKeyAction(this.controller);
  final ComposerBlockPickerController controller;
  @override
  bool isEnabled(_PickerKeyIntent intent) =>
      !controller.search.value.composing.isValid ||
      controller.search.value.composing.isCollapsed;
  @override
  Object? invoke(_PickerKeyIntent intent) {
    controller.handleLogicalKey(intent.key);
    return null;
  }
}
