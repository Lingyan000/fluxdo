import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../theme/theme_style.dart';
import '../controllers/topic_jump_history.dart';

/// 返回入口在不同宿主中的呈现风格。
enum TopicReturnButtonStyle {
  /// 窄屏/平板底栏上方的轻量紧凑胶囊，与小号悬浮按钮同高。
  floating,

  /// 宽屏阅读侧栏内的轻量行内按钮，融入楼层读数区域。
  rail,
}

/// 手机浮层和宽屏阅读栏共用的逐级返回入口。
class TopicReturnButton extends StatelessWidget {
  const TopicReturnButton({
    super.key,
    required this.history,
    required this.onReturn,
    required this.onClear,
    this.style = TopicReturnButtonStyle.floating,
  });

  final TopicJumpHistory history;
  final VoidCallback onReturn;
  final VoidCallback onClear;
  final TopicReturnButtonStyle style;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) {
        final target = history.target;
        if (target == null) return const SizedBox.shrink();
        final label = context.l10n.topicDetail_returnToPost(target.postNumber);
        return switch (style) {
          TopicReturnButtonStyle.floating => _FloatingReturnPill(
            label: label,
            returning: history.returning,
            onReturn: onReturn,
            onClear: onClear,
          ),
          TopicReturnButtonStyle.rail => _RailReturnRow(
            label: label,
            returning: history.returning,
            onReturn: onReturn,
            onClear: onClear,
          ),
        };
      },
    );
  }
}

class _FloatingReturnPill extends StatelessWidget {
  const _FloatingReturnPill({
    required this.label,
    required this.returning,
    required this.onReturn,
    required this.onClear,
  });

  final String label;
  final bool returning;
  final VoidCallback onReturn;
  final VoidCallback onClear;

  static const double _height = 40;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = context.shapes.borderRadius(_height / 2);
    final elevation = context.themeStyle.shadows ? 1.5 : 0.0;
    return Material(
      color: scheme.surfaceContainerHigh,
      shape: RoundedSuperellipseBorder(
        borderRadius: radius,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      elevation: elevation,
      shadowColor: Colors.black26,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: _height,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Semantics(
                button: true,
                enabled: !returning,
                child: InkWell(
                  onTap: returning ? null : onReturn,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12, right: 6),
                    child: SizedBox(
                      height: _height,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (returning)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: LoadingSpinner(size: 16),
                            )
                          else
                            Icon(
                              Symbols.undo_rounded,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 16,
              child: VerticalDivider(
                width: 1,
                thickness: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
            Tooltip(
              message: context.l10n.topicDetail_clearReturnHistory,
              child: Semantics(
                button: true,
                label: context.l10n.topicDetail_clearReturnHistory,
                child: InkWell(
                  onTap: onClear,
                  child: SizedBox(
                    width: 34,
                    height: _height,
                    child: Icon(
                      Symbols.close_rounded,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailReturnRow extends StatefulWidget {
  const _RailReturnRow({
    required this.label,
    required this.returning,
    required this.onReturn,
    required this.onClear,
  });

  final String label;
  final bool returning;
  final VoidCallback onReturn;
  final VoidCallback onClear;

  @override
  State<_RailReturnRow> createState() => _RailReturnRowState();
}

class _RailReturnRowState extends State<_RailReturnRow> {
  static const double _height = 32;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = context.shapes.borderRadius(10);
    final foreground = _hovered ? scheme.onSurface : scheme.onSurfaceVariant;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: _hovered
            ? scheme.surfaceContainerHigh.withValues(alpha: 0.72)
            : Colors.transparent,
        shape: RoundedSuperellipseBorder(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: _height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Semantics(
                  button: true,
                  enabled: !widget.returning,
                  child: InkWell(
                    onTap: widget.returning ? null : widget.onReturn,
                    borderRadius: radius,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 6),
                      child: SizedBox(
                        height: _height,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.returning)
                              const SizedBox(
                                width: 15,
                                height: 15,
                                child: LoadingSpinner(size: 15),
                              )
                            else
                              Icon(
                                Symbols.undo_rounded,
                                size: 16,
                                color: foreground,
                              ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                widget.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: foreground,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Tooltip(
                message: context.l10n.topicDetail_clearReturnHistory,
                child: Semantics(
                  button: true,
                  label: context.l10n.topicDetail_clearReturnHistory,
                  child: InkWell(
                    onTap: widget.onClear,
                    borderRadius: radius,
                    child: SizedBox(
                      width: 28,
                      height: _height,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 140),
                        opacity: _hovered ? 1 : 0.55,
                        child: Icon(
                          Symbols.close_rounded,
                          size: 15,
                          color: scheme.onSurfaceVariant,
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
  }
}
