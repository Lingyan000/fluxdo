import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../services/toast_service.dart';
import '../../../utils/time_utils.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../../../utils/dialog_utils.dart';
import '../plugin/providers/metaverse_plugin_providers.dart';
import 'metaverse_market_page.dart';
import 'metaverse_market_provider.dart';
import 'metaverse_update_provider.dart';
import 'metaverse_update_store.dart';

String metaverseUpdateFrequencyLabel(
  BuildContext context,
  MetaverseUpdateFrequency frequency,
) => switch (frequency) {
  MetaverseUpdateFrequency.disabled => context.l10n.metaverse_updateOff,
  MetaverseUpdateFrequency.sixHours => context.l10n.metaverse_updateSixHours,
  MetaverseUpdateFrequency.daily => context.l10n.metaverse_updateDaily,
  MetaverseUpdateFrequency.weekly => context.l10n.metaverse_updateWeekly,
};

class MetaverseUpdatePage extends ConsumerStatefulWidget {
  const MetaverseUpdatePage({super.key});
  @override
  ConsumerState<MetaverseUpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends ConsumerState<MetaverseUpdatePage> {
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    // 系统唤醒准备的候选可能比当前引擎的市场缓存新，打开管理页时同步详情入口。
    Future<void>.microtask(() {
      if (mounted) {
        return ref.read(metaverseMarketProvider.notifier).refresh(force: true);
      }
    });
  }

