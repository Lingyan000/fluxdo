import 'package:common_ui/common_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';
import '../../services/auth_session.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/platform_utils.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/skeleton.dart';
import 'mini_app.dart';
import 'mini_app_icon.dart';
import 'mini_app_metadata.dart';
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
    final selected = PlatformUtils.isDesktop
        ? await _showDesktopInfo<MiniAppDetails>(
            context,
            body: _MiniAppDetailsBody(appId: id),
            footer: footer,
          )
        : await AppBottomSheet.show<MiniAppDetails>(
            context: context,
            title: context.l10n.miniApp_info,
            showCloseButton: true,
            footer: footer,
            contentPadding: EdgeInsets.zero,
            builder: (_) => _MiniAppDetailsBody(appId: id),
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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: _MiniAppDetailsBody(appId: appId, shrinkWrap: false),
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

class _MiniAppDetailsBody extends ConsumerWidget {
  const _MiniAppDetailsBody({required this.appId, this.shrinkWrap = true});
  final String appId;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(miniAppDetailsProvider(appId));
    return ListView(
      shrinkWrap: shrinkWrap,
      padding: const EdgeInsets.all(24),
      children: [
        AppLoadingSwitcher(
          identity: (appId, AuthSession().generation),
          loading: data.isLoading,
          delay: Duration.zero,
          loadingBuilder: (_) => const MiniAppDetailsSkeleton(),
          child: data.when(
            loading: () => const MiniAppDetailsSkeleton(),
            error: (error, stackTrace) => ErrorView(
              error: error,
              stackTrace: stackTrace,
              onRetry: () => ref.invalidate(miniAppDetailsProvider(appId)),
            ),
            data: (details) => MiniAppDetailsContent(details: details),
          ),
        ),
      ],
    );
  }
}

/// 信息直接排在弹框表面，深链页面与运行页沿用同一份内容。
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
        Row(
          children: [
            MiniAppIcon(app, size: 64),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(app.name, style: theme.textTheme.titleLarge),
                  if (app.version.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      l.miniApp_version(app.version),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (app.author.isNotEmpty || app.authorUsername.isNotEmpty) ...[
          const SizedBox(height: 20),
          MiniAppDeveloper(app: app, showRole: true),
        ],
        const Divider(height: 32),
        MiniAppStatistics(app: app),
        if (app.description.trim().isNotEmpty)
          _section(context, l.miniApp_description, app.description),
        if (app.discussionTopicId case final int topicId) ...[
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
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
        if (app.releaseNotes.trim().isNotEmpty) ...[
          const SizedBox(height: 16),
          ExpansionTile(
            title: Text(
              l.miniApp_releaseNotes,
              style: theme.textTheme.titleSmall,
            ),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            shape: const Border(),
            collapsedShape: const Border(),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                app.releaseNotes,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ],
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

class MiniAppDetailsSkeleton extends StatelessWidget {
  const MiniAppDetailsSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Skeleton(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SkeletonCircle(size: 64),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(height: 24),
                  SizedBox(height: 10),
                  FractionallySizedBox(
                    widthFactor: .4,
                    child: SkeletonBox(height: 16),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 24),
        Row(
          children: [
            SkeletonCircle(size: 40),
            SizedBox(width: 8),
            SkeletonBox(width: 100, height: 20),
          ],
        ),
        SizedBox(height: 32),
        FractionallySizedBox(widthFactor: .6, child: SkeletonBox(height: 18)),
        SizedBox(height: 10),
        FractionallySizedBox(widthFactor: .8, child: SkeletonBox(height: 16)),
        SizedBox(height: 28),
        SkeletonBox(width: 80, height: 18),
        SizedBox(height: 12),
        SkeletonBox(height: 16),
        SizedBox(height: 8),
        SkeletonBox(height: 16),
        SizedBox(height: 8),
        FractionallySizedBox(widthFactor: .7, child: SkeletonBox(height: 16)),
      ],
    ),
  );
}
