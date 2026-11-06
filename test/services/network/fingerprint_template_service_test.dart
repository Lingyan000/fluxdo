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
}
