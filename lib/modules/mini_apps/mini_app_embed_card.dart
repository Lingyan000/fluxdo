import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../constants.dart';
import '../../l10n/s.dart';
import 'mini_app.dart';
import 'mini_app_card_surface.dart';
import 'mini_app_content_panel.dart';
import 'mini_app_detail_page.dart';
import 'mini_app_identity.dart';
import 'mini_app_metadata.dart';
import 'mini_app_providers.dart';
import 'mini_app_url.dart';

/// 内容卡片展示真实身份；点击直接运行，信息按钮单独查看详情。
class MiniAppEmbedCard extends ConsumerWidget {
  const MiniAppEmbedCard({super.key, required this.url, this.title});
  final String url;
  final String? title;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uri = MiniAppUrl.parse(url, AppConstants.baseUrl);
    final id = uri == null ? null : MiniAppUrl.appId(uri);
    if (uri == null || id == null) return const SizedBox.shrink();
    final data = ref.watch(miniAppDetailsProvider(id));
    final details = data.value;
    final l = context.l10n;
    final app =
        details?.app ??
        MiniApp(
          id: id,
          name: title?.trim().isNotEmpty == true
              ? title!.trim()
              : l.miniApp_contentLabel,
        );
    final theme = Theme.of(context);
    return MiniAppContentPanel(
      key: ValueKey(uri.toString()),
      details: details,
      launchUri: uri,
      builder: (context, open, resumable) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SegmentedCardItem(
          index: 0,
          count: 1,
          outerRadius: 24,
          child: MiniAppCardSurface(
            app: app,
            child: InkWell(
              key: ValueKey('mini-app-content-open-$id'),
              onTap: open,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: MiniAppIdentity(
                            app: app,
                            subtitle: [
                              l.miniApp_contentLabel,
                              if (app.version.isNotEmpty)
                                l.miniApp_version(app.version),
                            ].join(' · '),
                          ),
                        ),
                        IconButton(
                          tooltip: l.miniApp_info,
                          onPressed: details == null
                              ? null
                              : () => MiniAppDetailPage.showSummary(
                                  context,
                                  details,
                                ),
                          icon: const Icon(Symbols.info_rounded, size: 22),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      details == null
                          ? data.hasError
                                ? l.miniApp_metadataFailed
                                : l.miniApp_metadataLoading
                          : app.description.trim().isEmpty
                          ? l.miniApp_contentHint
                          : app.description.trim(),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (details != null) ...[
                      MiniAppDeveloper(app: app),
                      const SizedBox(height: 8),
                      MiniAppStatistics(app: app, compact: true),
                      const SizedBox(height: 12),
                    ],
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: data.hasError && details == null
                              ? () => ref.invalidate(miniAppDetailsProvider(id))
                              : open,
                          icon: Icon(
                            data.hasError && details == null
                                ? Symbols.refresh_rounded
                                : Symbols.play_arrow_rounded,
                            size: 20,
                          ),
                          label: Text(
                            data.hasError && details == null
                                ? l.miniApp_retry
                                : resumable
                                ? l.miniApp_resumePanel
                                : l.miniApp_open,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
