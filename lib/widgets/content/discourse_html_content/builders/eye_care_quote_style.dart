import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../providers/preferences_provider.dart';

bool isEyeCareBubblesEnabled(BuildContext context) {
  try {
    return ProviderScope.containerOf(context, listen: false)
        .read(preferencesProvider)
        .eyeCareBubbles;
  } catch (_) {
    return false;
  }
}

/// 引用块底色：护眼气泡开启时用半透明白叠在绿/黄卡片上，避免灰色断层。
Color eyeCareAwareQuoteBackground(BuildContext context, ThemeData theme) {
  if (!isEyeCareBubblesEnabled(context)) {
    return theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3);
  }
  return theme.brightness == Brightness.dark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.white.withValues(alpha: 0.44);
}

Color eyeCareAwareQuoteBorder(BuildContext context, ThemeData theme) {
  if (!isEyeCareBubblesEnabled(context)) {
    return theme.colorScheme.outline;
  }
  return theme.brightness == Brightness.dark
      ? const Color(0xFF6B5A34)
      : const Color(0xFF8F6F2A).withValues(alpha: 0.48);
}
