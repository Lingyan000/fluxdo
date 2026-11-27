import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/background/background_notification_service.dart';
import '../../../services/log/log_writer.dart';
import '../plugin/metaverse_plugin_installer.dart';
import '../plugin/metaverse_plugin_store.dart';
import '../plugin/providers/metaverse_plugin_providers.dart';
import 'metaverse_market_provider.dart';
import 'metaverse_plugin_updater.dart';
import 'metaverse_update_store.dart';

final metaverseUpdateStoreProvider = FutureProvider(
  (ref) async => MetaverseUpdateStore(
    await ref.watch(metaversePluginDirectoryProvider.future),
  ),
);

final metaverseUpdatesProvider =
    AsyncNotifierProvider<MetaverseUpdatesController, MetaverseUpdateState>(
      MetaverseUpdatesController.new,
    );

final metaverseAttentionProvider = Provider<Set<String>>((ref) {
  final reports = ref.watch(metaverseUpdatesProvider).value?.reports ?? const {};
  return {for (final plugin in ref.watch(metaversePluginsProvider))
    if (plugin.suspendedReason != null || (reports[plugin.id]?['status'] == 'review' &&
        reports[plugin.id]?['source'] == plugin.source)) plugin.id};
});

class MetaverseUpdatesController extends AsyncNotifier<MetaverseUpdateState> {
  @override
  Future<MetaverseUpdateState> build() async =>
      (await ref.watch(metaverseUpdateStoreProvider.future)).snapshot();
  Future<void> reload() async {
    final store = await ref.read(metaverseUpdateStoreProvider.future);
    if (ref.mounted) state = AsyncData(store.snapshot());
  }

  Future<void> setFrequency(MetaverseUpdateFrequency value) async {
    (await ref.read(metaverseUpdateStoreProvider.future)).setFrequency(value);
    await reload();
  }
  Future<void> setPreview(bool value) async {
    (await ref.read(metaverseUpdateStoreProvider.future)).setPreview(value);
    await reload();
  }

  Future<void> setAllowed(InstalledMetaversePlugin plugin, bool allowed) async {
    (await ref.read(metaverseUpdateStoreProvider.future))
        .setAllowed(plugin, allowed);
    await reload();
  }
}

MetaversePluginUpdater createMetaverseUpdater(
  ProviderContainer container,
  MetaverseUpdateStore store,
) => MetaversePluginUpdater(
  store: store,
  installed: () => container.read(metaversePluginsProvider),
  sourceEnabled: (source) => container
      .read(metaverseMarketProvider)
      .sources
      .any((s) => s.id == source && s.enabled),
  refresh: () async {
    await container.read(metaverseMarketProvider.notifier).refresh(force: true);
    return container.read(metaverseMarketProvider);
  },
  download: (entry) =>
      container.read(metaverseMarketProvider.notifier).downloadBundle(entry),
);

final metaverseUpdateDriverProvider = Provider<MetaverseUpdateDriver?>((ref) {
  final store = ref.watch(metaverseUpdateStoreProvider).value;
  if (store == null) return null;
  final driver = MetaverseUpdateDriver(ref, store);
  ref.listen(metaverseUpdatesProvider, (_, _) => driver.schedule());
  ref.listen(metaversePluginsProvider, (_, _) => driver.schedule());
  ref.listen(metaverseMarketProvider, (_, _) => driver.schedule());
  driver.start();
  ref.onDispose(driver.close);
  return driver;
});

class MetaverseUpdateDriver with WidgetsBindingObserver {
  MetaverseUpdateDriver(this.ref, this.store);
  final Ref ref;
  final MetaverseUpdateStore store;
  Timer? _timer;
  bool _open = true, _busy = false, _queued = false;
  Completer<void>? _finished;
  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.inactive;
  bool get _desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  late final updater = MetaversePluginUpdater(
    store: store,
    installed: () => ref.read(metaversePluginsProvider),
    sourceEnabled: (source) => ref
        .read(metaverseMarketProvider)
        .sources
        .any((s) => s.id == source && s.enabled),
    refresh: () async {
      await ref.read(metaverseMarketProvider.notifier).refresh(force: true);
      return ref.read(metaverseMarketProvider);
    },
    download: (entry) =>
        ref.read(metaverseMarketProvider.notifier).downloadBundle(entry),
  );

