import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/preferences_provider.dart';
import '../../utils/platform_utils.dart';

/// 按运行平台分流，桌面缩窄窗口也不启用移动端的两段下拉。
final miniAppPullEnabledProvider = Provider<bool>((ref) {
  return !PlatformUtils.isDesktop &&
      ref.watch(preferencesProvider.select((p) => p.miniAppPullEnabled));
});
