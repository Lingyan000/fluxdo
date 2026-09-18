import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/composer_raw_mirror.dart';
import 'package:fluxdo_render/editor.dart';

void main() {
  late TextEditingController controller;
  late ComposerRawMirror mirror;
  late EditorState editor;
  late int externalChanges;

  setUp(() {
    controller = TextEditingController.fromValue(
      const TextEditingValue(
        text: '原文\n\n\n',
        selection: TextSelection(baseOffset: 1, extentOffset: 0),
      ),
    );
    externalChanges = 0;
    mirror = ComposerRawMirror(
      controller,
      onExternalChange: () => externalChanges++,
    );
    editor = EditorState.fromTexts(['原文']);
  });
  tearDown(() {
    mirror.dispose();
    controller.dispose();
    editor.dispose();
  });
  void install() => mirror.install(
    exported: editor.exportMarkdown(),
    revision: editor.docRevision,
  );
  void flush() =>
      mirror.flush(revision: editor.docRevision, export: editor.exportMarkdown);

  test('导入、选区变化、重复 flush 不改原文与有效选区，也不再次导出', () {
    install();
    final original = controller.value;
    editor.updateSelection(
      const EditorSelection.collapsed(
        EditorPosition(blockId: 'e_0', offset: 1),
      ),
    );
    var exports = 0;
    for (var i = 0; i < 3; i++) {
      mirror.flush(
        revision: editor.docRevision,
        export: () {
          exports++;
          return editor.exportMarkdown();
        },
      );
    }
    expect(exports, 0);
    expect(controller.value, original);
  });

  test('真实编辑回写一次，撤销回基线恢复逐字原文与初始选区', () {
    install();
    final original = controller.value;
    var notifications = 0;
    controller.addListener(() => notifications++);
    editor.updateSelection(
      const EditorSelection.collapsed(
        EditorPosition(blockId: 'e_0', offset: 2),
      ),
    );
    editor.insertText('新增');
    flush();
    expect(controller.text, '原文新增');
    flush();
    expect(notifications, 1);
    editor.undo();
    flush();
    expect(controller.value, original);
    expect(externalChanges, 0);
  });

  test('IR 物化增加修订号，但导出基线相同不回写', () {
    editor.dispose();
    editor = EditorState(
      blocks: [
        TextBlock(
          id: 'bold',
          content: EditableTextContent(
            text: '原文',
            marks: const [MarkSpan(start: 0, end: 2, kind: MarkKind.strong)],
          ),
        ),
      ],
    )..mode = EditorMode.ir;
    install();
    final original = controller.value;
    final revision = editor.docRevision;
    editor.updateSelection(
      const EditorSelection.collapsed(
        EditorPosition(blockId: 'bold', offset: 1),
      ),
    );
    expect(editor.docRevision, greaterThan(revision));
    flush();
    expect(controller.value, original);
  });

  test('无效源码选区只修正位置，不规范化原文', () {
    mirror.dispose();
    controller.selection = const TextSelection.collapsed(offset: -1);
    mirror = ComposerRawMirror(
      controller,
      onExternalChange: () => externalChanges++,
    );
    install();
    flush();
    expect(controller.text, '原文\n\n\n');
    expect(controller.selection, const TextSelection.collapsed(offset: 5));
  });

  test('异步导入前外部改写，即使改回也不能安装旧结果', () async {
    final pending = Future<void>(() {
      install();
    });
    controller.text = '新的草稿';
    controller.text = '原文\n\n\n';
    await pending;
    mirror.flush(revision: 100, export: () => '过期文档');
    expect(controller.text, '原文\n\n\n');
    expect(mirror.isCurrent, false);
    expect(externalChanges, 1);
  });

  test('外部改写后旧 flush 不得覆盖；仅外部选区变更不使会话失效', () {
    install();
    controller.selection = const TextSelection.collapsed(offset: 1);
    flush();
    expect(controller.selection.baseOffset, 1);
    expect(mirror.isCurrent, true);
    controller.text = '新的草稿';
    mirror.flush(revision: 100, export: () => '旧内容');
    expect(controller.text, '新的草稿');
    expect(externalChanges, 1);
  });

  test('导出异常保留原文，失败修订不能进入缓存', () {
    install();
    final original = controller.value;
    expect(
      () => mirror.flush(revision: 1, export: () => throw StateError('失败')),
      throwsStateError,
    );
    expect(controller.value, original);
    mirror.flush(revision: 1, export: () => '成功');
    expect(controller.text, '成功');
  });

  testWidgets('切回真实源码输入框保留原文选区且可继续删除', (tester) async {
    install();
    flush();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(controller: controller, maxLines: null)),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(controller.text, '原文\n\n\n');
    controller.selection = const TextSelection.collapsed(offset: 2);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '原\n\n\n',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    expect(controller.text, '原\n\n\n');
    flush();
    expect(controller.text, '原\n\n\n');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('同步监听者外部改写不被后续 flush 当回声覆盖', () {
    install();
    controller.addListener(() {
      if (controller.text == '编辑') controller.text = '宿主替换';
    });
    mirror.flush(revision: 1, export: () => '编辑');
    mirror.flush(revision: 2, export: () => '旧编辑');
    expect(controller.text, '宿主替换');
    expect(externalChanges, 1);
  });
}
