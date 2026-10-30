import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  testWidgets('引用图片占位和完成图片均留在同一个引用容器内', (tester) async {
    final editor = EditorState.fromTexts(['前文后文']);
    addTearDown(editor.dispose);
    final id = editor.blocks.first.id;
    editor.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: id, offset: 2)),
    );
    editor.toggleQuote();
    final host = editor.blocks.first as TextBlock;
    final pending = TextBlock(
      id: 'pending',
      content: EditableTextContent.empty,
      containers: host.containers,
    );
    final tail = TextBlock(
      id: 'tail',
      content: EditableTextContent(text: '后文'),
      containers: host.containers,
    );
    editor.replaceBlockRange(0, 0, [
      host.copyWith(content: EditableTextContent(text: '前文')),
      pending,
      tail,
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FluxdoEditor(
              state: editor,
              transientBlockBuilder: (context, block) => block.id == 'pending'
                  ? const SizedBox(
                      key: ValueKey('upload-card'),
                      height: 50,
                      child: Text('上传中'),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    Finder shells() => find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('shell_'),
    );
    expect(shells(), findsOneWidget);
    expect(
      find.descendant(
        of: shells(),
        matching: find.byKey(const ValueKey('upload-card')),
      ),
      findsOneWidget,
    );
    editor.replaceBlockRange(1, 1, [
      TextBlock(
        id: 'image',
        containers: pending.containers,
        content: EditableTextContent.fromInlines([
          const ImageRun(src: 'upload://image.png', alt: '图片'),
        ]),
      ),
    ]);
    await tester.pump();
    expect(shells(), findsOneWidget);
    final raw = editor.exportMarkdown();
    expect(raw, contains('> ![图片]'));
    expect(raw, contains('> 前文'));
    expect(raw, contains('> 后文'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
