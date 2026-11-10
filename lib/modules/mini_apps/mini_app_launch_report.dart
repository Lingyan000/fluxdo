/// 只接收加载计时、缓存来源和受限的宿主错误诊断，不落盘任意页面数据。
abstract final class MiniAppLaunchReport {
  /// 原生初始化/状态读取失败也要保留原因类型，但不记录任意错误文本或 URL。
  static Map<String, Object?>? nativeFailure(Object? value, String appId) {
    if (value is! Map ||
        value['appId'] != appId ||
        !{'web', 'lightweight'}.contains(value['engine']) ||
        !{'document_load', 'state_read', 'timeout'}.contains(value['phase']) ||
        !{
          'PlatformException',
          'TimeoutException',
          'FormatException',
          'StateError',
          'Error',
        }.contains(value['errorName'])) {
      return null;
    }
    final code = value['code'];
    return {
      'type': 'mini_app',
      'event': 'mini_app_native_boot_failed',
      'level': 'error',
      'appId': appId,
      'engine': value['engine'],
      'phase': value['phase'],
      'errorName': value['errorName'],
      if (code is String && RegExp(r'^[A-Z_0-9.-]{1,80}$').hasMatch(code))
        'code': code,
    };
  }

  /// 宿主挂载官方 loader 之前的错误没有 performance measure，单独保留受限诊断。
  static Map<String, Object?>? hostFailure(Object? value, String appId) {
    if (value is! Map || value['appId'] != appId) return null;
    if (!{
          'environment',
          'bootstrap',
          'runtime_assets',
          'session',
          'csrf',
          'user',
          'identity',
          'loader_import',
          'loader_mount',
        }.contains(value['phase']) ||
        !{
          'ACCESS_DENIED',
          'BROWSER_UNSUPPORTED',
          'INVALID_RUNTIME_ASSET',
          'INVALID_USER',
          'REQUEST_FAILED',
          'START_FAILED',
        }.contains(value['code'])) {
      return null;
    }
    final status = value['httpStatus'];
    return {
      'type': 'mini_app',
      'event': 'mini_app_host_failed',
      'level': 'error',
      'engine': 'lightweight',
      'appId': appId,
      'phase': value['phase'],
      'code': value['code'],
      if ({
        'Error',
        'TypeError',
        'SyntaxError',
        'ReferenceError',
        'SecurityError',
        'AbortError',
        'TimeoutError',
        'NotSupportedError',
      }.contains(value['errorName']))
        'errorName': value['errorName'],
      if (status is int && status >= 100 && status <= 599) 'httpStatus': status,
      for (final key in ['secureContext', 'sameOrigin', 'entryMatches'])
        if (value[key] is bool) key: value[key],
    };
  }

  static num? _number(Object? value) =>
      value is num && value.isFinite && value >= 0 && value <= 86400000
      ? value
      : null;

  /// 子窗口不单独打开日志文件，由主窗口校验应用绑定和字段后统一记录。
  static Map<String, dynamic>? fromWindow(Object? value, String appId) {
    if (value is! Map || !{'web', 'lightweight'}.contains(value['engine'])) {
      return null;
    }
    if (value['event'] == 'mini_app_host_failed') {
      final failure = hostFailure(value, appId);
      return failure == null ? null : {...failure, 'independentWindow': true};
    }
    if (value['event'] == 'mini_app_native_boot_failed') {
      final failure = nativeFailure(value, appId);
      return failure == null ? null : {...failure, 'independentWindow': true};
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