  void start() {
    WidgetsBinding.instance.addObserver(this);
    schedule();
  }

  void schedule() {
    if (!_open || _queued) return;
    _queued = true;
    scheduleMicrotask(() async {
      _queued = false;
      if (!_open) return;
      try {
        await _schedule();
      } catch (error) {
        debugPrint('插件更新计划未就绪：$error');
      }
    });
  }

  Future<void> _schedule() async {
    if (!_open) return;
    for (final event in store.takeEvents()) {
      LogWriter.instance.write(event, inheritPluginContext: false);
    }
    final plugins = ref.read(metaversePluginsProvider);
    if (!_busy) store.reconcile(plugins);
    final state = store.snapshot();
    final enabled = state.enabled && plugins.any(updater.eligible);
    _timer?.cancel();
    if (enabled && !_busy && (_foreground || _desktop)) {
      final pending = state.reports.values.any((r) => r['status'] == 'ready');
      final delay = pending
          ? const Duration(seconds: 30).inMilliseconds
          : (state.nextCheck - store.now).clamp(2000, 86400000);
      _timer = Timer(
        Duration(milliseconds: state.checking ? 30000 : delay),
        () => unawaited(check()),
      );
    }
    await BackgroundNotificationService().setPluginUpdateWake(enabled);
  }

  bool _idle(String id) {
    if (ref.read(metaversePluginHostsProvider.exists) &&
        ref.read(metaversePluginHostsProvider).isInUse(id)) {
      return false;
    }
    final plugin = ref.read(metaversePluginsProvider.notifier).byId(id);
    if (plugin == null) return false;
    if (plugin.manifest.tasks.isEmpty) return true;
    final control = ref.read(metaverseTaskStoreProvider).value;
    if (control == null) return false;
    final jobs = (control.snapshot()['jobs'] as Map?)?.values ?? const [];
    return !jobs.any(
      (job) =>
          job['plugin'] == id && (job['leaseUntil'] as int? ?? 0) > control.now,
    );
  }

  Future<void> check({bool force = false}) async {
    if (_busy) return _finished?.future;
    if (!_open || (!_foreground && !_desktop)) return;
    final finished = _finished = Completer<void>();
    _busy = true;
    _timer?.cancel();
    try {
      final checking = updater.check(force: force);
      await ref.read(metaverseUpdatesProvider.notifier).reload();
      await checking;
      if (!_open) return;
      await updater.apply(
        installer: MetaversePluginInstaller(
          network: ref.read(metaversePluginNetworkProvider),
          reservedHosts: ref.read(metaversePluginStoreProvider).reservedHosts,
        ),
        available: () => _open && _foreground,
        idle: _idle,
        install: (package, expected, guard) => ref
            .read(metaversePluginsProvider.notifier)
            .installAutomatic(package, expected, guard),
      );
    } catch (error) {
      debugPrint('插件自动更新未完成：$error');
    } finally {
      _busy = false;
      try {
        if (_open) { await ref.read(metaverseUpdatesProvider.notifier).reload(); schedule(); }
      } finally { finished.complete(); }
    }
  }

  Future<void> applyNow(String id) async {
    if (_busy || !_foreground || !_open) return;
    final hosts = ref.read(metaversePluginHostsProvider);
    if (!hosts.closeForUpdate(id)) throw StateError('update_busy');
    _busy = true;
    final finished = _finished = Completer<void>();
    try {
      await updater.apply(installer: MetaversePluginInstaller(
        network: ref.read(metaversePluginNetworkProvider), reservedHosts: ref.read(metaversePluginStoreProvider).reservedHosts),
        available: () => _open && _foreground, idle: (candidate) => candidate == id && _idle(id),
        install: ref.read(metaversePluginsProvider.notifier).installAutomatic);
    } finally {
      _busy = false;
      try {
        if (_open) {
          await ref.read(metaversePluginsProvider.notifier).reloadHost(id);
          await ref.read(metaverseUpdatesProvider.notifier).reload();
          schedule();
        }
      } finally { finished.complete(); }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(check());
    } else {
      schedule();
    }
  }

  void close() {
    _open = false;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