  Future<void> _run(Future<void> Function() run) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await run();
    } catch (_) {
      if (mounted) ToastService.showError(context.l10n.metaverse_updateFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _frequency(MetaverseUpdateFrequency current) async {
    final value = await AppBottomSheet.show<MetaverseUpdateFrequency>(
      context: context,
      title: context.l10n.metaverse_updateFrequency,
      showDragHandle: true,
      builder: (context) => SingleChildScrollView(
        child: SegmentedCardGroup(
          children: [
            for (final frequency in MetaverseUpdateFrequency.values)
              ListTile(
                title: Text(metaverseUpdateFrequencyLabel(context, frequency)),
                selected: frequency == current,
                trailing: frequency == current
                    ? const Icon(Symbols.check_rounded)
                    : null,
                onTap: () => Navigator.of(context).pop(frequency),
              ),
          ],
        ),
      ),
    );
    if (value != null && mounted) {
      await _run(
        () => ref.read(metaverseUpdatesProvider.notifier).setFrequency(value),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final updates = ref.watch(metaverseUpdatesProvider);
    final driver = ref.watch(metaverseUpdateDriverProvider);
    final plugins = ref.watch(metaversePluginsProvider);
    final market = ref.watch(metaverseMarketProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.metaverse_autoUpdates)),
      body: updates.when(
        loading: () => const Center(child: LoadingSpinner()),
        error: (_, _) => AppEmptyState(
          icon: const Icon(Symbols.error_outline_rounded),
          title: l.metaverse_updateFailed,
          action: TextButton(
            onPressed: () => ref.invalidate(metaverseUpdatesProvider),
            child: Text(l.common_retry),
          ),
        ),
        data: (state) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedCardGroup(
              children: [
                M3eSwitchListTile(title: Text(l.metaverse_updatePreview), subtitle: Text(l.metaverse_updatePreviewNote),
                  value: state.preview, onChanged: _busy ? null : (value) => _run(() => ref.read(metaverseUpdatesProvider.notifier).setPreview(value))),
                ListTile(
                  leading: const Icon(Symbols.schedule_rounded),
                  title: Text(l.metaverse_updateFrequency),
                  subtitle: Text(
                    metaverseUpdateFrequencyLabel(context, state.frequency),
                  ),
                  trailing: const Icon(Symbols.chevron_right_rounded),
                  onTap: _busy ? null : () => _frequency(state.frequency),
                ),
                ListTile(
                  title: Text(l.metaverse_updateLastCheck),
                  subtitle: Text(
                    state.lastCheck == null
                        ? l.metaverse_updateNotChecked
                        : TimeUtils.formatDetailTime(
                            DateTime.fromMillisecondsSinceEpoch(
                              state.lastCheck!,
                            ),
                          ),
                  ),
                ),
                if (state.enabled && state.nextCheck > 0)
                  ListTile(
                    title: Text(l.metaverse_updateNextCheck),
                    subtitle: Text(
                      TimeUtils.formatDetailTime(
                        DateTime.fromMillisecondsSinceEpoch(state.nextCheck),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              l.metaverse_autoUpdateNote,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _busy || state.checking || driver == null
                  ? null
                  : () => _run(() => driver.check(force: true)),
              icon: _busy || state.checking
                  ? const SizedBox.square(
                      dimension: 18,
                      child: LoadingSpinner(),
                    )
                  : const Icon(Symbols.refresh_rounded),
              label: Text(
                state.checking
                    ? l.metaverse_updateChecking
                    : l.metaverse_updateCheckNow,
              ),
            ),
            if (state.failed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l.metaverse_updateFailed),
              ),
            const SizedBox(height: 24),
            Text(
              l.metaverse_updateSelectNote,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SegmentedCardGroup(
              children: [
                for (final plugin in plugins)
                  Builder(
                    builder: (context) {
                      final supported = market.sources.any(
                        (s) => s.id == plugin.source && s.enabled,
                      );
                      final report = state.reports[plugin.id];
                      final status = switch (report?['status']) {
                        'ready' => l.metaverse_updateReady,
                        'review' => l.metaverse_updateReview,
                        'incompatible' => l.metaverse_marketRequiresUpdate,
                        'updated' => l.metaverse_updateApplied,
                        'failed' => l.metaverse_updateFailed,
                        'withdrawn' => l.metaverse_updateWithdrawn,
                        'rejected' => l.metaverse_updateRejected,
                        _ => l.metaverse_updateCurrent,
                      };
                      final entry = market.entries
                          .where(
                            (e) =>
                                e.id == plugin.id &&
                                e.source.id == plugin.source &&
                                e.newerThan(plugin.manifest.version) && (e.channel == 'stable' || state.preview),
                          )
                          .firstOrNull;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          M3eSwitchListTile(
                            title: Text(plugin.manifest.localizedName(context.l10n.localeName)),
                            subtitle: Text(
                              !supported
                                  ? l.metaverse_updateNoSource
                                  : !state.allows(plugin)
                                  ? l.metaverse_updateExcluded
                                  : report == null
                                  ? plugin.manifest.version
                                  : '${report['version']} · $status',
                            ),
                            value: supported && state.allows(plugin),
                            onChanged: _busy || !supported
                                ? null
                                : (value) => _run(
                                    () => ref
                                        .read(metaverseUpdatesProvider.notifier)
                                        .setAllowed(plugin, value),
                                  ),
                          ),
                          if (report?['installedWithdrawn'] == true) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(l.metaverse_updateWithdrawn)),
                          if ((report?['reason'] as String? ?? '').isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(report!['reason'] as String)),
                          if (entry != null && report != null)
                            Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: TextButton(
                                onPressed: () => Navigator.of(context).push(
                                  InteractionPageRoute(
                                    builder: (_) =>
                                        MetaverseMarketDetailPage(entry: entry),
                                  ),
                                ),
                                child: Text(l.metaverse_updateView),
                              ),
                            ),
                          if (report?['status'] == 'ready' && state.enabled && state.allows(plugin))
                            Align(alignment: AlignmentDirectional.centerEnd, child: TextButton(
                              onPressed: _busy || driver == null ? null : () async {
                                final yes = await showAppDialog<bool>(context: context, builder: (ctx) => AlertDialog(
                                  title: Text(l.metaverse_updateClose), content: Text(l.metaverse_updateCloseNote), actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.common_cancel)),
                                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.common_confirm)),
                                  ]));
                                if (yes == true && mounted) await _run(() => driver.applyNow(plugin.id));
                              },
                              child: Text(l.metaverse_updateClose),
                            )),
                        ],
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              l.metaverse_updateBackgroundNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
