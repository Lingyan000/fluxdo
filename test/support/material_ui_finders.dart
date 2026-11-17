import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// Flutter 3.50 的 byTooltip 仍识别旧 Material 类型；
/// 独立 UI 包中 excludeFromSemantics 的提示需按新 Tooltip 类型查找。
Finder findMaterialTooltip(Pattern message) => find.byWidgetPredicate(
  (widget) =>
      widget is Tooltip &&
      message
          .allMatches(widget.message ?? widget.richMessage?.toPlainText() ?? '')
          .isNotEmpty,
  description: 'material_ui Tooltip: $message',
);
