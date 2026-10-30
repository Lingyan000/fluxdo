import 'dart:convert';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/download_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/log/logger_utils.dart';
import 'package:fluxdo/services/public_file_channel.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/utils/share_utils.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Picker extends FilePicker {
  int calls = 0;
  Uint8List? bytes;
  Object? error;
  String? result = '/export/app_log_share.jsonl';

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    calls++;
    this.bytes = bytes;
    if (error != null) throw error!;
    return result;
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.downloadsPath);
  final String downloadsPath;
  int calls = 0;

  @override
  Future<String?> getDownloadsPath() async {
    calls++;
    return downloadsPath;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fluxdo/public_file');
  late Directory sandbox;
  late File source;
  late List<String> nativeCalls;
  late _Picker picker;
  late _Paths paths;
  late PathProviderPlatform originalPaths;
  FilePicker? originalPicker;
  Map<String, Object?>? nativeResult;
  Object? nativeError;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('file-save-test-');
    source = File(p.join(sandbox.path, 'app_log_share.jsonl'))
      ..writeAsStringSync('{"message":"测试日志"}\n');
    await LogWriter.initForTesting(Directory(p.join(sandbox.path, 'logs')));
    try {
      originalPicker = FilePicker.platform;
    } catch (_) {
      originalPicker = null;
    }
    picker = _Picker();
    FilePicker.platform = picker;
    originalPaths = PathProviderPlatform.instance;
    paths = _Paths(p.join(sandbox.path, 'Downloads'));
    PathProviderPlatform.instance = paths;
    PlatformUtils.debugDesktopOverride = false;
    PublicFileChannel.debugPlatformOverride = TargetPlatform.iOS;
    DownloadService.debugIsIOSOverride = false;
    nativeCalls = [];
    nativeError = null;
    nativeResult = {'uri': '', 'displayName': '用户命名的日志.jsonl'};
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      nativeCalls.add(call.method);
      expect((call.arguments as Map)['sourcePath'], source.path);
      if (nativeError != null) throw nativeError!;
      return nativeResult;
    });
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    if (originalPicker != null) FilePicker.platform = originalPicker!;
    PathProviderPlatform.instance = originalPaths;
    PlatformUtils.debugDesktopOverride = null;
    PublicFileChannel.debugPlatformOverride = null;
    DownloadService.debugIsIOSOverride = null;
    await LogWriter.resetForTesting();
    sandbox.deleteSync(recursive: true);
  });

  Future<List<Map<String, dynamic>>> readLogs() async {
    await LogWriter.instance.flushNow();
    return (await LogWriter.readAllContent())
        .split('\n')
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
  }

  test('只有 Android 提供公共下载目录，iOS 仍支持原生导出', () {
    expect(PublicFileChannel.isSupported, isTrue);
    expect(PublicFileChannel.hasPublicDownloads, isFalse);
    PublicFileChannel.debugPlatformOverride = TargetPlatform.android;
    expect(PublicFileChannel.hasPublicDownloads, isTrue);
    PublicFileChannel.debugPlatformOverride = TargetPlatform.macOS;
    expect(PublicFileChannel.isSupported, isFalse);
    expect(PublicFileChannel.hasPublicDownloads, isFalse);
  });

  test('iOS 保存日志直接调用原生另存为，不写入应用下载目录', () async {
    final outcome = await ShareUtils.saveFile(XFile(source.path));
    expect(nativeCalls, ['saveAs']);
    expect(outcome.shared, isTrue);
    expect(outcome.displayName, '用户命名的日志.jsonl');
    expect(outcome.finalPath, isNull);
    expect(picker.calls, 0);
    expect(paths.calls, 0);
    expect(Directory(paths.downloadsPath).existsSync(), isFalse);
  });

  test('iOS 直接请求公共下载目录时不会调用原生通道', () async {
    expect(
      await PublicFileChannel.saveToDownloads(
        sourcePath: source.path,
        fileName: p.basename(source.path),
      ),
      isNull,
    );
    expect(nativeCalls, isEmpty);
  });

  test('iOS 取消系统保存面板后不启用其他保存方式，也不记录错误', () async {
    nativeResult = null;
    final outcome = await ShareUtils.saveFile(XFile(source.path));
    expect(outcome.shared, isFalse);
    expect(nativeCalls, ['saveAs']);
    expect(picker.calls, 0);
    expect(paths.calls, 0);
    expect(await readLogs(), isEmpty);
  });

  testWidgets('原生通道缺失时携带真实文件内容进入备用面板，并持久化异常', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    final print = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {};
    try {
      final outcome = await tester.runAsync(
        () => ShareUtils.saveFile(XFile(source.path)),
      );
      expect(outcome!.shared, isTrue);
    } finally {
      debugPrint = print;
    }
    expect(picker.calls, 1);
    expect(picker.bytes, source.readAsBytesSync());
    expect(paths.calls, 0);
    final warning = (await tester.runAsync(readLogs))!.single;
    expect(warning['level'], 'warning');
    expect(warning['stage'], 'nativeSaveAs');
    expect(warning['errorType'], 'MissingPluginException');
    expect(warning['sourcePath'], source.path);
    expect(warning['stackTrace'], isNotEmpty);
  });

  testWidgets('原生及备用面板都失败时显示错误，异常进入正式版日志', (tester) async {
    nativeError = PlatformException(code: 'NO_VIEW_CONTROLLER');
    picker.error = PlatformException(code: 'SAVE_FAILED');
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    final outcome = await tester.runAsync(
      () => ShareUtils.saveFile(XFile(source.path)),
    );
    expect(outcome!.shared, isFalse);
    await tester.pumpAndSettle();
    expect(find.text(S.current.share_saveFailed), findsOneWidget);
    final entries = await tester.runAsync(readLogs);
    expect(entries!.map((entry) => entry['stage']), [
      'nativeSaveAs',
      'pickerSaveAs',
    ]);
    expect(entries.map((entry) => entry['platformCode']), [
      'NO_VIEW_CONTROLLER',
      'SAVE_FAILED',
    ]);
    expect(entries.last['level'], 'error');
    expect(entries.last['stackTrace'], isNotEmpty);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
  });

  test('Android 保留公共下载目录保存及 content URI 返回', () async {
    PublicFileChannel.debugPlatformOverride = TargetPlatform.android;
    nativeResult = {
      'uri': 'content://downloads/log',
      'displayName': '日志.jsonl',
    };
    final outcome = await ShareUtils.saveFile(XFile(source.path));
    expect(nativeCalls, ['saveToDownloads']);
    expect(outcome.isContentUri, isTrue);
    expect(outcome.displayName, '日志.jsonl');
    expect(paths.calls, 0);
  });

  test('Android 不支持公共下载目录时保留应用内文件副本', () async {
    PublicFileChannel.debugPlatformOverride = TargetPlatform.android;
    nativeResult = null;
    final outcome = await ShareUtils.saveFile(XFile(source.path));
    expect(outcome.shared, isTrue);
    expect(nativeCalls, ['saveToDownloads']);
    expect(paths.calls, 1);
    expect(
      File(outcome.finalPath!).readAsStringSync(),
      source.readAsStringSync(),
    );
    expect(picker.calls, 0);
  });

  testWidgets('桌面保存仍将文件复制到用户选择的位置', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    PlatformUtils.debugDesktopOverride = true;
    picker.result = p.join(sandbox.path, 'selected.jsonl');
    final outcome = await tester.runAsync(
      () => ShareUtils.saveFile(XFile(source.path)),
    );
    expect(outcome!.finalPath, picker.result);
    expect(File(picker.result!).readAsStringSync(), source.readAsStringSync());
    expect(picker.bytes, isNull);
    expect(nativeCalls, isEmpty);
  });

  test('日志导出文件无法生成时留下独立的生成阶段异常', () async {
    final blocked = Directory(
      p.join(sandbox.path, 'logs', 'app_log_share.jsonl'),
    );
    blocked.createSync();
    await expectLater(
      LoggerUtils.getShareFilePath(),
      throwsA(isA<FileSystemException>()),
    );
    final failure = (await readLogs()).singleWhere(
      (entry) => entry['tag'] == 'LogExport',
    );
    expect(failure['stage'], 'writeExportFile');
    expect(failure['sourcePath'], blocked.path);
    expect(failure['osErrorCode'], isNotNull);
    expect(failure['stackTrace'], isNotEmpty);
    expect(nativeCalls, isEmpty);
  });
}
