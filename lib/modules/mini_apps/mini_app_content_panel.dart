import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../services/browser_tabs.dart';
import 'mini_app.dart';
import 'mini_app_runner_page.dart';
import 'mini_app_tab_session.dart';
import 'mini_app_url.dart';

/// 帖子内默认打开运行弹窗，主动收起后由公共底栏管理。
class MiniAppContentPanel extends ConsumerWidget {
  const MiniAppContentPanel({
    super.key,
    required this.details,
    required this.launchUri,
    required this.builder,
  });
  final MiniAppDetails? details;
  final Uri launchUri;
  final Widget Function(BuildContext, VoidCallback?, bool) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(browserTabsProvider);
    return ListenableBuilder(
      listenable: tabs,
      builder: (context, _) {
        final data = details;
        final entry = data == null
            ? null
            : MiniAppUrl.embed(
                launchUri.toString(),
                data.app.id,
                AppConstants.baseUrl,
              );
        final resumable = tabs.tabs.whereType<MiniAppTabSession>().any(
          (tab) => !tab.isClosed && tab.entry == entry,
        );
        return builder(
          context,
          data == null
              ? null
              : () => MiniAppRunnerPage.open(
                  context,
                  data,
                  launchUri: launchUri,
                  asPanel: true,
                ),
          resumable,
        );
      },
    );
  }
}
