import 'package:common_ui/common_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';
import '../../pages/user_profile_page.dart';
import '../../services/auth_session.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/platform_utils.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../../widgets/common/error_view.dart';
import 'mini_app.dart';
import 'mini_app_icon.dart';
import 'mini_app_card_surface.dart';
import 'mini_app_providers.dart';
import 'mini_app_runner_page.dart';
import 'mini_app_window_session.dart';

class MiniAppDetailPage extends ConsumerWidget {
  const MiniAppDetailPage({super.key, required this.appId, this.launchUri});
  final String appId;
  final Uri? launchUri;

  static Future<void> open(BuildContext context, String id, {Uri? launchUri}) =>
      Navigator.of(context).push<void>(
        InteractionPageRoute(
          builder: (_) => MiniAppDetailPage(appId: id, launchUri: launchUri),
        ),
      );

  /// 详情沿用公共弹层，运行使用正常页面，返回后保留广场位置。
  static Future<bool> show(BuildContext context, String id) async {
    final generation = AuthSession().generation;
    final footer = Consumer(
      builder: (context, ref, _) {
        final details = ref.watch(miniAppDetailsProvider(id)).value;
        return _OpenButton(
          onPressed: details == null
              ? null
              : () => Navigator.pop(context, details),
        );
      },
    );
    Widget bodyBuilder(BuildContext context, ScrollController? controller) =>
        Consumer(
          builder: (context, ref, _) {
            return ref
                .watch(miniAppDetailsProvider(id))
                .when(
                  loading: () => const SizedBox(
                    height: 160,
                    child: Center(child: LoadingSpinner()),
                  ),
                  error: (e, _) => ErrorView(
                    error: e,
                    onRetry: () => ref.invalidate(miniAppDetailsProvider(id)),
                  ),
                  data: (details) => ListView(
                    controller: controller,
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(20),
                    children: [MiniAppDetailsContent(details: details)],
                  ),
                );
          },
        );
    final selected = PlatformUtils.isDesktop
        ? await _showDesktopInfo<MiniAppDetails>(
            context,
            body: bodyBuilder(context, null),
            footer: footer,
          )
        : await AppBottomSheet.show<MiniAppDetails>(
            context: context,
            title: context.l10n.miniApp_info,
            showCloseButton: true,
            footer: footer,
            contentPadding: EdgeInsets.zero,
            builder: (context) => bodyBuilder(context, null),
          );
    if (selected == null ||
        !context.mounted ||
        !AuthSession().isValid(generation)) {
      return false;
    }
    await MiniAppRunnerPage.open(context, selected);
    if (context.mounted) {
      ProviderScope.containerOf(context).invalidate(miniAppDetailsProvider(id));
    }
    return true;
  }

  static Future<void> showSummary(
    BuildContext context,
    MiniAppDetails details, {
    bool blur = true,
    ValueChanged<double>? onBlurSigmaChanged,
    ValueListenable<bool>? blurReady,
    bool filterBackdrop = true,
  }) async {
    if (PlatformUtils.isDesktop) {
      await _showDesktopInfo<void>(
        context,
        blur: blur,
        onBlurSigmaChanged: onBlurSigmaChanged,
        blurReady: blurReady,
        filterBackdrop: filterBackdrop,
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: MiniAppDetailsContent(details: details),
        ),
      );
      return;
    }
    await AppBottomSheet.show<void>(
      context: context,
      blur: blur,
      onBlurSigmaChanged: onBlurSigmaChanged,
      blurReady: blurReady,
      filterBackdrop: filterBackdrop,
      title: context.l10n.miniApp_info,
      builder: (_) =>
          SingleChildScrollView(child: MiniAppDetailsContent(details: details)),
    );
  }

  /// 桌面详情使用公共居中弹窗，内容滚动与固定操作区各自占位。
  static Future<T?> _showDesktopInfo<T>(
    BuildContext context, {
    required Widget body,
    Widget? footer,
    bool blur = true,
    ValueChanged<double>? onBlurSigmaChanged,
    ValueListenable<bool>? blurReady,
    bool filterBackdrop = true,
  }) => showAppDialog<T>(
    context: context,
    blur: blur,
    onBlurSigmaChanged: onBlurSigmaChanged,
    blurReady: blurReady,
    filterBackdrop: filterBackdrop,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 600,
          maxHeight: (MediaQuery.sizeOf(context).height - 96).clamp(
            160.0,
            640.0,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.miniApp_info,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.common_close,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Symbols.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(child: body),
            ?footer,
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(miniAppDetailsProvider(appId));
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.miniApp_info)),
      bottomNavigationBar: SafeArea(
        child: _OpenButton(
          onPressed: data.value == null
              ? null
              : () async {
                  await MiniAppRunnerPage.open(
                    context,
                    data.value!,
                    launchUri: launchUri,
                  );
                  if (context.mounted) {
                    ref.invalidate(miniAppDetailsProvider(appId));
                  }
                },
        ),
      ),
      body: data.when(
        loading: () => const Center(child: LoadingSpinner()),
        error: (e, st) => ErrorView(
          error: e,
          stackTrace: st,
          onRetry: () => ref.invalidate(miniAppDetailsProvider(appId)),
        ),
        data: (details) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [MiniAppDetailsContent(details: details)],
            ),
          ),
        ),
      ),
    );
  }
}

