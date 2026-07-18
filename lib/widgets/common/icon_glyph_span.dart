import 'package:flutter/material.dart';

/// 图标字形直接进 TextSpan:消灭 Text.rich 里"图标当子 widget"的
/// WidgetSpan 占位布局(占位符逼 RenderParagraph 走占位子节点布局,
/// 每个占位一棵额外渲染子树 —— 标签行/标题行清 WidgetSpan 均已验证
/// 收益)。
///
/// Icon(size:s) 本质就是画一个 s px 的图标字体字形,同字形同字号像素
/// 一致;原 Padding(right:gap) 用单字形 span 的 letterSpacing 精确复刻
/// (尾部 +gap)。fontVariations 按 IconTheme 原样复刻(可变字体的
/// 粗细/填充,漏了笔画粗细会变)。与 WidgetSpan(middle 对齐)的残余
/// 差异 = 基线 vs 行中线的 ≤1px 垂直微差。
TextSpan iconGlyphSpan(
  BuildContext context,
  IconData icon, {
  required double size,
  required Color color,
  double gap = 0,
}) {
  final iconTheme = IconTheme.of(context);
  return TextSpan(
    text: String.fromCharCode(icon.codePoint),
    style: TextStyle(
      fontFamily: icon.fontFamily,
      package: icon.fontPackage,
      fontSize: size,
      color: color,
      letterSpacing: gap,
      height: 1.0,
      fontVariations: <FontVariation>[
        if (iconTheme.fill != null) FontVariation('FILL', iconTheme.fill!),
        if (iconTheme.weight != null) FontVariation('wght', iconTheme.weight!),
        if (iconTheme.grade != null) FontVariation('GRAD', iconTheme.grade!),
        if (iconTheme.opticalSize != null)
          FontVariation('opsz', iconTheme.opticalSize!),
      ],
    ),
  );
}
