import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/composer_import_pipeline.dart';

void main() {
  test('token 门禁诊断不改变拒绝结果', () async {
    final differences = <(String, String)>[];
    final pipeline = ComposerTokenImportPipeline<String>(
      cook: (raw) => raw == '模拟输入' ? '<p>甲</p>' : '<p>乙</p>',
      parseForEditor: (_) => {'version': 1, 'tokens': <Object>[]},
      convert: (_, _) => '模拟文档',
      serialize: (_) => '模拟回写',
      emptyDocument: () => '',
      onMismatch: (original, returned) => differences.add((original, returned)),
    );
    final result = await pipeline.import(
      '模拟输入',
      timeout: const Duration(seconds: 1),
      guarded: true,
    );
    expect(result.failure, ComposerImportFailure.mismatch);
    expect(result.document, isNull);
    expect(differences, [('<p>甲</p>', '<p>乙</p>')]);
  });

  const cooked = {'version': 1, 'tokens': <Object>[]};
  late List<String> calls;

  ComposerTokenImportPipeline<List<String>> pipeline({
    String? fail,
    String? unavailable,
    String? hang,
    String back = '<p>正文</p>',
    Duration delay = Duration.zero,
  }) {
    Future<T> step<T>(String name, T value) async {
      calls.add(name);
      if (name == fail) throw StateError('模拟阶段异常');
      if (name == hang) return Completer<T>().future;
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      return value;
    }

    return ComposerTokenImportPipeline(
      cook: (raw) {
        final name = raw == '原文' ? 'original' : 'back';
        return step(
          name,
          unavailable == name
              ? null
              : (name == 'original' ? '<p>正文</p>' : back),
        );
      },
      parseForEditor: (_) =>
          step('editor', unavailable == 'editor' ? null : cooked),
      convert: (raw, dto) {
        expect(raw, '原文');
        expect(dto, cooked);
        return step('convert', unavailable == 'convert' ? null : ['文档']);
      },
      serialize: (doc) {
        expect(doc, ['文档']);
        return step('serialize', '回写');
      },
      emptyDocument: () => step('empty', ['空文档']),
    );
  }

  setUp(() => calls = []);

  test('完整门禁路径和原文 token 传递', () async {
    final result = await pipeline().import(
      '原文',
      timeout: const Duration(seconds: 1),
      guarded: true,
    );
    expect(result.document, ['文档']);
    expect(result.failure, isNull);
    expect(calls, ['original', 'editor', 'convert', 'serialize', 'back']);
  });

  test('普通导入不序列化或运行门禁', () async {
    final result = await pipeline().import(
      '原文',
      timeout: const Duration(seconds: 1),
    );
    expect(result.document, ['文档']);
    expect(calls, ['editor', 'convert']);
  });

  for (final stage in ['original', 'editor', 'convert', 'serialize', 'back']) {
    test('$stage 异常安全降级并停止后续阶段', () async {
      final result = await pipeline(fail: stage)
          .import('原文', timeout: const Duration(seconds: 1), guarded: true);
      expect(result.document, isNull);
      expect(result.failure, ComposerImportFailure.exception);
      expect(calls.last, stage);
    });
    test('$stage 挂起受整体预算约束', () async {
      final result = await pipeline(
        hang: stage,
      ).import('原文', timeout: const Duration(milliseconds: 30), guarded: true);
      expect(result.document, isNull);
      expect(result.failure, ComposerImportFailure.timeout);
      expect(calls.last, stage);
    });
  }

  for (final stage in ['original', 'editor', 'back']) {
    test('$stage 返回 null 安全降级', () async {
      final result = await pipeline(unavailable: stage)
          .import('原文', timeout: const Duration(seconds: 1), guarded: true);
      expect(result.document, isNull);
      expect(result.failure, ComposerImportFailure.unavailable);
      expect(calls.last, stage);
    });
  }

  test('语义转换不支持时拒绝并停止后续阶段', () async {
    final result = await pipeline(unavailable: 'convert')
        .import('原文', timeout: const Duration(seconds: 1), guarded: true);
    expect(result.document, isNull);
    expect(result.failure, ComposerImportFailure.unsupported);
    expect(calls.last, 'convert');
  });

  for (final changed in [
    '<p> 正文</p>',
    '<p>正文</p>\n',
    '<pre><code>  x\n\n y\n</code></pre>',
  ]) {
    test('输出差异不泛化归一化：${changed.length}', () async {
      final result = await pipeline(back: changed)
          .import('原文', timeout: const Duration(seconds: 1), guarded: true);
      expect(result.failure, ComposerImportFailure.mismatch);
    });
  }

  for (final changed in [
    '<pre><code>x\ny</code></pre>',
    '<pre><code>  x\ny</code></pre>',
  ]) {
    test('代码缩进或空行丢失不得通过：${changed.length}', () async {
      var count = 0;
      final p = ComposerTokenImportPipeline<String>(
        cook: (_) =>
            ++count == 1 ? '<pre><code>  x\n\ny</code></pre>' : changed,
        parseForEditor: (_) => cooked,
        convert: (_, _) => '文档',
        serialize: (_) => '回写',
        emptyDocument: () => '',
      );
      expect(
        (await p.import(
          '原文',
          timeout: const Duration(seconds: 1),
          guarded: true,
        )).failure,
        ComposerImportFailure.mismatch,
      );
    });
  }

  test('预算不能在各阶段重置，超时后不再启动下一阶段', () async {
    final result = await pipeline(
      delay: const Duration(milliseconds: 40),
    ).import('原文', timeout: const Duration(milliseconds: 100), guarded: true);
    expect(result.failure, ComposerImportFailure.timeout);
    final snapshot = List<String>.of(calls);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(calls, snapshot);
    expect(calls, isNot(contains('serialize')));
  });

  test('空白输入不调用引擎；空文档转换异常同样捕获', () async {
    expect(
      (await pipeline().import(
        ' \n',
        timeout: const Duration(seconds: 1),
      )).document,
      ['空文档'],
    );
    expect(calls, ['empty']);
    expect(
      (await pipeline(
        fail: 'empty',
      ).import('', timeout: const Duration(seconds: 1))).failure,
      ComposerImportFailure.exception,
    );
  });

  test('预算耗尽不启动任何阶段', () async {
    expect(
      (await pipeline().import(
        '原文',
        timeout: Duration.zero,
        guarded: true,
      )).failure,
      ComposerImportFailure.timeout,
    );
    expect(calls, isEmpty);
  });
}
