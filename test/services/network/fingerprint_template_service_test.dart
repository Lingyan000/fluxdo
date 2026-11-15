import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/fingerprint/fingerprint_template_service.dart';

void main() {
  test('同端口并发检查合并，已有真实模板不启动探针', () async {
    var reads = 0;
    var probes = 0;
    final status = Completer<Map<String, dynamic>?>();
    final service = FingerprintTemplateService.forTesting(
      status: (_) {
        reads++;
        return status.future;
      },
      probe: (_, _) async {
        probes++;
      },
      userAgent: () async => 'actual',
    );
    final a = service.ensure(1);
    final b = service.ensure(1);
    status.complete({'ready': true, 'user_agent': 'actual'});
    await Future.wait([a, b]);
    expect(reads, 1);
    expect(probes, 0);
    expect(service.templateReady.value, true);
  });
  test('切换核心取消旧探针，销毁后才启动新探针且旧结果不覆盖新状态', () async {
    var active = 0;
    var peak = 0;
    final started = Completer<void>();
    final probed = <int>[];
    final ready = <int>{};
    final service = FingerprintTemplateService.forTesting(
      status: (port) async => {
        'ready': ready.contains(port),
        'user_agent': 'actual',
      },
      userAgent: () async => 'actual',
      probe: (port, cancelled) async {
        active++;
        if (active > peak) peak = active;
        probed.add(port);
        if (port == 1) {
          started.complete();
          await cancelled;
        }
        ready.add(port);
        active--;
      },
    );
    final first = service.ensure(1);
    await started.future;
    final second = service.ensure(2);
    await Future.wait([first, second]);
    expect(probed, [1, 2]);
    expect(peak, 1);
    expect(service.templateReady.value, true);
  });
  test('停止核心后旧状态查询不能恢复就绪状态', () async {
    final status = Completer<Map<String, dynamic>?>();
    final service = FingerprintTemplateService.forTesting(
      status: (_) => status.future,
      probe: (_, _) async {},
      userAgent: () async => 'actual',
    );
    final pending = service.ensure(1);
    service.reset();
    status.complete({'ready': true, 'user_agent': 'actual'});
    await pending;
    expect(service.templateReady.value, false);
  });
  test('同一 UA 的未校准模板执行两轮采样后才就绪', () async {
    var probes = 0;
    final service = FingerprintTemplateService.forTesting(
      status: (_) async => {'ready': probes >= 2, 'user_agent': 'Chrome/110'},
      userAgent: () async => 'Chrome/110',
      probe: (_, _) async {
        probes++;
      },
    );
    await service.ensure(1);
    expect(probes, 2);
    expect(service.templateReady.value, true);
  });

  test('采样始终不完整时有界退出，不把部分模板当成就绪', () async {
    var probes = 0;
    final service = FingerprintTemplateService.forTesting(
      status: (_) async => {'ready': false, 'user_agent': 'actual'},
      userAgent: () async => 'actual',
      probe: (_, _) async {
        probes++;
      },
    );
    await service.ensure(1);
    expect(probes, 2);
    expect(service.templateReady.value, false);
  });

  test('首轮没有取得当前 UA 时不重复启动失败探针', () async {
    var probes = 0;
    final service = FingerprintTemplateService.forTesting(
      status: (_) async => {'ready': false, 'user_agent': null},
      userAgent: () async => 'actual',
      probe: (_, _) async {
        probes++;
      },
    );
    await service.ensure(1);
    expect(probes, 1);
    expect(service.templateReady.value, false);
  });
  test('两轮间取消会立即结束，不创建第二个 WebView', () async {
    var reads = 0;
    var probes = 0;
    final firstProbeRead = Completer<void>();
    final service = FingerprintTemplateService.forTesting(
      status: (_) async {
        reads++;
        if (reads == 2) firstProbeRead.complete();
        return {'ready': false, 'user_agent': 'actual'};
      },
      userAgent: () async => 'actual',
      probe: (_, _) async {
        probes++;
      },
    );
    final pending = service.ensure(1);
    await firstProbeRead.future;
    service.reset();
    await pending;
    expect(probes, 1);
    expect(service.templateReady.value, false);
  });
}
