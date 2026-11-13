import 'package:common_ui/common_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/preferences_provider.dart';
import '../../providers/theme_provider.dart';
import '../../theme/theme_style.dart';

/// 只订阅玻璃偏好与主题的玻璃相关风格，避免调整档位时重建 MainApp 的
/// 其他主题/窗口逻辑。用户偏好决定开关与档位，主题只决定「自动」档位
/// 的质感和外壳是否投影，优先级见 [GlassSettings]。
class AppGlassSettings extends ConsumerWidget {
  const AppGlassSettings({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (enabled, level) = ref.watch(
      preferencesProvider.select((p) => (p.glassEnabled, p.glassEffectLevel)),
    );
    final (glass, shadows) = ref.watch(
      themeProvider.select(
        (t) => (t.effectiveStyle.glass, t.effectiveStyle.shadows),
      ),
    );
    return GlassSettingsScope(
      settings: GlassSettings(
        enabled: enabled,
        level: level,
        autoOptics: glass == GlassStyle.optical,
        shadows: shadows,
      ),
      child: child,
    );
  }
}
