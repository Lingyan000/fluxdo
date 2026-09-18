import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/uploads/markdown_insertion_anchor.dart';

void main() {
  test('编辑前文后锚点跟随，完成不抢选区', () {
    final controller = TextEditingController(text: '前文后文')
      ..selection = const TextSelection.collapsed(offset: 2);
    final anchors = MarkdownInsertionAnchors(controller);
    final anchor = anchors.capture();
    controller.value = const TextEditingValue(
      text: '新增前文后文',
      selection: TextSelection(baseOffset: 5, extentOffset: 6),
    );
    anchors.insertBlock(anchor, '图片');
    expect(controller.text, '新增前文\n图片\n后文');
    expect(
      controller.selection,
      const TextSelection(baseOffset: 9, extentOffset: 10),
    );
    anchors.dispose();
    controller.dispose();
  });

  test('批量倒序完成仍按选择顺序插入且正文无占位符', () {
    final controller = TextEditingController(text: '后文')
      ..selection = const TextSelection.collapsed(offset: 0);
    final anchors = MarkdownInsertionAnchors(controller);
    final first = anchors.capture();
    final second = anchors.fork(first);
    final third = anchors.fork(first);
    expect(controller.text, '后文');
    anchors.insertBlock(third, '三');
    anchors.insertBlock(first, '一');
    anchors.insertBlock(second, '二');
    expect(controller.text, '一\n二\n三\n后文');
    expect(controller.selection.baseOffset, 0);
    anchors.dispose();
    controller.dispose();
  });

  test('删除跨越锚点后安全折叠，无效选区保留，销毁后不插入', () {
    final controller = TextEditingController(text: 'abcdef')
      ..selection = const TextSelection.collapsed(offset: 3);
    final anchors = MarkdownInsertionAnchors(controller);
    final anchor = anchors.capture();
    controller.text = 'af';
    anchors.insertBlock(anchor, '附件');
    expect(controller.text, 'a\n附件\nf');
    expect(controller.selection.isValid, false);
    final lateAnchor = anchors.capture();
    anchors.dispose();
    anchors.insertBlock(lateAnchor, '忽略');
    expect(controller.text, 'a\n附件\nf');
    controller.dispose();
  });
}
