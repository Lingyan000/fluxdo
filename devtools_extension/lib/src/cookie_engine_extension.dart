import 'package:flutter/material.dart';

import 'tabs/actions_tab.dart';
import 'tabs/events_tab.dart';
import 'tabs/overview_tab.dart';

/// Cookie 引擎 DevTools 主面板,3 tab:
/// - Overview: jar / WV cookie 双视图 + Priming 状态
/// - Events: 实时 SweepEvent 流
/// - Actions: 手动 sweep / Nuclear Reset / Invalidate Priming
class CookieEngineExtension extends StatelessWidget {
  const CookieEngineExtension({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.cookie_outlined), text: 'Overview'),
            Tab(icon: Icon(Icons.timeline), text: 'Events'),
            Tab(icon: Icon(Icons.build_outlined), text: 'Actions'),
          ],
        ),
        body: const TabBarView(
          children: [
            OverviewTab(),
            EventsTab(),
            ActionsTab(),
          ],
        ),
      ),
    );
  }
}
