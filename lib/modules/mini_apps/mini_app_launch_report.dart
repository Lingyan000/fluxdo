/// 只接收官方加载器的计时与缓存来源，绝不落盘任意页面数据。
abstract final class MiniAppLaunchReport {
  static num? _number(Object? value) =>
      value is num && value.isFinite && value >= 0 && value <= 86400000
      ? value
      : null;

  /// 子窗口不单独打开日志文件，由主窗口校验应用绑定和字段后统一记录。
  static Map<String, dynamic>? fromWindow(Object? value, String appId) {
    if (value is! Map || !{'web', 'lightweight'}.contains(value['engine'])) {
      return null;
    }
    final report = parse({
      'appId': value['appId'],
      'status': value['status'],
      'startTime': value['loaderStartMs'],
      'duration': value['loaderDurationMs'],
      'packageSource': value['packageSource'],
      'phases': value['phasesMs'],
    }, appId);
    if (report == null) return null;
    return {
      'type': 'mini_app',
      'event': 'mini_app_launch',
      'level': 'info',
      'engine': value['engine'],
      'independentWindow': true,
      for (final key in [
        'observedElapsedMs',
        'viewCreatedMs',
        'cookiesReadyMs',
      ])
        key: ?_number(value[key]),
      ...report,
    };
  }

  static Map<String, Object?>? parse(Object? value, String appId) {
    if (value is! Map ||
        value['appId'] != appId ||
        !{'ready', 'failed', 'closed'}.contains(value['status'])) {
      return null;
    }
    final duration = _number(value['duration']);
    final start = _number(value['startTime']);
    if (duration == null || start == null) return null;
    final phases = value['phases'];
    return {
      'appId': appId,
      'status': value['status'],
      'loaderStartMs': start,
      'loaderDurationMs': duration,
      if ({'memory', 'persistent', 'network'}.contains(value['packageSource']))
        'packageSource': value['packageSource'],
      'phasesMs': {
        for (final phase in [
          'authorize',
          'sdk',
          'package',
          'download',
          'worker',
          'decrypt',
          'verify',
          'unpack',
          'audio_choice',
          'mount',
          'app',
        ])
          if (phases is Map && _number(phases[phase]) != null)
            phase: _number(phases[phase]),
      },
    };
  }
}
