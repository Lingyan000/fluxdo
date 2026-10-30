import 'package:common_ui/common_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/preferences_provider.dart';

/// 只订阅玻璃偏好，避免调整档位时重建 MainApp 的其他主题/窗口逻辑。
class AppGlassSettings extends ConsumerWidget {
  const AppGlassSettings({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(
      preferencesProvider.select(
        (p) =>
            GlassSettings(enabled: p.glassEnabled, level: p.glassEffectLevel),
      ),
    );
    return GlassSettingsScope(settings: settings, child: child);
  }
}
