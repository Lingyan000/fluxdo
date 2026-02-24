import 'package:flutter/material.dart';
import 'scan_boundary.dart';

/// 构建 Discourse details 折叠块
/// 
/// 处理 `<details><summary>标题</summary>内容</details>` 结构
Widget buildDetails({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required Widget Function(String html, TextStyle? textStyle) htmlBuilder,
}) {
  // 提取 summary 文本
  final summaryElements = element.getElementsByTagName('summary');
  String summaryText = '详情'; // 默认标题
  if (summaryElements.isNotEmpty) {
    // 取 summary 的纯文本
    summaryText = summaryElements.first.text.trim();
    if (summaryText.isEmpty) {
      summaryText = '详情';
    }
  }

  // 提取 details 内容（除 summary 外的部分）
  String contentHtml = element.innerHtml as String;
  // 移除 summary 标签及其内容
  contentHtml = contentHtml.replaceFirst(
    RegExp(r'<summary[^>]*>.*?</summary>', caseSensitive: false, dotAll: true),
    '',
  );
  contentHtml = contentHtml.trim();

  // 检查是否有 open 属性（默认展开）
  final isOpenByDefault = element.attributes.containsKey('open');

  return ScanBoundary(
    child: _DetailsWidget(
      theme: theme,
      summaryText: summaryText,
      contentHtml: contentHtml,
      htmlBuilder: htmlBuilder,
      initiallyExpanded: isOpenByDefault,
    ),
  );
}

/// 可折叠的 Details Widget
class _DetailsWidget extends StatefulWidget {
  final ThemeData theme;
  final String summaryText;
  final String contentHtml;
  final Widget Function(String html, TextStyle? textStyle) htmlBuilder;
  final bool initiallyExpanded;

  const _DetailsWidget({
    required this.theme,
    required this.summaryText,
    required this.contentHtml,
    required this.htmlBuilder,
    required this.initiallyExpanded,
  });

  @override
  State<_DetailsWidget> createState() => _DetailsWidgetState();
}

class _DetailsWidgetState extends State<_DetailsWidget>
    with SingleTickerProviderStateMixin {
  late bool _isExpanded;
  late AnimationController _controller;
  late Animation<double> _iconTurns;
  late Animation<double> _heightFactor;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _iconTurns = Tween<double>(begin: 0.0, end: 0.25).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _heightFactor = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
    if (_isExpanded) {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final isDark = theme.brightness == Brightness.dark;
    
    // 使用柔和的边框颜色
    final borderColor = isDark
        ? theme.colorScheme.outlineVariant.withValues(alpha: 0.5)
        : theme.colorScheme.outline.withValues(alpha: 0.3);
    
    // 标题背景色
    final headerBgColor = isDark
        ? theme.colorScheme.surfaceContainerHigh
        : theme.colorScheme.surfaceContainerLow;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          // 可点击的标题栏
          Material(
            color: headerBgColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
            child: InkWell(
              onTap: _handleTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    RotationTransition(
                      turns: _iconTurns,
                      child: Icon(
                        Icons.arrow_right_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        widget.summaryText,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 可折叠的内容
          ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return Align(
                  alignment: Alignment.topLeft,
                  heightFactor: _heightFactor.value,
                  child: child,
                );
              },
              child: widget.contentHtml.isNotEmpty
                  ? Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        border: Border(
                          top: BorderSide(color: borderColor, width: 1),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: widget.htmlBuilder(
                          widget.contentHtml,
                          theme.textTheme.bodyMedium?.copyWith(
                            height: 1.5,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
      ),
    );
  }
}
