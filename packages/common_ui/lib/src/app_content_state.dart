import 'dart:async';

import 'package:flutter/material.dart';

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
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });
  final Widget icon;
  final String title;
  final String? message;
  final Widget? action;

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
              IconTheme(
                data: IconThemeData(
                  size: 48,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                child: icon,
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}