class _OpenButton extends StatelessWidget {
  const _OpenButton({required this.onPressed});
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
    child: FilledButton.icon(
      onPressed: onPressed,
      icon: const Icon(Symbols.play_arrow_rounded),
      label: Text(context.l10n.miniApp_open),
    ),
  );
}

/// 深链、广场详情与运行页共用身份卡、统计和介绍，保持一致的信息层次。
class MiniAppDetailsContent extends StatelessWidget {
  const MiniAppDetailsContent({super.key, required this.details});
  final MiniAppDetails details;
  @override
  Widget build(BuildContext context) {
    final app = details.app;
    final l = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedCardItem(
          index: 0,
          count: 1,
          outerRadius: 28,
          child: MiniAppCardSurface(
            app: app,
            prominent: true,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      MiniAppIcon(app, size: 64),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(app.name, style: theme.textTheme.titleLarge),
                            const SizedBox(height: 6),
                            Text(
                              l.miniApp_version(app.version),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 16,
                    runSpacing: 10,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Symbols.star_rounded,
                            size: 20,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              miniAppRating(context, app),
                              style: theme.textTheme.labelLarge,
                            ),
                          ),
                        ],
                      ),
                      if (app.usageCount > 0)
                        Text(
                          l.miniApp_usage(app.usageCount),
                          style: theme.textTheme.labelLarge,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (app.description.trim().isNotEmpty)
          _section(context, l.miniApp_description, app.description),
        const SizedBox(height: 24),
        SegmentedCardGroup(
          children: [
            if (app.authorUsername.isNotEmpty)
              ListTile(
                leading: const Icon(Symbols.person_rounded),
                title: Text(app.author),
                subtitle: Text(l.miniApp_developer),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => MiniAppWindowSession.current != null
                    ? MiniAppWindowSession.current!.community(
                        '/u/${Uri.encodeComponent(app.authorUsername)}',
                      )
                    : Navigator.of(context).push(
                        InteractionPageRoute(
                          builder: (_) =>
                              UserProfilePage(username: app.authorUsername),
                        ),
                      ),
              ),
            if (app.discussionTopicId case final int topicId)
              ListTile(
                leading: const Icon(Symbols.forum_rounded),
                title: Text(l.miniApp_discussion),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => MiniAppWindowSession.current != null
                    ? MiniAppWindowSession.current!.community('/t/$topicId')
                    : Navigator.of(context).push(
                        InteractionPageRoute(
                          builder: (_) => TopicDetailPage(topicId: topicId),
                        ),
                      ),
              ),
          ],
        ),
        if (app.releaseNotes.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: SegmentedCardItem(
              index: 0,
              count: 1,
              child: ExpansionTile(
                title: Text(
                  l.miniApp_releaseNotes,
                  style: theme.textTheme.titleSmall,
                ),
                subtitle: Text(l.miniApp_version(app.version)),
                shape: const Border(),
                collapsedShape: const Border(),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    app.releaseNotes,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _section(BuildContext context, String title, String text) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 10),
        SelectableText(text, style: Theme.of(context).textTheme.bodyMedium),
      ],
    ),
  );
}

String miniAppRating(BuildContext context, MiniApp app) => app.ratingCount == 0
    ? context.l10n.miniApp_noRating
    : context.l10n.miniApp_score(
        app.rating.toStringAsFixed(1),
        app.ratingCount,
      );
