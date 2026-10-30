import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/download_provider.dart';
import 'package:fluxdo/services/download_service.dart';
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/network/interceptors/network_log_interceptor.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath, this.downloadsPath);

  final String documentsPath;
  String? downloadsPath;
  Object? downloadsError;
  int downloadsCalls = 0;

  @override
  Future<String?> getDownloadsPath() async {
    downloadsCalls++;
    final error = downloadsError;
    if (error != null) throw error;
    return downloadsPath;
  }

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

class _DeniedFile extends Fake implements File {
  _DeniedFile(this.path);

  @override
  final String path;

  @override
  void createSync({bool recursive = false, bool exclusive = false}) {
    throw PathAccessException(
      path,
      const OSError('Operation not permitted', 1),
      'Creation failed',
    );
  }
}

class _DownloadAdapter implements HttpClientAdapter {
  _DownloadAdapter(this.scenario, this.directory);

  final String scenario;
  final Directory directory;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (scenario == 'http' || options.method == 'HEAD') {
      return ResponseBody.fromString('Forbidden', 403);
    }
    if (scenario == 'connection') {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Could not connect to ${options.uri}',
        error: const SocketException('Connection refused'),
      );
    }
    Stream<Uint8List> body() async* {
      if (scenario == 'write') {
        throw const FileSystemException(
          'write failed',
          '/tmp/file.part',
          OSError('No space left on device', 28),
        );
      }
      yield Uint8List.fromList('attachment content'.codeUnits);
    }

    if (scenario == 'commit') {
      // 将最终占位项替换为目录；临时文件照常写入，提交 rename 时必须失败。
      final target = directory.listSync().whereType<File>().singleWhere(
        (file) => file.path.endsWith('.pdf'),
      );
      target.deleteSync();
      Directory(target.path).createSync();
    }
    return ResponseBody(body(), 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const fileChannel = MethodChannel('com.fluxdo/public_file');
  late Directory sandbox;
  late PathProviderPlatform originalPathProvider;
  late _FakePathProvider pathProvider;
  late List<MethodCall> nativeCalls;
  Object? backupError;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('fluxdo-download-dir-test-');
    originalPathProvider = PathProviderPlatform.instance;
    pathProvider = _FakePathProvider(
      p.join(sandbox.path, 'Documents'),
      p.join(sandbox.path, 'Downloads'),
    );
    PathProviderPlatform.instance = pathProvider;
    DownloadService.debugIsIOSOverride = true;
    nativeCalls = [];
    backupError = null;
    await LogWriter.initForTesting(Directory(p.join(sandbox.path, 'logs')));
    binding.defaultBinaryMessenger.setMockMethodCallHandler(fileChannel, (
      call,
    ) async {
      nativeCalls.add(call);
      expect(call.method, 'excludeDownloadsFromBackup');
      expect(call.arguments, isNull);
      expect(
        Directory(p.join(pathProvider.documentsPath, 'Downloads')).existsSync(),
        isTrue,
        reason: '创建应用下载目录后再设置备份属性',
      );
      if (backupError != null) throw backupError!;
      return null;
    });
  });

  tearDown(() async {
    await LogWriter.resetForTesting();
    PathProviderPlatform.instance = originalPathProvider;
    DownloadService.debugIsIOSOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(fileChannel, null);
    sandbox.deleteSync(recursive: true);
  });

  test('iOS 直接使用 Documents/Downloads，不访问系统下载目录', () async {
    pathProvider.downloadsError = StateError('iOS 不应查询系统下载目录');

    final directory = await DownloadService.resolveDownloadDirectory();

    expect(directory.path, p.join(pathProvider.documentsPath, 'Downloads'));
    expect(await directory.exists(), isTrue);
    expect(pathProvider.downloadsCalls, 0);
    expect(await Directory(pathProvider.downloadsPath!).exists(), isFalse);
    expect(nativeCalls, hasLength(1));
    final reservation = DownloadService.reserveAvailableDownload(
      directory: directory,
      fileName: '2026-10-19-人工智能.pdf',
    );
    await File(reservation.temporaryPath).writeAsString('download content');
    await reservation.commit();
    expect(File(reservation.savePath).readAsStringSync(), 'download content');
  });

  test('iOS 复用已有目录并保留已有文件', () async {
    final directory = Directory(
      p.join(pathProvider.documentsPath, 'Downloads'),
    );
    await directory.create(recursive: true);
    final existing = File(p.join(directory.path, 'existing.pdf'));
    await existing.writeAsString('existing content');

    expect(
      (await DownloadService.resolveDownloadDirectory()).path,
      directory.path,
    );
    expect(await existing.readAsString(), 'existing content');
    expect(nativeCalls, hasLength(1));
  });

  test('iOS 目录创建失败时不查询其他位置或设置备份属性', () async {
    await File(pathProvider.documentsPath).writeAsString('blocked');

    await expectLater(
      DownloadService.resolveDownloadDirectory(),
      throwsA(isA<FileSystemException>()),
    );
    expect(pathProvider.downloadsCalls, 0);
    expect(nativeCalls, isEmpty);
  });

  for (final missingChannel in [false, true]) {
    test('iOS ${missingChannel ? '原生通道缺失' : '排除备份失败'}时保留目录并记录可导出警告', () async {
      backupError = PlatformException(code: 'BACKUP_EXCLUSION_FAILED');
      if (missingChannel) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          fileChannel,
          null,
        );
      }

      final directory = await DownloadService.resolveDownloadDirectory();
      expect(directory.path, p.join(pathProvider.documentsPath, 'Downloads'));
      expect(pathProvider.downloadsCalls, 0);
      await LogWriter.instance.flushNow();
      final entries = (await LogWriter.readAllContent())
          .split('\n')
          .where((line) => line.isNotEmpty)
          .map((line) => jsonDecode(line) as Map<String, dynamic>);
      final warning = entries.singleWhere(
        (entry) => entry['level'] == 'warning',
      );
      expect(warning['stage'], 'excludeBackup');
      expect(warning['fatal'], isFalse);
      expect(
        warning['errorType'],
        missingChannel ? 'MissingPluginException' : 'PlatformException',
      );
      expect(warning['stackTrace'], isNotEmpty);
    });
  }

  test('其他平台继续使用系统下载目录', () async {
    DownloadService.debugIsIOSOverride = false;

    final directory = await DownloadService.resolveDownloadDirectory();

    expect(directory.path, pathProvider.downloadsPath);
    expect(await directory.exists(), isTrue);
    expect(pathProvider.downloadsCalls, 1);
    expect(nativeCalls, isEmpty);
  });

  for (final unsupported in [false, true]) {
    test('其他平台下载目录${unsupported ? '不支持' : '为空'}时保留原有文档目录回退', () async {
      DownloadService.debugIsIOSOverride = false;
      pathProvider.downloadsPath = null;
      if (unsupported) {
        pathProvider.downloadsError = UnsupportedError('downloads unavailable');
      }

      final directory = await DownloadService.resolveDownloadDirectory();

      expect(directory.path, p.join(pathProvider.documentsPath, 'Downloads'));
      expect(await directory.exists(), isTrue);
      expect(nativeCalls, isEmpty);
    });
  }

  for (final stage in ['创建目录', '预留文件']) {
    testWidgets('目录准备阶段$stage失败时提示用户，不生成下载记录', (tester) async {
      if (stage == '创建目录') {
        File(pathProvider.documentsPath).writeAsStringSync('blocked');
      }
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notifier = DownloadNotifier(prefs);
      addTearDown(notifier.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );

      await tester.runAsync(
        () => IOOverrides.runZoned(
          () => notifier.startDownload(
            url: 'https://linux.do/uploads/short-url/example.pdf',
            suggestedFilename: '附件.pdf',
          ),
          createFile: stage == '预留文件' ? _DeniedFile.new : null,
        ),
      );
      await tester.pumpAndSettle();

      expect(notifier.state, isEmpty);
      expect(prefs.getString('download_items'), isNull);
      expect(find.text(S.current.myBrowser_downloadFailed), findsOneWidget);
      final entries = await tester.runAsync(() async {
        await LogWriter.instance.flushNow();
        return (await LogWriter.readAllContent())
            .split('\n')
            .where((line) => line.isNotEmpty)
            .map((line) => jsonDecode(line) as Map<String, dynamic>)
            .toList();
      });
      final failure = entries!.singleWhere(
        (entry) => entry['level'] == 'error',
      );
      expect(
        failure['stage'],
        stage == '创建目录' ? 'createDirectory' : 'reserveFile',
      );
      expect(failure['osErrorCode'], stage == '创建目录' ? isNotNull : 1);
      expect(failure['directory'], endsWith('Documents/Downloads'));
      expect(failure['stackTrace'], isNotEmpty);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  }

  for (final scenario in [
    'backup',
    'head',
    'http',
    'connection',
    'write',
    'commit',
  ]) {
    testWidgets('$scenario 场景留下可导出的阶段及关联日志', (tester) async {
      if (scenario == 'backup') {
        backupError = PlatformException(code: 'BACKUP_EXCLUSION_FAILED');
      }
      final dio = Dio()
        ..httpClientAdapter = _DownloadAdapter(
          scenario,
          Directory(p.join(pathProvider.documentsPath, 'Downloads')),
        );
      dio.interceptors.add(NetworkLogInterceptor());
      addTearDown(() => dio.close(force: true));
      SharedPreferences.setMockInitialValues({});
      final notifier = DownloadNotifier(
        await SharedPreferences.getInstance(),
        downloadService: DownloadService.forTesting(dio),
      );
      addTearDown(notifier.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );
      // 模拟正式版禁用 debugPrint，验证落盘不依赖控制台输出。
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {};
      try {
        await tester.runAsync(
          () => notifier.startDownload(
            url: 'https://user:password@linux.do/uploads/example.pdf?token=secret#fragment',
            suggestedFilename: scenario == 'head' ? null : '附件.pdf',
          ),
        );
      } finally {
        debugPrint = originalDebugPrint;
      }
      final entries = await tester.runAsync(() async {
        await LogWriter.instance.flushNow();
        final content = await LogWriter.readAllContent();
        expect(content, isNot(contains('secret')));
        expect(content, isNot(contains('password')));
        expect(content, isNot(contains('fragment')));
        return content
            .split('\n')
            .where((line) => line.isNotEmpty)
            .map((line) => jsonDecode(line) as Map<String, dynamic>)
            .toList();
      });
      final events = entries!
          .where((entry) => entry['tag'] == 'Download')
          .toList();
      expect(events.map((entry) => entry['downloadId']).toSet(), hasLength(1));
      final id = events.first['downloadId'];
      final requests = entries.where((entry) => entry['type'] == 'request');
      expect(requests, isNotEmpty);
      expect(requests.every((entry) => entry['downloadId'] == id), isTrue);
      final success = scenario == 'backup' || scenario == 'head';
      expect(
        notifier.state.single.status.name,
        success ? 'completed' : 'failed',
      );
      if (success) {
        expect(events.last['stage'], 'completed');
        expect(
          File(notifier.state.single.savePath).readAsStringSync(),
          'attachment content',
        );
        final warning = events.singleWhere(
          (entry) => entry['level'] == 'warning',
        );
        expect(
          warning['stage'],
          scenario == 'backup' ? 'excludeBackup' : 'fetchHeaders',
        );
      } else {
        final failure = events.singleWhere(
          (entry) => entry['level'] == 'error',
        );
        expect(
          failure['stage'],
          scenario == 'commit' ? 'commitFile' : 'transfer',
        );
        expect(failure['stackTrace'], isNotEmpty);
        expect(failure['savePath'], isNotEmpty);
        expect(failure['temporaryPath'], isNotEmpty);
        if (scenario == 'http') {
          expect(failure['statusCode'], 403);
        }
        if (scenario == 'connection') {
          expect(failure['dioType'], 'connectionError');
        }
        if (scenario == 'write') {
          expect(failure['causeType'], 'FileSystemException');
          expect(failure['osErrorCode'], 28);
        }
        if (scenario == 'commit') {
          expect(failure['osErrorCode'], isNotNull);
        }
      }
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
    });
  }
}
