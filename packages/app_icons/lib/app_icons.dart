/// app_icons —— Flux 全局图标库（Material Symbols Rounded + 自绘）。
///
/// 业务方只 `import 'package:app_icons/app_icons.dart';`。
///
/// 推荐：用 [AppIcons] 中已收录的语义常量；只有当图标尚未收录、又确实属于
/// Material Symbols 字形时，才直接用 `Symbols.xxx_rounded`（同样从这里导出）。
/// 自绘场景用 [AppCustomIcon]/[AppIcon]；规则细节见 src/app_icons.dart 头注释。
library;

export 'package:material_symbols_icons/symbols.dart' show Symbols;

export 'src/app_icon.dart';
export 'src/app_icons.dart';
export 'src/icon_painters.dart';

