import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

/// 声明可由宿主调度的任务，执行内容始终来自插件脚本。
class MetaverseTaskSpec {
  const MetaverseTaskSpec(this.id, this.title);
  final String id, title;

  static List<MetaverseTaskSpec> parse(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > 4) {
      throw const FormatException('tasks 最多声明 4 项');
    }
    final ids = <String>{};
    return List.unmodifiable(
      raw.map((item) {
        if (item is! Map || item.keys.any((k) => k != 'id' && k != 'title')) {
          throw const FormatException('任务声明无效');
        }
        final id = item['id'], title = item['title'];
        if (id is! String ||
            !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$').hasMatch(id) ||
            !ids.add(id) ||
            title is! String ||
            title.trim().isEmpty ||
            title.length > 80) {
          throw const FormatException('任务名称或标识无效');
        }
        return MetaverseTaskSpec(id, title);
      }),
    );
  }
}

class MetaverseTaskSchedule {
  const MetaverseTaskSchedule(
    this.id,
    this.intervalSeconds, {
    this.background = false,
  });
  final String id;
  final int intervalSeconds;
  final bool background;
  static MetaverseTaskSchedule parse(Map<String, Object?> options) {
    final id = options['id'], interval = options['intervalSeconds'];
    if (id is! String ||
        interval is! int ||
        interval < 10 ||
        interval > 86400 ||
        options.keys.any(
          (k) => k != 'id' && k != 'intervalSeconds' && k != 'background',
        )) {
      throw const MetaversePluginCallException('task_invalid_schedule');
    }
    if (options['background'] != null && options['background'] is! bool) {
      throw const MetaversePluginCallException('task_invalid_schedule');
    }
    return MetaverseTaskSchedule(
      id,
      interval,
      background: options['background'] == true,
    );
  }
}
