import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/log/plugin_log_store.dart';
import 'package:fluxdo/services/log/log_policy.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plugin_log_isolation_');
    await LogWriter.initForTesting(directory);
  });

  tearDown(() async {
    await LogWriter.resetForTesting();
    await directory.delete(recursive: true);
  });

  test('插件独立轮转，密集输出保留其他插件和应用日志', () async {
    LogWriter.instance.write({'message': 'app-retained'});
    LogWriter.instance.write({
      'pluginId': 'quiet',
      'message': 'quiet-retained',
    });
    await LogWriter.instance.flushNow();
    for (var batch = 0; batch < 30; batch++) {
      for (var row = 0; row < 50; row++) {
        LogWriter.instance.write({
          'pluginId': 'noisy',
          'message': 'batch-$batch-row-$row-${'x' * 1000}',
        });
      }
      await LogWriter.instance.flushNow();
    }
    expect(
      await LogWriter.readPluginContent('quiet'),
      contains('quiet-retained'),
    );
    expect(
      await (await LogWriter.getLogFile()).readAsString(),
      contains('app-retained'),
    );
    expect(
      await (await LogWriter.getLogFile()).readAsString(),
      isNot(contains('batch-')),
    );
    final noisy = await LogWriter.readPluginContent('noisy');
    expect(noisy, contains('batch-29-row-49'));
    expect(noisy, isNot(contains('batch-0-row-0-')));
    final files = await Directory('${directory.path}/plugins')
        .list()
        .where((file) => file is File)
        .cast<File>()
        .toList();
    expect(files, hasLength(3));
    for (final file in files) {
      expect(
        await file.length(),
        lessThanOrEqualTo(PluginLogStore.maxFileBytes),
      );
    }
    final combined = await LogWriter.readAllContent();
    expect(combined, contains('app-retained'));
    expect(combined, contains('quiet-retained'));
    expect(combined, contains('batch-29-row-49'));
  });

  test('每插件缓冲独立，超额汇总具有明确归属', () async {
    LogWriter.instance.write({'pluginId': 'quiet', 'message': 'preserved'});
    LogWriter.instance.write({'message': 'app-preserved'});
    for (var index = 0; index < 1000; index++) {
      LogWriter.instance.write({
        'pluginId': 'noisy',
        'message': 'line-$index-${'x' * 400}',
      });
    }
    await LogWriter.instance.flushNow();
    expect(await LogWriter.readPluginContent('quiet'), contains('preserved'));
    expect(await LogWriter.readAllContent(), contains('app-preserved'));
    final rows = const LineSplitter()
        .convert(await LogWriter.readPluginContent('noisy'))
        .map((line) => jsonDecode(line) as Map)
        .toList();
    final summary = rows.singleWhere(
      (row) => row['event'] == 'plugin_log_overflow',
    );
    expect(summary['pluginId'], 'noisy');
    expect(summary['emitter'], 'framework');
    expect(summary['dropped'], greaterThan(0));
    expect(rows.last['message'], '插件日志缓冲超限，丢弃最旧记录');
  });

  test('兼容旧共享记录，清空与晚到写入通过同一队列', () async {
    final legacy = await LogWriter.getLogFile();
    await legacy.writeAsString(
      '${jsonEncode({'pluginId': 'one', 'message': 'legacy', 'sessionId': 'old'})}\n',
      mode: FileMode.append,
    );
    expect(await LogWriter.readPluginContent('one'), contains('legacy'));
    LogWriter.instance.write({'pluginId': 'one', 'message': 'old-current'});
    LogWriter.instance.write({'pluginId': 'two', 'message': 'retained'});
    final flushing = LogWriter.instance.flushNow();
    final clearing = LogWriter.instance.clearPlugin('one');
    LogWriter.instance.write({'pluginId': 'one', 'message': 'after-clear'});
    await Future.wait([flushing, clearing]);
    final rows = const LineSplitter().convert(
      await LogWriter.readPluginContent('one'),
    );
    expect(rows, hasLength(1));
    expect(jsonDecode(rows.single)['message'], 'after-clear');
    expect(await LogWriter.readPluginContent('two'), contains('retained'));
    await LogWriter.initForTesting(directory);
    expect(await LogWriter.readPluginContent('one'), contains('after-clear'));
    final clearingAll = LogWriter.instance.clearAll();
    LogWriter.instance.write({'pluginId': 'one', 'message': 'new-session'});
    await clearingAll;
    expect(await LogWriter.readPluginContent('two'), isEmpty);
    expect(await LogWriter.readPluginContent('one'), contains('new-session'));
  });

  test('文件名使用摘要，过期分区在启动时清理', () async {
    LogWriter.instance.write({
      'pluginId': '../outside',
      'message': 'bounded-path',
    });
    await LogWriter.instance.flushNow();
    final files = await Directory('${directory.path}/plugins')
        .list()
        .where((file) => file is File)
        .cast<File>()
        .toList();
    expect(files, hasLength(1));
    expect(
      files.single.uri.pathSegments.last,
      matches(RegExp(r'^[a-f0-9]{64}\.jsonl$')),
    );
    await files.single.setLastModified(
      DateTime.now().subtract(const Duration(days: 15)),
    );
    await LogWriter.initForTesting(directory);
    expect(await LogWriter.readPluginContent('../outside'), isEmpty);
  });

  test('轮转批次晚生成的超限汇总仍属于清空前的记录', () async {
    final store = PluginLogStore();
    await store.initialize(directory);
    store.append(
      LogPolicy.normalize({'pluginId': 'first', 'message': 'first'}),
    );
    for (var index = 0; index < 300; index++) {
      store.append(
        LogPolicy.normalize({'pluginId': 'second', 'message': 'row-$index'}),
      );
    }
    // 第一分区首次 IO 挂起后，第二分区尚未生成汇总。
    final flushing = store.flush();
    final cutoff = LogPolicy.sequence;
    await flushing;
    final rows = const LineSplitter()
        .convert(await store.read(pluginId: 'second'))
        .map((line) => jsonDecode(line) as Map)
        .toList();
    expect(
      rows.singleWhere((row) => row['event'] == 'plugin_log_overflow')['seq'],
      lessThanOrEqualTo(cutoff),
    );
    await store.clearFiles(
      pluginId: 'second',
      keep: (line) => (jsonDecode(line)['seq'] as int) > cutoff,
    );
    expect(await store.read(pluginId: 'second'), isEmpty);
    expect(await store.read(pluginId: 'first'), isNotEmpty);
  });

  test('全部清空覆盖损坏行，保留异步落盘期间产生的应用与插件记录', () async {
    await (await LogWriter.getLogFile()).writeAsString(
      'damaged-json\n',
      mode: FileMode.append,
    );
    LogWriter.instance.write({'pluginId': 'one', 'message': 'plugin-old'});
    LogWriter.instance.write({'message': 'app-old'});
    final flushing = LogWriter.instance.flushNow();
    await Future<void>.value();
    final clearing = LogWriter.instance.clearAll();
    LogWriter.instance.write({'message': 'app-fresh'});
    LogWriter.instance.write({'pluginId': 'one', 'message': 'plugin-fresh'});
    await Future.wait([flushing, clearing]);
    final content = await LogWriter.readAllContent();
    expect(content, isNot(contains('damaged-json')));
    expect(content, isNot(contains('-old')));
    expect(content, contains('app-fresh'));
    expect(content, contains('plugin-fresh'));
  });
}
