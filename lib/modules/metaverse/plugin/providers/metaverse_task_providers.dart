part of 'metaverse_plugin_providers.dart';

bool _usesTaskControl(InstalledMetaversePlugin plugin) =>
    plugin.manifest.tasks.isNotEmpty ||
    plugin.manifest.capabilities.notifications ||
    plugin.manifest.requiredFeatures.contains('navigationBadge');

final metaverseTaskStoreProvider = FutureProvider(
  (ref) async => MetaverseTaskStore(
    await ref.watch(metaversePluginDirectoryProvider.future),
  ),
);

Future<void> _dismissTaskNotifications(List<int> ids) async {
  for (final id in ids) {
    try {
      await LocalNotificationService().cancelNotification(id);
    } catch (error) {
      debugPrint('取消插件通知失败：$error');
    }
  }
}

final metaverseTaskDriverProvider = Provider<MetaverseTaskDriver?>((ref) {
  final state = ref.watch(currentUserProvider);
  final plugins = ref.watch(metaversePluginsProvider);
  final control = ref.watch(metaverseTaskStoreProvider).value;
  if (control == null || (state.isLoading && state.value == null)) return null;
  final account = state.value;
  final driver = MetaverseTaskDriver(ref, control, account?.id);
  final dismissed = control.sync(
    accountId: account?.id,
    username: account?.username,
    plugins: plugins,
  );
  unawaited(_dismissTaskNotifications(dismissed));
  driver.start();
  ref.onDispose(driver.close);
  return driver;
});

class MetaverseTaskDriver with WidgetsBindingObserver {
  MetaverseTaskDriver(this.ref, this.control, this.account);
  final Ref ref;
  final MetaverseTaskStore control;
  final int? account;
  final badges = ValueNotifier<Map<String, int>>({});
  Timer? _timer;
  bool _open = true, _busy = false;
  bool get _foreground {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return lifecycle == null ||
        lifecycle == AppLifecycleState.resumed ||
        lifecycle == AppLifecycleState.inactive;
  }

  bool get _desktop =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      changed().catchError((Object error) => debugPrint('插件调度未就绪：$error')),
    );
    LocalNotificationService().pluginTap.addListener(_queueTap);
    _queueTap();
  }

  void _queueTap() {
    if (account == null || LocalNotificationService().pluginTap.value == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_open || !_foreground) return;
      final taps = LocalNotificationService().pluginTap, id = taps.value;
      final context = navigatorKey.currentState?.overlay?.context;
      if (id == null || context == null || !context.mounted) return;
      taps.value = null;
      final target = control.notificationTarget(id);
      if (target == null ||
          target['account'] != ref.read(currentUserProvider).value?.id) {
        return;
      }
      final plugin = ref
          .read(metaversePluginsProvider.notifier)
          .byId(target['plugin']);
      if (plugin == null ||
          !plugin.enabled ||
          plugin.suspendedReason != null ||
          plugin.manifest.page(target['page']) == null) {
        return;
      }
      unawaited(
        MetaversePluginPage.open(
          context,
          plugin.id,
          target['page'],
          params: (target['params'] as Map).cast<String, Object?>(),
        ),
      );
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> changed() async {
    if (!_open) return;
    final snapshot = control.snapshot();
    if ((snapshot['events'] as List?)?.isNotEmpty == true) {
      for (final event in control.takeEvents()) {
        LogWriter.instance.write(event, inheritPluginContext: false);
      }
    }
    final jobs = ((snapshot['jobs'] as Map?)?.values ?? []).where(
      (job) => job['account'] == account,
    );
    final wake = jobs.any((job) => job['background'] == true);
    final eligible = jobs.where(
      (job) => _foreground || (_desktop && job['background'] == true),
    );
    _timer?.cancel();
    if (account != null && !_busy && eligible.isNotEmpty) {
      final next = eligible
          .map((job) => MetaverseTaskStore.dueAt(job, background: !_foreground))
          .reduce((a, b) => a < b ? a : b);
      _timer = Timer(
        Duration(milliseconds: (next - control.now).clamp(1000, 86400000)),
        _tick,
      );
    }
    if (account != null) badges.value = control.badges(account!);
    await BackgroundNotificationService().setPluginWake(wake);
  }

  Future<void> _tick() async {
    if (!_open || _busy || account == null) return;
    _busy = true;
    try {
      final hosts = ref.read(metaversePluginHostsProvider);
      final background = !_foreground;
      final id = await dispatchMetaverseTask(
        control: control,
        background: background,
        available: (owner) =>
            _open &&
            (_foreground || (_desktop && background)) &&
            ref.read(currentUserProvider).value?.id == owner,
        installed: () => ref.read(metaversePluginsProvider),
        newHost: (p) => hosts.newHost(p, worker: true),
      );
      if (_open && id != null) hosts.notifyTaskUpdated(id);
    } catch (error) {
      debugPrint('插件任务调度失败：$error');
    } finally {
      _busy = false;
      if (_open) await changed();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_open) return;
    unawaited(
      changed().catchError((Object error) => debugPrint('插件调度未就绪：$error')),
    );
    if (state == AppLifecycleState.resumed) _queueTap();
  }

  Future<void> stopTask(String plugin, String id) async {
    if (account == null) return;
    control.cancel(account!, plugin, id);
    await changed();
  }

  Future<void> mute(String plugin) async {
    if (account == null) return;
    control.allowNotifications(account!, plugin, false);
    final ids = control.notificationIds(plugin, account: account);
    control.forgetNotifications(plugin, account: account);
    await _dismissTaskNotifications(ids);
    await changed();
  }

  void close() {
    _open = false;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    LocalNotificationService().pluginTap.removeListener(_queueTap);
    badges.dispose();
  }
}
