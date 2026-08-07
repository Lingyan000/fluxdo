import 'package:flutter/material.dart';

/// 图标内联进段落:WidgetSpan 行中线对齐的单字形 Text。
///
/// Material Symbols 是零下降部字体(ascent=1em、descent=0,字形整体
/// 坐在基线上方),字形直接与正文同基线排布时光学中心比小字号正文高
/// ≈0.17em(12px 图标 ≈2px,元信息行肉眼可见"图标飘"),所以必须走
/// placeholder 行中线对齐 —— 与自绘卡(topic_card_layout)同构。
///
/// [textStyle] 是同行正文的样式:middle 对齐的"行中线"用占位符处生效
/// 的 span 样式度量计算((ascent-descent)/2,已实测),不是段落默认
/// 样式。根 TextSpan 带同款样式时可省(继承即正确);根无样式时**必须**
/// 传,否则中线按 DefaultTextStyle(通常 bodyMedium 14px)的度量算,
/// 对 11px 小字行图标会整体上飘 ≈1px。
///
/// 子节点用裸 Text 画字形(同字形同字号与 Icon 像素一致,少一层
/// Semantics 壳);原 Padding(right:gap) 用字形 letterSpacing 精确复刻
/// (尾部 +gap)。fontVariations 按 IconTheme 原样复刻(可变字体的
/// 粗细/填充,漏了笔画粗细会变)。
InlineSpan iconGlyphSpan(
  BuildContext context,
  IconData icon, {
  required double size,
  required Color color,
  double gap = 0,
  TextStyle? textStyle,
}) {
  final iconTheme = IconTheme.of(context);
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    style: textStyle,
    child: Text(
      String.fromCharCode(icon.codePoint),
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
    ),
  );
}
