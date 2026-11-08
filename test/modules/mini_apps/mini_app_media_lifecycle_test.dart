import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_media_lifecycle.dart';

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('迟到暂停完成后才恢复，快速切换合并到最终状态', () async {
    final lifecycle = MiniAppMediaLifecycle();
    final pause = Completer<void>();
    final started = <bool>[];
    bool? suspended;
    final binding = lifecycle.bind(
      platform: (value, _) async {
        started.add(value);
        if (value) await pause.future;
        suspended = value;
      },
      host: (_, _) async {},
    );
    binding.update(suspended: true);
    binding.update(suspended: false);
    binding.update(suspended: true);
    binding.update(suspended: false);
    await flush();
    expect(started, [true], reason: '旧暂停未结束前不能抢先恢复');
    pause.complete();
    await flush();
    expect(started, [true, false]);
    expect(suspended, isFalse);
    binding.update(suspended: false);
    await flush();
    expect(started, [true, false], reason: '相同目标不重复干扰网页焦点');
    lifecycle.dispose();
  });

  test('网页脚本延迟不拖住原生恢复，新绑定使旧页面任务失效', () async {
    final lifecycle = MiniAppMediaLifecycle();
    final checkUrl = Completer<void>();
    final platform = <bool>[];
    final host = <bool>[];
    final old = lifecycle.bind(
      platform: (value, _) async => platform.add(value),
      host: (value, current) async {
        await checkUrl.future;
        if (current()) host.add(value);
      },
    );
    old.update(suspended: true);
    await flush();
    final restored = lifecycle.bind(
      platform: (value, _) async => platform.add(value),
      host: (value, _) async => host.add(value),
    );
    restored.update(suspended: false);
    old.update(suspended: true);
    await flush();
    expect(platform, [true, false]);
    expect(host, isEmpty);
    checkUrl.complete();
    await flush();
    expect(host, [false], reason: '旧页面不得向恢复后的实例补发暂停');
    lifecycle.dispose();
  });

  test('收起前未完成的原生操作与恢复页共用执行顺序', () async {
    final lifecycle = MiniAppMediaLifecycle();
    final pause = Completer<void>();
    final events = <String>[];
    final old = lifecycle.bind(
      platform: (value, _) async {
        events.add('pause-start');
        await pause.future;
        events.add('pause-end');
      },
      host: (_, _) async {},
    );
    old.update(suspended: true);
    final restored = lifecycle.bind(
      platform: (value, _) async => events.add('resume'),
      host: (_, _) async {},
    );
    restored.update(suspended: false);
    await flush();
    expect(events, ['pause-start']);
    pause.complete();
    await flush();
    expect(events, ['pause-start', 'pause-end', 'resume']);
    lifecycle.dispose();
  });

  test('异常不阻断后续目标，重新加载仅刷新网页状态', () async {
    final lifecycle = MiniAppMediaLifecycle();
    final platform = <bool>[];
    final host = <bool>[];
    final binding = lifecycle.bind(
      platform: (value, _) async {
        platform.add(value);
        if (value) throw UnimplementedError();
      },
      host: (value, _) async => host.add(value),
    );
    binding.update(suspended: true);
    await flush();
    binding.update(suspended: false);
    await flush();
    binding.update(suspended: false, refreshHost: true);
    await flush();
    expect(platform, [true, false]);
    expect(host, [true, false, false]);
    lifecycle.dispose();
  });

  test('关闭实例后丢弃排队操作，不影响全新实例', () async {
    final lifecycle = MiniAppMediaLifecycle();
    final gate = Completer<void>();
    final events = <bool>[];
    final binding = lifecycle.bind(
      platform: (value, current) async {
        await gate.future;
        if (current()) events.add(value);
      },
      host: (_, _) async {},
    );
    binding.update(suspended: true);
    binding.update(suspended: false);
    lifecycle.dispose();
    final fresh = MiniAppMediaLifecycle();
    fresh
        .bind(
          platform: (value, _) async => events.add(value),
          host: (_, _) async {},
        )
        .update(suspended: false);
    gate.complete();
    binding.update(suspended: true);
    await flush();
    expect(events, [false]);
    fresh.dispose();
  });
}
