import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/user.dart';
import '../../../services/log/log_writer.dart';
import '../../../providers/core_providers.dart';
import '../../../providers/theme_provider.dart';
import '../../../services/network/cookie/cookie_jar_service.dart';
import '../../../services/network/cookie/csrf_token_service.dart';
import '../../../services/network/discourse_dio.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../plugin/providers/metaverse_plugin_providers.dart';
import 'metaverse_task_dispatcher.dart';
import 'metaverse_task_store.dart';

class _WakeAccount extends CurrentUserNotifier {
  _WakeAccount(this.user);
  final User user;
  @override
  User build() => user;
}

Future<bool> runMetaverseSystemWake() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final bootstrap = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  try {
    final control = await bootstrap.read(metaverseTaskStoreProvider.future);
    final snapshot = control.snapshot();
    final owner = (snapshot['account'] as Map?)?['id'];
    final jobs = (snapshot['jobs'] as Map?)?.values ?? [];
    if (owner is! int ||
        !jobs.any(
          (job) =>
              job['account'] == owner &&
              job['background'] == true &&
              MetaverseTaskStore.dueAt(job, background: true) <= control.now,
        )) {
      return true;
    }
    await CookieJarService().initialize();
    await CsrfTokenService().init();
    await NetworkSettingsService.instance.initialize(prefs);
    final dio = DiscourseDio.create(
      enableCfChallenge: false,
      enableRetry: false,
      callTimeout: const Duration(seconds: 5),
    );
    final User user;
    try {
      final response = await dio.get(
        '/session/current.json',
        options: Options(
          extra: const {
            'isSilent': true,
            'skipAuthCheck': true,
            'skipCsrf': true,
          },
        ),
      );
      final raw = response.data is Map ? response.data['current_user'] : null;
      if (raw is! Map<String, dynamic> || raw['id'] != owner) return true;
      user = User.fromJson(raw);
    } finally {
      dio.close(force: true);
    }
    final worker = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWith(() => _WakeAccount(user)),
      ],
    );
    final events = <Map<String, dynamic>>[];
    final stream = LogWriter.instance.entries.listen((entry) {
      if (entry['pluginId'] is! String) return;
      if (events.length == 64) events.removeAt(0);
      events.add(entry);
    });
    try {
      final hosts = worker.read(metaversePluginHostsProvider);
      await dispatchMetaverseTask(
        control: control,
        background: true,
        available: (account) => account == user.id,
        installed: () => worker.read(metaversePluginsProvider),
        newHost: (plugin) => hosts.newHost(plugin, worker: true),
      );
      return true;
    } finally {
      try {
        await Future<void>.delayed(Duration.zero);
        await stream.cancel();
        control.queueEvents(owner, events);
      } finally { worker.dispose(); }
    }
  } finally {
    bootstrap.dispose();
  }
}
