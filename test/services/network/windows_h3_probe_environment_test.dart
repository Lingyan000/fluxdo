import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/fingerprint/windows_h3_probe_environment.dart';

class _Environment implements WebViewEnvironment {
  int disposals = 0;
  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final spki = base64Encode(List<int>.generate(32, (i) => i));
  test('只接受规范证书指纹与本机端口，拒绝命令行注入', () {
    for (final value in [
      '',
      'bad',
      '$spki --ignore-certificate-errors',
      base64Encode([1, 2]),
    ]) {
      expect(
        () => WindowsH3ProbeEnvironment.arguments(43210, value),
        throwsFormatException,
      );
    }
    for (final port in [0, -1, 65536]) {
      expect(
        () => WindowsH3ProbeEnvironment.arguments(port, spki),
        throwsFormatException,
      );
    }
    final arguments = WindowsH3ProbeEnvironment.arguments(43210, spki);
    expect(arguments, contains('--origin-to-force-quic-on=localhost:43210 '));
    expect(arguments, contains('--ignore-certificate-errors-spki-list=$spki '));
    expect(arguments, isNot(contains('--ignore-certificate-errors ')));
  });

  test('两个探针各用独立临时 profile，重复销毁只释放一次', () async {
    final root = await Directory.systemTemp.createTemp('h3-test-');
    addTearDown(() => root.delete(recursive: true));
    final directories = <String>[];
    final native = <_Environment>[];
    Future<WebViewEnvironment> factory(
      WebViewEnvironmentSettings settings,
    ) async {
      directories.add(settings.userDataFolder!);
      final environment = _Environment();
      native.add(environment);
      return environment;
    }

    final cancelled = Completer<void>();
    for (final port in [10001, 10002]) {
      final probe = await WindowsH3ProbeEnvironment.create(
        port: port,
        spki: spki,
        cancelled: cancelled.future,
        factory: factory,
        temporaryRoot: root,
      );
      expect(await probe.directory.exists(), true);
      await Future.wait([probe.dispose(), probe.dispose()]);
      expect(await probe.directory.exists(), false);
    }
    expect(directories.toSet().length, 2);
    expect(native.map((e) => e.disposals), [1, 1]);
  });

  for (final mode in ['cancel', 'timeout']) {
    test('$mode 后迟到的原生环境也必须释放', () async {
      final root = await Directory.systemTemp.createTemp('h3-test-');
      addTearDown(() => root.delete(recursive: true));
      final pending = Completer<WebViewEnvironment>();
      final started = Completer<void>();
      final cancelled = Completer<void>();
      final native = _Environment();
      final operation = WindowsH3ProbeEnvironment.create(
        port: 10001,
        spki: spki,
        cancelled: cancelled.future,
        temporaryRoot: root,
        timeout: const Duration(milliseconds: 30),
        factory: (_) {
          started.complete();
          return pending.future;
        },
      );
      final check = expectLater(
        operation,
        mode == 'cancel' ? throwsStateError : throwsA(isA<TimeoutException>()),
      );
      await started.future;
      if (mode == 'cancel') cancelled.complete();
      await check;
      pending.complete(native);
      for (
        var i = 0;
        i < 100 &&
            (native.disposals == 0 || await root.list().isEmpty == false);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(native.disposals, 1);
      expect(await root.list().isEmpty, true);
    });
  }

  test('已经取消时不创建原生环境', () async {
    final root = await Directory.systemTemp.createTemp('h3-test-');
    addTearDown(() => root.delete(recursive: true));
    var creates = 0;
    await expectLater(WindowsH3ProbeEnvironment.create(port: 10001, spki: spki,
        cancelled: Future<void>.value(), temporaryRoot: root,
        factory: (_) async { creates++; return _Environment(); }), throwsStateError);
    expect(creates, 0);
    expect(await root.list().isEmpty, true);
  });

  test('原生控制器创建超时后先等迟到结果，再销毁控制器和环境', () async {
    final started = Completer<void>();
    final events = <String>[];
    await disposeProbeResources(started: started.future,
        disposeView: () async { events.add('view'); },
        disposeEnvironment: () async { events.add('environment'); },
        timeout: const Duration(milliseconds: 10));
    expect(events, isEmpty);
    started.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(events, ['view', 'environment']);
  });

  test('创建失败仍清理控制器，控制器销毁失败仍释放环境', () async {
    final events = <String>[];
    await expectLater(disposeProbeResources(started: Future<void>.error(StateError('create')),
        disposeView: () async { events.add('view'); throw StateError('dispose'); },
        disposeEnvironment: () async { events.add('environment'); }), throwsStateError);
    expect(events, ['view', 'environment']);
  });

  test('原生环境创建失败会清理空目录', () async {
    final root = await Directory.systemTemp.createTemp('h3-test-');
    addTearDown(() => root.delete(recursive: true));
    await expectLater(
      WindowsH3ProbeEnvironment.create(
        port: 10001,
        spki: spki,
        cancelled: Completer<void>().future,
        temporaryRoot: root,
        factory: (_) => throw StateError('native failure'),
      ),
      throwsStateError,
    );
    for (var i = 0; i < 100 && !await root.list().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(await root.list().isEmpty, true);
  });
}
