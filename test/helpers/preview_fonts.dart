import 'dart:io';

import 'package:flutter/services.dart';

/// 截图导出类测试用的中文字体。
///
/// MiSans 不再随安装包内置，测试改用本机可用的中文字体，以 [family]
/// （默认沿用 `MiSans`）注册，既有测试的 `fontFamily: 'MiSans'` 不必改。
/// 查找顺序：环境变量 `PREVIEW_CJK_FONT` → macOS 系统字体 → 常见 Linux
/// Noto CJK 路径。找不到时返回 false，调用方照常导出（中文显示为方块）。
Future<bool> loadPreviewCjkFont({String family = 'MiSans'}) async {
  final candidates = <String?>[
    Platform.environment['PREVIEW_CJK_FONT'],
    '/System/Library/Fonts/Hiragino Sans GB.ttc',
    '/System/Library/Fonts/STHeiti Medium.ttc',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc',
  ];
  for (final path in candidates.nonNulls) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    await (FontLoader(
      family,
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    return true;
  }
  return false;
}
