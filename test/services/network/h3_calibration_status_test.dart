import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/fingerprint/h3_calibration_status.dart';

void main() {
  test('缺少或损坏就绪字段不能冒充采样失败', () {
    for (final value in [
      null,
      {},
      [],
      {'enabled_for_template': 'false'},
    ]) {
      final status = H3CalibrationStatus.fromJson(value);
      expect(status.state, H3CalibrationState.unknown);
      expect(status.reason, 'status_unavailable');
    }
  });

  test('已观察到的未就绪保留失败原因，没有原因则明确未知', () {
    final failed = H3CalibrationStatus.fromJson({
      'enabled_for_template': false,
      'error': 'UDP unavailable',
      'reason': 'native_quic_h3_calibration_failed',
    });
    expect(failed.state, H3CalibrationState.notReady);
    expect(failed.reason, 'UDP unavailable');
    expect(
      H3CalibrationStatus.fromJson({'enabled_for_template': false}).reason,
      'reason_unavailable',
    );
  });

  test('两次采样就绪仅描述模板，保留原生观测理由', () {
    final sampled = H3CalibrationStatus.fromJson({
      'enabled_for_template': true,
      'reason': 'sampled_quic_h3_profile',
    });
    expect(sampled.state, H3CalibrationState.sampled);
    expect(sampled.reason, 'sampled_quic_h3_profile');
  });
}
