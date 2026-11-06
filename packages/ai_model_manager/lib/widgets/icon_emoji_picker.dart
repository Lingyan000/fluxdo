import 'package:flutter/material.dart';

import '../l10n/ai_l10n.dart';
import 'preset_icon.dart';

/// 选 icon 或 emoji
///
/// 输出：单个字符串 `iconRaw`，约定 emoji 文本（首 rune > 0x80）走 emoji，
/// 否则视为 Material icon name（在 PresetIcon 里查表）。
class IconEmojiPicker extends StatefulWidget {
  const IconEmojiPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<IconEmojiPicker> createState() => _IconEmojiPickerState();
}

class _IconEmojiPickerState extends State<IconEmojiPicker>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final TextEditingController _emojiController;

  static const List<String> _suggestedEmoji = [
    '🎨',
    '🖼️',
    '✏️',
    '📝',
    '🎯',
    '💡',
    '⭐',
    '🔥',
    '✨',
    '🌈',
    '🎬',
    '📷',
    '🗺️',
    '❤️',
    '🌟',
    '🎭',
    '🌸',
    '🌿',
    '🪐',
    '🎮',
    '🍿',
    '☕',
    '🛹',
    '🧸',
    '📚',
    '🧠',
    '👀',
    '🤖',
    '🦄',
    '🍀',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // 初始 tab：当前值是 emoji 就停在 Emoji tab
    if (_isEmoji(widget.value)) _tabController.index = 1;
    _emojiController = TextEditingController(
      text: _isEmoji(widget.value) ? widget.value : '',
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _emojiController.dispose();
    super.dispose();
  }

  static bool _isEmoji(String s) {
    if (s.isEmpty) return false;
    return s.runes.first >= 0x80;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 当前预览
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: ShapeDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: PresetIcon(iconRaw: widget.value, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.value,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TabBar(
          controller: _tabController,
          isScrollable: false,
          tabs: [
            Tab(text: AiL10n.current.quickPromptsIconTab),
            Tab(text: AiL10n.current.quickPromptsEmojiTab),
          ],
        ),
        SizedBox(
          height: 200,
          child: TabBarView(
            controller: _tabController,
            children: [
              // 图标 tab
              GridView.count(
                padding: const EdgeInsets.all(8),
                crossAxisCount: 6,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                children: [
                  for (final name in kBuiltInIconNames)
                    _IconCell(
                      name: name,
                      selected: widget.value == name,
                      onTap: () => widget.onChanged(name),
                    ),
                ],
              ),
              // emoji tab
              SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _emojiController,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 22),
                      decoration: InputDecoration(
                        hintText: AiL10n.current.quickPromptsEmojiInputHint,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (value) {
                        // 只取第一个字符（防止用户输入多个 emoji 串）
                        if (value.isEmpty) return;
                        final first = String.fromCharCodes([value.runes.first]);
                        if (first.runes.first >= 0x80) {
                          widget.onChanged(first);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final e in _suggestedEmoji)
                          _EmojiCell(
                            emoji: e,
                            selected: widget.value == e,
                            onTap: () {
                              widget.onChanged(e);
                              _emojiController.text = e;
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _IconCell extends StatelessWidget {
  const _IconCell({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHigh,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(6)),
      child: InkWell(
        onTap: onTap,
        customBorder:
            RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(6)),
        child: Center(
          child: PresetIcon(
            iconRaw: name,
            size: 22,
            color: selected
                ? theme.colorScheme.onPrimaryContainer
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _EmojiCell extends StatelessWidget {
  const _EmojiCell({
    required this.emoji,
    required this.selected,
    required this.onTap,
  });

  final String emoji;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      customBorder:
          RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(6)),
      child: Container(
        width: 36,
        height: 36,
        decoration: ShapeDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHigh,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        alignment: Alignment.center,
        child: Text(emoji, style: const TextStyle(fontSize: 20)),
      ),
    );
  }
}
