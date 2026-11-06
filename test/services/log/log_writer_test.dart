import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_writer.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('log_writer_test');
  });

  tearDown(() async {
    await LogWriter.resetForTesting();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<List<Map<String, dynamic>>> readEntries(File file) async {
    if (!file.existsSync()) return [];
    final content = await file.readAsString();
    return content
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
  }

  test('重复无关联事件汇总，请求身份不同则保留', () async {
    await LogWriter.initForTesting(tempDir);
    for (var i = 0; i < 100; i++) {
      LogWriter.instance.write({'level': 'warning', 'message': 'same'});
    }
    LogWriter.instance.write({
      'level': 'info',
      'message': 'request',
      'coreRequestId': 1,
    });
    LogWriter.instance.write({
      'level': 'info',
      'message': 'request',
      'coreRequestId': 2,
    });
    await LogWriter.instance.flushNow();
    final rows = await readEntries(await LogWriter.getLogFile());
    expect(
      rows.where(
        (e) => e['message'] == 'same' && e['event'] != 'repeat_summary',
      ),
      hasLength(1),
    );
    expect(
      rows.singleWhere((e) => e['event'] == 'repeat_summary')['suppressed'],
      99,
    );
    expect(rows.where((e) => e['coreRequestId'] != null), hasLength(2));
  });

  test('write 进缓冲，flushNow 后落盘并注入 appVersion', () async {
    await LogWriter.initForTesting(tempDir, appVersion: '1.0.0+1');

    LogWriter.instance.write({
      'timestamp': '2026-06-13T00:00:00.000',
      'level': 'info',
      'type': 'general',
      'message': 'hello',
    });

    final file = await LogWriter.getLogFile();
    // 缓冲尚未落盘
    expect(
      !file.existsSync() || (await file.readAsString()).isEmpty,
      isTrue,
      reason: 'info 级日志应先进缓冲',
    );

    await LogWriter.instance.flushNow();
    final entries = await readEntries(file);
    expect(entries, hasLength(1));
    expect(entries.single['message'], 'hello');
    expect(entries.single['appVersion'], '1.0.0+1');
  });

  test('error 级日志立即落盘', () async {
    await LogWriter.initForTesting(tempDir);

    LogWriter.instance.write({
      'timestamp': '2026-06-13T00:00:00.000',
      'level': 'error',
      'type': 'general',
      'message': 'boom',
    });
    // error 触发的 flush 是异步排队的，等待 io 链完成
    await LogWriter.instance.flushNow();

    final entries = await readEntries(await LogWriter.getLogFile());
    expect(entries, hasLength(1));
    expect(entries.single['level'], 'error');
  });

  test('debug 级日志默认不落盘，verbose 开启后落盘', () async {
    await LogWriter.initForTesting(tempDir);

    LogWriter.instance.write({'level': 'debug', 'message': 'noisy'});
    await LogWriter.instance.flushNow();
    expect(await readEntries(await LogWriter.getLogFile()), isEmpty);

    LogWriter.verboseEnabled = true;
    LogWriter.instance.write({'level': 'debug', 'message': 'noisy'});
    await LogWriter.instance.flushNow();
    final entries = await readEntries(await LogWriter.getLogFile());
    expect(entries, hasLength(1));
    expect(entries.single['message'], 'noisy');
  });

  test('超过大小上限时轮换为 .1 文件且不丢日志', () async {
    await LogWriter.initForTesting(tempDir);
    LogWriter.maxFileSizeForTesting = 1024;

    // 每条约 120 字节，写到触发至少一次轮换
    for (var i = 0; i < 30; i++) {
      LogWriter.instance.write({
        'level': 'info',
        'message': 'entry-$i-${'x' * 80}',
      });
      await LogWriter.instance.flushNow();
    }

    final current = await LogWriter.getLogFile();
    final rotated = await LogWriter.getRotatedLogFile();
    expect(rotated.existsSync(), isTrue, reason: '应产生轮换文件');
    expect(await current.length(), lessThan(1024 + 200));

    // readAllContent 拼接两代，最后一条一定在
    final all = await LogWriter.readAllContent();
    expect(all, contains('entry-29'));
  });

  test('clearAll 清空两代文件后可继续写入', () async {
    await LogWriter.initForTesting(tempDir);
    LogWriter.maxFileSizeForTesting = 512;

    for (var i = 0; i < 10; i++) {
      LogWriter.instance.write({
        'level': 'info',
        'message': 'old-$i-${'y' * 80}',
      });
      await LogWriter.instance.flushNow();
    }
    await LogWriter.instance.clearAll();

    expect(await LogWriter.readAllContent(), isEmpty);

    LogWriter.instance.write({'level': 'info', 'message': 'fresh'});
    await LogWriter.instance.flushNow();
    expect(await LogWriter.readAllContent(), contains('fresh'));
  });

  test('readContentSafely 容忍非法 utf-8 字节', () async {
    final file = File('${tempDir.path}/bad.jsonl');
    await file.writeAsBytes([
      ...utf8.encode('{"message":"ok"}\n'),
      0xFF,
      0xFE,
      ...utf8.encode('\n{"message":"after"}\n'),
    ]);

    final content = await LogWriter.readContentSafely(file);
    expect(content, contains('"ok"'));
    expect(content, contains('"after"'));
  });
}
