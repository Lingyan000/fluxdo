import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_js_runtime/fluxdo_js_runtime.dart';

Future<JsWorker> createWorker({String? channel, Duration? timeout}) async {
  final worker = await JsWorker.spawn(
    debugName: 'test-js-worker',
    messageChannel: channel,
    timeout: timeout ?? const Duration(seconds: 5),
    stackLimit: 1024 * 1024,
  );
  addTearDown(() async {
    worker.dispose();
    await worker.terminated;
  });
  return worker;
}

void main() {
  test('各实例全局状态独立，同一实例的命令按提交顺序执行', () async {
    final editor = await createWorker();
    final plugin = await createWorker();
    final write = editor.evaluate('globalThis.value = "编辑器"');
    final read = editor.evaluateString('value');
    await write;
    expect(await read, '编辑器');
    expect(await plugin.evaluateString('typeof value'), 'undefined');
    expect(await editor.evaluateString('typeof sendMessage'), 'undefined');
    await expectLater(
      editor.evaluateString('42'),
      throwsA(isA<JsWorkerException>()),
    );
    await expectLater(
      editor.evaluate('throw Error("test")'),
      throwsA(isA<JsWorkerException>()),
    );
    expect(await editor.evaluateString('value'), '编辑器');
  });

  test('只投递已配置通道的 JSON 消息，包含微任务消息', () async {
    final worker = await createWorker(channel: 'test');
    final messages = <Object?>[];
    worker.onMessage = messages.add;
    await worker.evaluate('''
      sendMessage('other', 'false');
      Promise.resolve().then(() => sendMessage('test', '{"ready":true}'));
    ''');
    expect(messages, [
      {'ready': true},
    ]);
    worker.dispose();
    worker.dispose();
    await worker.terminated;
    await expectLater(worker.evaluate('1'), throwsA(isA<JsWorkerException>()));
  });

  test('超时拒绝运行中和排队的请求，不中断其他实例', () async {
    final other = await createWorker();
    final worker = await createWorker(
      timeout: const Duration(milliseconds: 150),
    );
    final fatal = Completer<String>();
    worker.onFatal = fatal.complete;
    await Future.wait([
      expectLater(
        worker.evaluate('while (true) {}'),
        throwsA(isA<JsWorkerException>()),
      ),
      expectLater(worker.evaluate('1'), throwsA(isA<JsWorkerException>())),
    ]);
    expect(await fatal.future, contains('超时'));
    await worker.terminated;
    expect(await other.evaluateString('"ok"'), 'ok');
  });

  test('编辑器真实 bundle 在后台实例生成 HTML 和版本化 token', () async {
    final worker = await createWorker();
    final bundle = await File('assets/cook/discourse-cook.js').readAsString();
    await worker.evaluate(bundle, name: 'discourse-cook.js');
    expect(
      await worker.evaluateString('''__fluxdoCook.init(JSON.stringify({
      siteSettings: {enable_markdown_linkify: true, markdown_linkify_tlds: 'com'},
      site: {categories: [], hashtag_configurations: {}},
      customEmoji: [], baseUri: 'https://example.com'
    }))'''),
      'ok',
    );
    final html = await worker.evaluateString('__fluxdoCook.cook("**你好**")');
    expect(html, contains('<strong>你好</strong>'));
    final dto = jsonDecode(
      await worker.evaluateString('__fluxdoCook.parseForEditor("**你好**")'),
    );
    expect(dto['version'], 1);
    expect(dto['tokens'], isNotEmpty);
    await worker.evaluate('''__fluxdoCook.seedInlineOnebox(
      'https://example.com/deep/path', '链接标题', null)''');
    final linked = await worker.evaluateString(
      '__fluxdoCook.cook("参考 https://example.com/deep/path 这篇")',
    );
    expect(linked, contains('链接标题'));
    expect(linked, isNot(contains('inline-onebox-loading')));
  });
}
