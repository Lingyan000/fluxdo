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
  test('同 UA 的磁盘缓存也执行当前进程两轮校准', () async {
    var probes = 0;
    final service = FingerprintTemplateService.forTesting(
      status: (_) async => {
        'ready': true,
        'user_agent': 'frozen',
        'needs_revalidation': probes < 2,
        'cache_state': 'loaded_pending_revalidation',
      },
      userAgent: () async => 'frozen',
      probe: (_, _) async {
        probes++;
      },
    );
    await service.ensure(1);
    expect(probes, 2);
    expect(service.templateReady.value, true);
    await service.ensure(1);
    expect(probes, 2);
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

  test('TCP 已就绪仍独立采样两个 H3 origin，失败不重复采样或撤销 TCP', () async {
    final ports = <int>[];
    final service = FingerprintTemplateService.forTesting(
      status: (_) async => {
        'ready': true, 'user_agent': 'actual',
        'h3': {'enabled_for_template': false, 'probe_ports': [2, 3], 'error': 'UDP unavailable'},
      },
      probe: (port, _) async { ports.add(port); },
      userAgent: () async => 'actual',
    );
    await service.ensure(1);
    await service.ensure(1);
    expect(ports, [2, 3]);
    expect(service.templateReady.value, true);
  });

  test('H3 校准中停止核心会取消探针且不启动第二个 origin', () async {
    final started = Completer<void>();
    final ports = <int>[];
    final service = FingerprintTemplateService.forTesting(
      status: (_) async => {
        'ready': true, 'user_agent': 'actual',
        'h3': {'enabled_for_template': false, 'probe_ports': [2, 3]},
      },
      probe: (port, cancelled) async {
        ports.add(port); started.complete(); await cancelled;
      },
      userAgent: () async => 'actual',
    );
    final pending = service.ensure(1);
    await started.future;
    service.reset();
    await pending;
    expect(ports, [2]);
    expect(service.templateReady.value, false);
  });

  test('同 UA 和端口的 H3 模板失效后按核心采样代次重新校准', () async {
    var epoch = 1;
    final ports = <int>[];
    final service = FingerprintTemplateService.forTesting(
      status: (_) async => {'ready': true, 'user_agent': 'actual',
        'h3': {'enabled_for_template': false, 'probe_ports': [2, 3], 'epoch': epoch}},
      probe: (port, _) async { ports.add(port); },
      userAgent: () async => 'actual',
    );
    await service.ensure(1);
    await service.ensure(1);
    expect(ports, [2, 3]);
    epoch++;
    await service.ensure(1);
    await service.ensure(1);
    expect(ports, [2, 3, 2, 3]);
    expect(service.templateReady.value, true);
  });

  test('同端口探针证书变化后重试，但映射顺序变化不重复采样', () async {
    var pins = <String, String>{'2': 'first', '3': 'second'};
    final ports = <int>[];
    final service = FingerprintTemplateService.forTesting(
      status: (_) async => {'ready': true, 'user_agent': 'actual',
        'h3': {'enabled_for_template': false, 'probe_ports': [2, 3], 'probe_spki': pins}},
      probe: (port, _) async { ports.add(port); },
      userAgent: () async => 'actual',
    );
    await service.ensure(1);
    pins = {'3': 'second', '2': 'first'};
    await service.ensure(1);
    expect(ports, [2, 3]);
    pins = {'3': 'second', '2': 'new'};
    await service.ensure(1);
    expect(ports, [2, 3, 2, 3]);
  });

  test('首次启动可在 TCP 校验完成后返回，H3 继续串行且可被取消', () async {
    final started = Completer<void>();
    var probes = 0;
    final service = FingerprintTemplateService.forTesting(
      status: (_) async => {
        'ready': true,
        'user_agent': 'actual',
        'h3': {'enabled_for_template': false, 'probe_ports': [2, 3]},
      },
      userAgent: () async => 'actual',
      probe: (_, cancelled) async {
        probes++;
        started.complete();
        await cancelled;
      },
    );
    final tcp = service.ensure(1, waitForH3: false);
    var allFinished = false;
    final all = service.ensure(1).then((_) => allFinished = true);
    await started.future;
    await tcp;
    expect(service.templateReady.value, true);
    expect(allFinished, false);
    expect(probes, 1);
    service.reset();
    await all;
    expect(probes, 1);
    expect(service.templateReady.value, false);
  });
}
