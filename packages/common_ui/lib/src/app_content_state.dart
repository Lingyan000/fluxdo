import 'dart:async';

import 'package:flutter/material.dart';

import 'route_motion_hold.dart';
import 'ui_decor.dart';

/// 短请求不闪加载占位；同一份内容刷新时保留原子树和滚动位置。
/// [identity] 必须包含账号、查询等内容身份，变化时不复用上一份内容。
/// 错误/空结果由 [child] 正常呈现，不把请求失败伪装为仍在加载。
class AppLoadingSwitcher extends StatefulWidget {
  const AppLoadingSwitcher({
    super.key,
    required this.loading,
    required this.identity,
    required this.loadingBuilder,
    required this.child,
    this.delay = const Duration(milliseconds: 400),
  });

  final bool loading;
  final Object identity;
  final WidgetBuilder loadingBuilder;
  final Widget child;
  final Duration delay;

  @override
  State<AppLoadingSwitcher> createState() => _AppLoadingSwitcherState();
}

class _AppLoadingSwitcherState extends State<AppLoadingSwitcher> {
  Timer? _timer;
  Widget? _content;
  bool _showLoading = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(AppLoadingSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity ||
        oldWidget.delay != widget.delay) {
      _timer?.cancel();
      _timer = null;
      _content = null;
      _showLoading = false;
    }
    _sync();
  }

  void _sync() {
    if (!widget.loading) {
      _timer?.cancel();
      _timer = null;
      _showLoading = false;
      _content = widget.child;
    } else if (_content == null && _timer == null && !_showLoading) {
      if (widget.delay == Duration.zero) {
        _showLoading = true;
      } else {
        _timer = Timer(widget.delay, () {
          _timer = null;
          if (mounted) setState(() => _showLoading = true);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) =>
      _content ??
      (_showLoading ? widget.loadingBuilder(context) : const SizedBox.expand());

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// 空态的布局由公共组件负责，文字和业务动作由调用方提供。
class AppEmptyState extends StatefulWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.animate = true,
  });
  final Widget icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool animate;

  @override
  State<AppEmptyState> createState() => _AppEmptyStateState();
}

class _AppEmptyStateState extends State<AppEmptyState>
    with SingleTickerProviderStateMixin {
  late final _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final skip =
        !widget.animate ||
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled ||
        PageMotionScope.of(context) ||
        (route?.animation?.isAnimating ?? false) ||
        (route?.secondaryAnimation?.isAnimating ?? false);
    if (skip) {
      _entrance.value = 1;
    } else if (!_started) {
      _entrance.forward();
    }
    _started = true;
  }

  @override
  void didUpdateWidget(AppEmptyState oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.animate) _entrance.value = 1;
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Widget _enter(int order, Widget child) => AnimatedBuilder(
    animation: _entrance,
    child: child,
    builder: (context, child) {
      final t = Interval(
        order / 7,
        1,
        curve: Curves.easeOutCubic,
      ).transform(_entrance.value);
      return IgnorePointer(
        ignoring: t == 0,
        child: ExcludeFocus(
          excluding: t == 0,
          child: Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - t)),
              child: child,
            ),
          ),
        ),
      );
    },
  );

  /// 宿主注入的点缀挂在图标右上角，不改变图标的布局尺寸
  Widget _withCornerBadge(BuildContext context, Widget icon) {
    final badge = UiDecor.maybeOf(context)?.cornerBadge;
    if (badge == null) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(right: -14, top: -10, child: badge(context)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _enter(
                0,
                _withCornerBadge(
                  context,
                  IconTheme(
                    data: IconThemeData(
                      size: 48,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    child: widget.icon,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _enter(
                1,
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (widget.message != null) ...[
                const SizedBox(height: 8),
                _enter(
                  2,
                  Text(
                    widget.message!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              if (widget.action != null) ...[
                const SizedBox(height: 16),
                _enter(3, widget.action!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
