import 'dart:convert';

import '../fingerprint/h3_calibration_status.dart';

/// 日志使用的只读快照；读取失败保留未知，不回退到业务状态缓存。
class NetCoreDiagnosticSnapshot {
  const NetCoreDiagnosticSnapshot._(this.readStatus, this._status);

  final String readStatus;
  final Map<String, dynamic>? _status;

  factory NetCoreDiagnosticSnapshot.capture(String? Function() readJson) {
    final String? raw;
    try {
      raw = readJson();
    } catch (_) {
      return const NetCoreDiagnosticSnapshot._('status_read_failed', null);
    }
    if (raw == null) {
      return const NetCoreDiagnosticSnapshot._('status_unavailable', null);
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> || value['running'] is! bool) {
        return const NetCoreDiagnosticSnapshot._('status_invalid', null);
      }
      return NetCoreDiagnosticSnapshot._('live', value);
    } catch (_) {
      return const NetCoreDiagnosticSnapshot._('status_invalid', null);
    }
  }

  Map<String, dynamic> toLogFields({required bool appProxyEnabled}) {
    final status = _status;
    final systemProxy = status?['system_proxy'] is bool
        ? status!['system_proxy'] as bool
        : null;
    final diagnostics = status?['template_diagnostics'] is Map
        ? status!['template_diagnostics'] as Map
        : null;
    final h3 = H3CalibrationStatus.fromJson(diagnostics?['h3']);
    return {
      'coreStatusRead': readStatus,
      'coreRunning': status?['running'],
      'proxyEnabled': appProxyEnabled,
      'systemProxyEnabled': systemProxy,
      'effectiveProxyEnabled': appProxyEnabled ? true : systemProxy,
      'proxySource': appProxyEnabled
          ? 'app'
          : switch (systemProxy) {
              true => 'system',
              false => 'direct',
              null => 'unknown',
            },
      'templateMode': status?['template_mode'],
      'templateSource': status?['template_source'],
      'templatePreset': status?['template_preset'],
      'templateDiagnostics': diagnostics,
      'h3CalibrationState': h3.state.name,
      'h3CalibrationReason': h3.reason,
    };
  }
}
