import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../l10n/s.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../../app_logs_page.dart';

/// 调试工具卡片
///
/// 网络/CF 验证日志已合并进统一日志（JSONL），这里只提供
/// 跳转到应用日志页并预设对应类型筛选的入口。
class DebugToolsCard extends StatefulWidget {
  const DebugToolsCard({super.key});

  @override
  State<DebugToolsCard> createState() => _DebugToolsCardState();
}

class _DebugToolsCardState extends State<DebugToolsCard> {
  bool _isDeveloperMode = false;

  @override
  void initState() {
    super.initState();
    _loadDeveloperMode();
  }

  Future<void> _loadDeveloperMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isDeveloperMode = prefs.getBool('developer_mode') ?? false;
      });
    }
  }

  void _openLogs(LogTypeFilter type) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AppLogsPage(initialType: type)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SegmentedCardGroup(
      children: [
        ListTile(
          leading: const Icon(Symbols.article_rounded),
          title: Text(context.l10n.appLogs_title),
          trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
          onTap: () => _openLogs(LogTypeFilter.all),
        ),
        ListTile(
          leading: const Icon(Symbols.dns_rounded),
          title: Text(context.l10n.debugTools_networkLogs),
          subtitle: Text(context.l10n.debugTools_networkLogsDesc),
          trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
          onTap: () => _openLogs(LogTypeFilter.network),
        ),
        // CF 验证日志（开发者模式）
        if (_isDeveloperMode)
          ListTile(
            leading: const Icon(Symbols.shield_rounded),
            title: Text(context.l10n.debugTools_cfLogs),
            subtitle: Text(context.l10n.debugTools_cfLogsDesc),
            trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
            onTap: () => _openLogs(LogTypeFilter.cfChallenge),
          ),
      ],
    );
  }
}
