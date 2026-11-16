/// 只描述本地模板校准，不推断业务请求协议或站点是否放行。
enum H3CalibrationState { unknown, notReady, sampled }

class H3CalibrationStatus {
  const H3CalibrationStatus._(this.state, this.reason);

  final H3CalibrationState state;
  final String reason;

  factory H3CalibrationStatus.fromJson(Object? value) {
    if (value is! Map || value['enabled_for_template'] is! bool) {
      return const H3CalibrationStatus._(
        H3CalibrationState.unknown,
        'status_unavailable',
      );
    }
    final sampled = value['enabled_for_template'] == true;
    final reason = value['error'] ?? value['reason'];
    return H3CalibrationStatus._(
      sampled ? H3CalibrationState.sampled : H3CalibrationState.notReady,
      reason is String && reason.isNotEmpty
          ? reason
          : (sampled ? 'sampled_quic_h3_profile' : 'reason_unavailable'),
    );
  }
}
