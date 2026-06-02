import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:flutter/material.dart';

import 'src/cookie_engine_extension.dart';

void main() {
  runApp(const FluxdoCookieDevToolsExtension());
}

/// Fluxdo Cookie 引擎 v0.4.0 DevTools Extension 入口。
///
/// 通过 `extension/devtools/config.yaml` 注册到 Flutter DevTools；
/// 主 app 端 service extensions 见
/// `lib/services/network/cookie/cookie_devtools_extension.dart`。
class FluxdoCookieDevToolsExtension extends StatelessWidget {
  const FluxdoCookieDevToolsExtension({super.key});

  @override
  Widget build(BuildContext context) {
    return const DevToolsExtension(
      child: CookieEngineExtension(),
    );
  }
}
