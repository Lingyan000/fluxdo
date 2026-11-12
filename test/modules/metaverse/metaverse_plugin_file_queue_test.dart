import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_file_queue.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_file_service.dart';

void main() {
  final first = Uri.file('/first.fluxplugin');
  final second = Uri.file('/second.fluxplugin');
  late List<Object> errors;
  late MetaversePluginFileQueue queue;
  setUp(() {
    errors = [];
    queue = MetaversePluginFileQueue(onError: (error, _) => errors.add(error));
  });

  test('冷启动等待界面，重复文件去重，确认界面逐个打开', () async {
    queue.add(first);
    queue.add(first);
    queue.add(second);
    expect(queue.pendingCount, 2);
    final opened = <Uri>[];
    final confirmation = Completer<bool>();
    queue.attach((uri) async {
      opened.add(uri);
      return uri == first ? confirmation.future : true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(opened, [first]);
    queue.add(first);
    confirmation.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(opened, [first, second]);
    expect(queue.pendingCount, 0);
    queue.add(first);
    await Future<void>.delayed(Duration.zero);
    expect(opened, [first, second, first]);
  });

  test('界面卸载后保留未确认文件，新导航就绪后继续', () async {
    final opened = <Uri>[];
    queue.add(first);
    queue.attach((_) async => false);
    await Future<void>.delayed(Duration.zero);
    expect(queue.pendingCount, 1);
    queue.attach((uri) async {
      opened.add(uri);
      return true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(opened, [first]);
    expect(queue.pendingCount, 0);
  });

  test('损坏文件失败后继续下一个，错误只报告一次', () async {
    queue.add(first);
    queue.add(second);
    final opened = <Uri>[];
    queue.attach((uri) async {
      opened.add(uri);
      if (uri == first) throw const FormatException('invalid bundle');
      return true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(opened, [first, second]);
    expect(errors, hasLength(1));
    expect(queue.pendingCount, 0);
  });

  test('正在导入时切换导航，旧界面返回不会撤销新处理器', () async {
    final previous = Completer<bool>();
    queue.add(first);
    queue.attach((_) => previous.future);
    queue.detach();
    final opened = <Uri>[];
    queue.attach((uri) async {
      opened.add(uri);
      return true;
    });
    previous.complete(false);
    await Future<void>.delayed(Duration.zero);
    expect(opened, [first]);
    expect(queue.pendingCount, 0);
  });

  test('文件授权在消费或失败后释放，等待新导航时继续保留', () async {
    final released = <Uri>[];
    queue = MetaversePluginFileQueue(
      onError: (error, _) => errors.add(error),
      onConsumed: released.add,
    );
    queue.add(first);
    queue.add(second);
    queue.attach((_) async => false);
    await Future<void>.delayed(Duration.zero);
    expect(released, isEmpty);
    queue.attach((uri) async {
      if (uri == second) throw const FormatException('invalid file');
      return true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(released, [first, second]);
    expect(errors, hasLength(1));
  });

  test('Windows 文件路径保留空格、中文和 URL 保留字符', () {
    const path = r'C:\插件目录\我的 #1.fluxplugin';
    final uri = MetaversePluginFileService.fileArgument(path, windows: true)!;
    expect(uri.toFilePath(windows: true), path);
    expect(uri.hasFragment, isFalse);
    expect(
      MetaversePluginFileService.fileArgument(uri.toString(), windows: true),
      uri,
    );
  });

  test('只接收插件文件，其他启动参数保持原有处理', () {
    for (final value in [
      'multi_window',
      '{"window":1}',
      'https://example.org/a.fluxplugin',
      'fluxdo://topic/1',
      'file:///tmp/other.txt',
      'file:///tmp/a.fluxplugin?x=1',
    ]) {
      expect(
        MetaversePluginFileService.fileArgument(value, windows: true),
        isNull,
      );
    }
    expect(
      MetaversePluginFileService.fileArgument(
        '/tmp/a.FLUXPLUGIN',
        windows: false,
      ),
      Uri.file('/tmp/a.FLUXPLUGIN'),
    );
  });
}
