import 'dart:async';

import 'package:fluxdo/l10n/s.dart';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:fluxdo/widgets/markdown_editor/uploads/upload_task_panel.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/widgets/markdown_editor/uploads/task_controller.dart';

UploadResult result() =>
    UploadResult(shortUrl: 'upload://example', originalFilename: '图片.png');

UploadTaskRequest request(UploadExecutor execute) => UploadTaskRequest(
  path: '/private/图片.png',
  name: '图片.png',
  isImage: true,
  execute: execute,
);

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  testWidgets('聊天上传条固定高度，完成仍保留附件且可移除', (tester) async {
    final controller = UploadTaskController();
    addTearDown(controller.dispose);
    controller.add(request((_, _) async => result()));
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 320,
                child: ChatUploadStrip(controller: controller),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(ChatUploadStrip)).height, 88);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(controller.tasks, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空任务和全部成功任务不占面板空间', (tester) async {
    final controller = UploadTaskController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: UploadTaskPanel(controller: controller)),
    );
    expect(find.byType(ListTile), findsNothing);
    controller.add(request((_, _) async => result()));
    await tester.pump();
    expect(find.byType(ListTile), findsNothing);
    controller.clearSucceeded();
    expect(controller.tasks, isEmpty);
  });
  test('单任务回调覆盖默认回调且仅交付一次', () async {
    var defaultCalls = 0;
    var taskCalls = 0;
    final controller = UploadTaskController(
      onCompleted: (_, _) => defaultCalls++,
    );
    addTearDown(controller.dispose);
    final id = controller.add(
      UploadTaskRequest(
        path: '/private/文件',
        name: '文件',
        execute: (_, _) async => result(),
        onCompleted: (_, _) => taskCalls++,
      ),
    );
    await settle();
    controller.retry(id);
    expect(defaultCalls, 0);
    expect(taskCalls, 1);
  });

  test('整批预注册，成功结果仅交付一次', () async {
    var delivered = 0;
    final controller = UploadTaskController(onCompleted: (_, _) => delivered++);
    addTearDown(controller.dispose);
    final pending = <Completer<UploadResult>>[];
    final ids = controller.addBatch(
      List.generate(
        3,
        (_) => request((token, progress) {
          expect(controller.tasks.length, 3);
          final completer = Completer<UploadResult>();
          pending.add(completer);
          return completer.future;
        }),
      ),
    );
    expect(controller.hasPending, isTrue);
    for (final completer in pending) {
      completer.complete(result());
    }
    await settle();
    expect(delivered, 3);
    expect(controller.hasPending, isFalse);
    for (final id in ids) {
      controller.retry(id);
    }
    expect(delivered, 3);
    expect(pending.length, 3);
  });

  test('失败仍pending，重试保留id且使用新token', () async {
    final tokens = <CancelToken>[];
    var attempts = 0;
    var delivered = 0;
    final controller = UploadTaskController(onCompleted: (_, _) => delivered++);
    addTearDown(controller.dispose);
    final id = controller.add(
      request((token, progress) async {
        tokens.add(token);
        if (++attempts == 1) throw StateError('模拟失败');
        return result();
      }),
    );
    await settle();
    expect(controller.tasks.single.phase, UploadTaskPhase.failed);
    expect(controller.hasPending, isTrue);
    controller.retry(id);
    await settle();
    expect(controller.tasks.single.id, id);
    expect(identical(tokens[0], tokens[1]), isFalse);
    expect(delivered, 1);
    expect(controller.hasPending, isFalse);
  });

  test('取消后重试忽略旧进度和迟到结果', () async {
    final pending = <Completer<UploadResult>>[];
    final tokens = <CancelToken>[];
    final callbacks = <UploadProgressCallback>[];
    var delivered = 0;
    final controller = UploadTaskController(onCompleted: (_, _) => delivered++);
    addTearDown(controller.dispose);
    final id = controller.add(
      request((token, progress) {
        tokens.add(token);
        callbacks.add(progress);
        final completer = Completer<UploadResult>();
        pending.add(completer);
        return completer.future;
      }),
    );
    controller.cancel(id);
    expect(tokens.first.isCancelled, isTrue);
    expect(controller.hasPending, isFalse);
    controller.retry(id);
    callbacks.first(
      const UploadProgress(
        phase: UploadPhase.uploading,
        sentBytes: 99,
        totalBytes: 100,
      ),
    );
    expect(controller.tasks.single.progress, isNull);
    pending.first.complete(result());
    await settle();
    expect(delivered, 0);
    expect(controller.tasks.single.phase, UploadTaskPhase.uploading);
    pending.last.complete(result());
    await settle();
    expect(delivered, 1);
  });

  for (final dispose in [false, true]) {
    test('${dispose ? '销毁' : '移除'}取消传输并阻止迟到插入', () async {
      final completer = Completer<UploadResult>();
      late CancelToken token;
      var delivered = 0;
      final controller = UploadTaskController(
        onCompleted: (_, _) => delivered++,
      );
      final id = controller.add(
        request((t, _) {
          token = t;
          return completer.future;
        }),
      );
      if (dispose) {
        controller.dispose();
      } else {
        controller.remove(id);
      }
      expect(token.isCancelled, isTrue);
      completer.complete(result());
      await settle();
      expect(delivered, 0);
      expect(controller.tasks, isEmpty);
      if (!dispose) controller.dispose();
    });
  }

  test('插入前处理通知中的删除也能阻止插入', () async {
    var delivered = 0;
    final controller = UploadTaskController(onCompleted: (_, _) => delivered++);
    addTearDown(controller.dispose);
    controller.addListener(() {
      for (final task in controller.tasks) {
        if (task.progress?.phase == UploadPhase.processing) {
          controller.remove(task.id);
        }
      }
    });
    controller.add(request((_, _) async => result()));
    await settle();
    expect(delivered, 0);
  });

  test('插入失败重试复用服务端结果，不重复上传', () async {
    var uploads = 0;
    var inserts = 0;
    final controller = UploadTaskController(
      onCompleted: (_, _) async {
        if (++inserts == 1) throw StateError('转换失败');
      },
    );
    addTearDown(controller.dispose);
    final id = controller.add(
      request((_, _) async {
        uploads++;
        return result();
      }),
    );
    await settle();
    expect(controller.hasPending, true);
    controller.retry(id);
    await settle();
    expect(uploads, 1);
    expect(inserts, 2);
    expect(controller.hasPending, false);
  });

  test('预注册通知取消任务后不会启动执行器', () {
    final controller = UploadTaskController();
    addTearDown(controller.dispose);
    controller.addListener(() {
      for (final task in controller.tasks) {
        if (task.phase == UploadTaskPhase.queued) controller.cancel(task.id);
      }
    });
    controller.add(
      request((_, _) {
        fail('取消任务不应启动');
      }),
    );
    expect(controller.tasks.single.phase, UploadTaskPhase.cancelled);
  });

  test('不同编辑器的控制器互不影响', () async {
    final first = UploadTaskController();
    final second = UploadTaskController();
    addTearDown(second.dispose);
    first.add(request((_, _) => Completer<UploadResult>().future));
    second.add(request((_, _) async => result()));
    first.dispose();
    await settle();
    expect(second.tasks.single.phase, UploadTaskPhase.succeeded);
  });
}
