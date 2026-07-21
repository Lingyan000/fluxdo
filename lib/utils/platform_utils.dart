import 'dart:io';

import 'package:flutter/foundation.dart';

/// 平台工具类 — 统一平台检测逻辑
class PlatformUtils {
  PlatformUtils._();

  @visibleForTesting
  static bool? debugDesktopOverride;

  /// 是否运行在桌面操作系统（macOS / Windows / Linux）
  static bool get isDesktop =>
      debugDesktopOverride ??
      (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux));

  /// 是否运行在 Windows（原生分享面板体验差,链接分享需特殊处理）
  static bool get isWindows => !kIsWeb && Platform.isWindows;

  /// 是否运行在移动操作系统（Android / iOS）
  static bool get isMobile =>
      debugDesktopOverride == null
      ? (!kIsWeb && (Platform.isAndroid || Platform.isIOS))
      : !debugDesktopOverride!;
}
