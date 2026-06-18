import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../pages/network_settings_page/widgets/cf_verify_card.dart';
import '../../pages/network_settings_page/widgets/debug_tools_card.dart';
import '../../pages/network_settings_page/widgets/doh_settings_card.dart';
import '../../pages/network_settings_page/widgets/engine_card.dart';
import '../../pages/network_settings_page/widgets/eruda_card.dart';
import '../../pages/network_settings_page/widgets/http_proxy_card.dart';
import '../../pages/network_settings_page/widgets/rate_limit_card.dart';
import '../../pages/network_settings_page/widgets/vpn_auto_toggle_card.dart';
import '../settings_model.dart';

/// 网络设置数据声明
List<SettingsGroup> buildNetworkGroups(BuildContext context) {
  final l10n = context.l10n;
  return [
    // 网络引擎
    SettingsGroup(
      title: l10n.networkSettings_engine,
      icon: Icons.speed_outlined,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'engine',
          title: l10n.networkSettings_engine,
          subtitle: 'rhttp · WebView',
          builder: (context, ref) => const EngineCard(),
        ),
      ],
    ),

    // 网络代理
    SettingsGroup(
      title: l10n.networkSettings_proxy,
      icon: Icons.dns_outlined,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'dohSettings',
          title: 'DNS over HTTPS',
          subtitle: l10n.networkSettings_proxy,
          builder: (context, ref) => const DohSettingsCard(),
        ),
        CustomModel(
          id: 'httpProxy',
          title: l10n.httpProxy_title,
          subtitle: l10n.networkSettings_proxy,
          builder: (context, ref) => const HttpProxyCard(),
        ),
      ],
    ),

    // 辅助功能
    SettingsGroup(
      title: l10n.networkSettings_auxiliary,
      icon: Icons.tune_outlined,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'vpnAutoToggle',
          title: l10n.vpnToggle_title,
          subtitle: l10n.vpnToggle_subtitle,
          builder: (context, ref) => const VpnAutoToggleCard(),
        ),
        CustomModel(
          id: 'cfVerify',
          title: l10n.cf_securityVerifyTitle,
          subtitle: l10n.networkSettings_auxiliary,
          builder: (context, ref) => const CfVerifyCard(),
        ),
      ],
    ),

    // 高级
    SettingsGroup(
      title: l10n.networkSettings_advanced,
      icon: Icons.settings_outlined,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'rateLimit',
          title: l10n.networkSettings_rateLimitTitle,
          subtitle: l10n.networkSettings_advanced,
          builder: (context, ref) => const RateLimitCard(),
        ),
      ],
    ),

    // 调试
    SettingsGroup(
      title: l10n.networkSettings_debug,
      icon: Icons.bug_report_outlined,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'debugTools',
          title: l10n.appLogs_title,
          subtitle: l10n.networkSettings_debug,
          builder: (context, ref) => const DebugToolsCard(),
        ),
        CustomModel(
          id: 'erudaConsole',
          title: 'Eruda 调试控制台',
          subtitle: l10n.networkSettings_debug,
          builder: (context, ref) => const ErudaCard(),
        ),
      ],
    ),
  ];
}
