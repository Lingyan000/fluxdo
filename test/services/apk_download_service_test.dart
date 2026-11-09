import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/apk_download_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/update_service.dart';
import 'package:ota_update/ota_update.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const streamChannel = MethodChannel('sk.fourq.ota_update/stream');
  const methodChannel = MethodChannel('sk.fourq.ota_update/method');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Completer<Map<Object?, Object?>> listening;
  late Completer<void> canceled;
  late List<String> methodCalls;

  Future<void> sendEvent(int code, [String value = '']) async {
    await messenger.handlePlatformMessage(
      streamChannel.name,
      codec.encodeSuccessEnvelope([code.toString(), value]),
      (_) {},
    );
  }

  Future<void> finish() async {
    await messenger.handlePlatformMessage(streamChannel.name, null, (_) {});
  }

  ApkAsset asset() => ApkAsset(
    downloadUrl: 'https://example.com/fluxdo.apk',
    architecture: 'arm64-v8a',
    size: 1024,
    name: 'fluxdo.apk',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    listening = Completer();
    canceled = Completer();
    methodCalls = [];
    messenger.setMockMethodCallHandler(streamChannel, (call) async {
      if (call.method == 'listen') {
        listening.complete(Map<Object?, Object?>.from(call.arguments as Map));
      } else if (call.method == 'cancel' && !canceled.isCompleted) {
        canceled.complete();
      }
      return null;
    });
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      methodCalls.add(call.method);
      if (call.method == 'cancel') {
        await sendEvent(9);
        await finish();
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(streamChannel, null);
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  testWidgets('启用安装会话，系统报告成功前不会把下载结束当作更新完成', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
      ),
    );
    await tester.runAsync(() async {
      final events = <ApkDownloadProgress>[];
      final done = Completer<void>();
      final sub = ApkDownloadService()
          .downloadAndInstall(asset())
          .listen(events.add, onDone: done.complete);
      addTearDown(sub.cancel);
      final arguments = await listening.future;
      expect(arguments['usePackageInstaller'], 'true');
      expect(arguments['confirmationNotificationText'], isNotEmpty);
      await sendEvent(0, '100');
      await sendEvent(1);
      expect(
        events.map((e) => e.status),
        isNot(contains(ApkDownloadStatus.completed)),
      );
      await sendEvent(2);
      await finish();
      await done.future;
      expect(events.last.status, ApkDownloadStatus.completed);
      expect(events.last.progress, 100);
    });
  });

  testWidgets('安装失败保留系统错误信息并结束状态流，允许用户重试', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
      ),
    );
    await tester.runAsync(() async {
      final result = ApkDownloadService().downloadAndInstall(asset()).toList();
      await listening.future;
      await messenger.handlePlatformMessage(
        streamChannel.name,
        codec.encodeErrorEnvelope(
          code: '4',
          message: 'INSTALL_FAILED_UPDATE_INCOMPATIBLE',
        ),
        (_) {},
      );
      await finish();
      final events = await result;
      expect(events.last.status, ApkDownloadStatus.error);
      expect(events.last.error, contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE'));
      expect(events.last.error, isNot(S.current.download_alreadyInProgress));
    });
  });

  testWidgets('正在执行和安装失败使用不同的状态码', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
      ),
    );
    await tester.runAsync(() async {
      final result = ApkDownloadService().downloadAndInstall(asset()).toList();
      await listening.future;
      await messenger.handlePlatformMessage(
        streamChannel.name,
        codec.encodeErrorEnvelope(code: '3', message: 'busy'),
        (_) {},
      );
      await finish();
      expect((await result).last.error, S.current.download_alreadyInProgress);
    });
  });

  testWidgets('取消下载会通知原生停止，取消后不会报告安装完成', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
      ),
    );
    await tester.runAsync(() async {
      final service = ApkDownloadService();
      final result = service.downloadAndInstall(asset()).toList();
      await listening.future;
      await service.cancelDownload();
      final events = await result;
      expect(methodCalls, ['cancel']);
      expect(
        events.map((e) => e.status),
        isNot(contains(ApkDownloadStatus.completed)),
      );
    });
  });

  testWidgets('取消 Dart 订阅会释放原生事件通道', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
      ),
    );
    await tester.runAsync(() async {
      final sub = OtaUpdate()
          .execute('https://example.com/fluxdo.apk')
          .listen((_) {});
      await listening.future;
      await sub.cancel();
      await canceled.future;
    });
  });
}
