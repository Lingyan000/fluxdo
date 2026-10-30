import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/semantic_editor.dart';
import 'package:fluxdo_render/src/editor/widget/editable_paragraph.dart';

import '../../helpers/discourse_cook_node.dart';

void main() {
  for (final mode in EditorMode.values) {
    for (final newline in ['\n', '  \n']) {
      testWidgets('打开链接加下一行正文后可定位、输入和恢复：$mode/${newline.length}', (
        tester,
      ) async {
        const url = 'https://github.com/mock-user/mock-project';
        const tail = '模拟正文';
        final codec = SemanticComposerCodec(
          cook: cookWithNode,
          tokenize: parseWithNode,
        );
        final result = await tester.runAsync(
          () => codec.import('$url$newline$tail'),
        );
        expect(result!.failure, isNull);
        final session = SemanticEditorSession(result.document!);
        addTearDown(session.dispose);
        session.editor.mode = mode;
        final block = session.editor.blocks.whereType<TextBlock>().first;
        expect(block.content.text, '$url\n$tail');
        expect(block.content.atoms, isEmpty);
        expect(block.content.marks.single.isAutoLink, isTrue);
        expect(codec.export(session.exportTree()), '$url$newline$tail');

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 375,
                  child: FluxdoEditor(state: session.editor, autofocus: true),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final paragraphFinder = find
            .descendant(
              of: find.byType(EditableParagraph).first,
              matching: find.byType(RichText),
            )
            .first;
        for (final expected in [
          url.indexOf('mock-user') + 4,
          url.length + 1 + tail.length,
          url.length + 3,
        ]) {
          final paragraph = tester.renderObject<RenderParagraph>(
            paragraphFinder,
          );
          final rendered = paragraph.text.toPlainText();
          // 渲染器会在长 URL 中插入零宽换行点，它们不占编辑坐标。
          expect(rendered.replaceAll('\u200b', ''), '$url\n$tail');
          final positions = [
            for (var i = 0; i < rendered.length; i++)
              if (rendered[i] != '\u200b') i,
            rendered.length,
          ];
          final point = paragraph.getOffsetForCaret(
            TextPosition(offset: positions[expected]),
            Rect.zero,
          );
          await tester.tapAt(
            paragraph.localToGlobal(point + const Offset(0, 8)),
          );
          await tester.pump(const Duration(milliseconds: 600));
          expect(session.editor.selection!.isCollapsed, isTrue);
          expect(session.editor.selection!.extent.offset, expected);
        }

        final platform = tester.testTextInput.editingState!;
        final value = TextEditingValue.fromJSON(platform);
        final offset = value.selection.extentOffset;
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: value.text.replaceRange(offset, offset, '新增'),
            selection: TextSelection.collapsed(offset: offset + 2),
          ),
        );
        await tester.pump();
        const editedTail = '模拟新增正文';
        expect(
          (session.editor.blocks.first as TextBlock).content.text,
          '$url\n$editedTail',
        );
        final exported = codec.export(session.exportTree());
        final reopened = await tester.runAsync(() => codec.import(exported));
        expect(reopened!.failure, isNull);
        final restored = SemanticEditorSession(reopened.document!);
        addTearDown(restored.dispose);
        expect(
          (restored.editor.blocks.first as TextBlock).content.text,
          '$url\n$editedTail',
        );
        session.editor.undo();
        expect(codec.export(session.exportTree()), '$url$newline$tail');
      });
    }
  }
}
