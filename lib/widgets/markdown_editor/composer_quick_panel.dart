import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';
import 'composer_tool_action.dart';

/// 快捷键专用搜索入口，和底栏的工具展开共用动作注册表。
Future<bool> showComposerQuickPanel(
  BuildContext context,
  List<ComposerToolAction> actions,
) async {
  List<ComposerToolAction> flatten(List<ComposerToolAction> items) => [
    for (final item in items)
      if (item.children.isEmpty) item else ...flatten(item.children),
  ];
  final picked = await showAppDialog<ComposerToolAction>(
    context: context,
    blur: false,
    builder: (context) => Dialog(
      alignment: const Alignment(0, -.55),
      clipBehavior: Clip.antiAlias,
      child: _ComposerQuickPanel(actions: flatten(actions)),
    ),
  );
  if (!context.mounted || picked == null || !picked.enabled) return false;
  picked.run();
  return true;
}

class _ComposerQuickPanel extends StatefulWidget {
  const _ComposerQuickPanel({required this.actions});
  final List<ComposerToolAction> actions;
  @override
  State<_ComposerQuickPanel> createState() => _ComposerQuickPanelState();
}

class _ComposerQuickPanelState extends State<_ComposerQuickPanel> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _searchFocus = FocusNode();
  final _panelFocus = FocusNode();
  int _selected = 0;
  static const _rowHeight = 48.0;

  String _shortcutLabel(String value) => value
      .trim()
      .replaceAll('(', '')
      .replaceAll(')', '')
      .replaceAll('⌘', 'Cmd+')
      .replaceAll('⇧', 'Shift+')
      .replaceAll('⌥', 'Alt+')
      .replaceAll('⌃', 'Ctrl+');

  @override
  void initState() {
    super.initState();
    _selected = _matches.indexWhere((action) => action.enabled);
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _panelFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  int? _score(ComposerToolAction action, String query) {
    if (query.isEmpty) return 0;
    final label = action.label.toLowerCase();
    final text = '$label ${action.searchText.toLowerCase()}';
    var score = label == query
        ? -100
        : label.startsWith(query)
        ? -50
        : 0;
    for (final token in query.split(RegExp(r'\s+'))) {
      final index = text.indexOf(token);
      if (index >= 0) {
        score += index;
        continue;
      }
      var cursor = 0;
      for (final rune in token.runes) {
        final char = String.fromCharCode(rune);
        final at = text.indexOf(char, cursor);
        if (at < 0) return null;
        score += 100 + at - cursor;
        cursor = at + char.length;
      }
    }
    return score;
  }

  List<ComposerToolAction> get _matches {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.actions;
    final ranked = <(int, int, ComposerToolAction)>[];
    for (var i = 0; i < widget.actions.length; i++) {
      final score = _score(widget.actions[i], query);
      if (score != null) ranked.add((score, i, widget.actions[i]));
    }
    ranked.sort(
      (a, b) => a.$1 == b.$1 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1),
    );
    return ranked.map((entry) => entry.$3).toList();
  }

  void _revealSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _selected < 0) return;
      final top = _selected * _rowHeight;
      final bottom = top + _rowHeight;
      final p = _scroll.position;
      final target = top < p.pixels
          ? top
          : bottom > p.pixels + p.viewportDimension
          ? bottom - p.viewportDimension
          : p.pixels;
      _scroll.jumpTo(target.clamp(p.minScrollExtent, p.maxScrollExtent));
    });
  }

  void _move(int delta) {
    final matches = _matches;
    if (!matches.any((action) => action.enabled)) return;
    var next = _selected;
    do {
      next = (next + delta) % matches.length;
    } while (!matches[next].enabled);
    setState(() => _selected = next);
    _revealSelected();
  }

  void _choose([int? index]) {
    final matches = _matches;
    final selected = index ?? _selected;
    if (selected < 0 ||
        selected >= matches.length ||
        !matches[selected].enabled) {
      return;
    }
    Navigator.of(context).pop(matches[selected]);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // 输入法候选确认不能被当作工具操作。
    if (_search.value.composing.isValid &&
        !_search.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if ((keys.isControlPressed || keys.isMetaPressed) &&
        event.logicalKey == LogicalKeyboardKey.keyF) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (keys.isMetaPressed || keys.isAltPressed || keys.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        (keys.isControlPressed && key == LogicalKeyboardKey.keyN)) {
      _move(1);
    } else if (key == LogicalKeyboardKey.arrowUp ||
        (keys.isControlPressed && key == LogicalKeyboardKey.keyP)) {
      _move(-1);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _choose();
    } else if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final matches = _matches;
      return Focus(
        focusNode: _panelFocus,
        onKeyEvent: _onKey,
        child: SizedBox(
          key: const ValueKey('composer-quick-panel'),
          width: 520,
          height: math.min(480, bounds.maxHeight),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 20, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        S.current.composer_quickPanel,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: S.current.common_cancel,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  key: const ValueKey('composer-tools-search'),
                  controller: _search,
                  focusNode: _searchFocus,
                  autofocus: true,
                  textAlignVertical: TextAlignVertical.center,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _choose(),
                  decoration: InputDecoration(
                    hintText: S.current.composer_searchTools,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 48,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                  onChanged: (_) {
                    setState(
                      () => _selected = _matches.indexWhere((a) => a.enabled),
                    );
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  },
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ClipRect(
                  child: matches.isEmpty
                      ? Center(
                          child: Text(
                            S.current.composer_noTools,
                            style: theme.textTheme.bodyMedium,
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          itemCount: matches.length,
                          itemExtent: _rowHeight,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          itemBuilder: (context, index) {
                            final action = matches[index];
                            return MouseRegion(
                              onEnter: (_) {
                                if (action.enabled) {
                                  setState(() => _selected = index);
                                }
                              },
                              child: Material(
                                color: Colors.transparent,
                                clipBehavior: Clip.antiAlias,
                                borderRadius: BorderRadius.circular(8),
                                child: ListTile(
                                  key: ObjectKey(action),
                                  dense: true,
                                  enabled: action.enabled,
                                  selected: index == _selected,
                                  selectedTileColor: colors.primaryContainer
                                      .withValues(alpha: .4),
                                  leading: IconTheme(
                                    data: IconThemeData(
                                      size: 20,
                                      color: action.enabled
                                          ? colors.onSurfaceVariant
                                          : colors.outline,
                                    ),
                                    child: action.icon,
                                  ),
                                  title: Text(
                                    action.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (action.active)
                                        const Padding(
                                          padding: EdgeInsets.only(right: 6),
                                          child: Icon(Icons.check, size: 16),
                                        ),
                                      if (action.shortcut != null)
                                        Text(
                                          _shortcutLabel(action.shortcut!),
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                color: colors.onSurfaceVariant,
                                              ),
                                        ),
                                    ],
                                  ),
                                  onTap: () => _choose(index),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              if (bounds.maxHeight > 260)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '↑↓ ${S.current.composer_toolsNavigate}    Enter ${S.current.composer_toolsApply}    Esc ${S.current.common_cancel}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
