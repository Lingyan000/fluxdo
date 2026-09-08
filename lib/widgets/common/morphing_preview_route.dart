import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';
import 'morphing_dialog_anchor.dart';
import 'morphing_dialog_shell.dart';

/// 所有卡片预览共用转场、快照生命周期和无动画降级。
Future<void> showMorphingPreviewDialog(
  BuildContext context, {
  required WidgetBuilder builder,
  BuildContext? sourceContext,
  Rect? anchorRect,
  Color? anchorColor,
  double anchorRadius = 10,
}) {
  final reducedMotion = MediaQuery.disableAnimationsOf(context);
  final source = sourceContext == null || reducedMotion
      ? null
      : MorphingDialogAnchor.capture(sourceContext);
  final anchor =
      source?.rect ??
      anchorRect ??
      (sourceContext == null
          ? null
          : MorphingDialogAnchor.rectOf(sourceContext));
  try {
    return showAppGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: S.current.common_closePreview,
      // 使用应用统一的明暗主题遮罩和模糊偏好。
      transitionDuration: reducedMotion
          ? Duration.zero
          : anchor == null
          ? const Duration(milliseconds: 200)
          : MorphingDialogShell.enterDuration,
      reverseTransitionDuration: reducedMotion
          ? Duration.zero
          : MorphingDialogShell.exitDuration,
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          child,
      pageBuilder: (context, animation, secondaryAnimation) =>
          MorphingDialogShell(
            animation: animation,
            anchorRect: anchor,
            source: source,
            anchorColor: anchorColor,
            anchorRadius: anchorRadius,
            child: builder(context),
          ),
      // Navigator.pop 的 Future 在退场开始时就完成，图片必须留到路由销毁。
      onDisposed: source?.dispose,
    );
  } catch (_) {
    source?.dispose();
    rethrow;
  }
}
