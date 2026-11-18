import 'dart:async';

import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import '../../../services/log/log_writer.dart';
import '../plugin/metaverse_plugin_host.dart';
import '../plugin/metaverse_plugin_store.dart';
import 'metaverse_task_store.dart';

Future<String?> dispatchMetaverseTask({
  required MetaverseTaskStore control,
  required bool background,
  required bool Function(int account) available,
  required List<InstalledMetaversePlugin> Function() installed,
  required MetaversePluginHost Function(InstalledMetaversePlugin plugin)
  newHost,
  Duration timeout = const Duration(seconds: 24),
}) async {
  final lease = control.claim(background: background);
  if (lease == null) return null;
  final account = lease['account'] as int, id = lease['plugin'] as String;
  final task = lease['id'] as String;
  MetaversePluginHost? host;
  var running = true;
  String? failure;
  bool active() => running && available(account) && control.active(lease);
  try {
    final plugin = installed().where((entry) => entry.id == id).firstOrNull;
    if (plugin == null ||
        !plugin.enabled ||
        !plugin.manifest.runtimeSupported ||
        plugin.suspendedReason != null ||
        plugin.codeRevision != lease['installed']['revision'] ||
        plugin.source != lease['installed']['source'] ||
        (background && !plugin.manifest.capabilities.background) ||
        !active()) {
      throw const MetaversePluginCallException('task_cancelled');
    }
    host = newHost(plugin);
    await host
        .runTask(task, background: background, isActive: active)
        .timeout(timeout);
    if (!active()) throw const MetaversePluginCallException('task_cancelled');
    return id;
  } on TimeoutException {
    failure = 'task_timeout';
  } on MetaversePluginCallException catch (error) {
    failure =
        const {
          'task_cancelled',
          'forum_rate_limited',
          'forum_forbidden',
          'forum_auth_required',
          'task_handler_missing',
        }.contains(error.message)
        ? error.message
        : 'task_failed';
  } catch (_) {
    failure = 'task_failed';
  } finally {
    running = false;
    host?.shutdown();
    control.finish(lease, error: failure);
    LogWriter.instance.write({
      'type': 'plugin',
      'level': failure == null ? 'info' : 'warning',
      'event': 'plugin_task',
      'pluginId': id,
      'runtimeId': host?.runtimeId,
      'emitter': 'framework',
      'taskId': task,
      'background': background,
      'message': failure ?? 'task_complete',
    });
  }
  return null;
}
