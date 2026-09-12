/// 富文本工具注册表 + pin 机制。
///
/// 富文本原来 13 个工具全硬编码在横滚条里、无面板无自定义；这套注册表
/// 让它与源码模式机制对齐（外显 pin + 「更多」面板网格）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_editor_tools.dart';

EditorState _makeState() => EditorState.fromTexts(const ['第一段']);

void _caret(EditorState s, int offset) {
  final id = s.blocks.first.id;
  s.updateSelection(
    EditorSelection.collapsed(EditorPosition(blockId: id, offset: offset)),
  );
}

RichToolContext _ctx(
  EditorState state, {
  VoidCallback? onLink,
  VoidCallback? onImage,
  VoidCallback? onSpoiler,
  ValueChanged<int>? onHeading,
}) => RichToolContext(
  state: state,
  onInsertLink: onLink ?? () {},
  onPickImage: onImage ?? () {},
  onToggleInlineSpoiler: onSpoiler ?? () {},
  onSetHeading: onHeading ?? (_) {},
);

RichToolSnapshot _snap(EditorState s) {
  final sel = s.selection;
  final block = sel == null ? null : s.textBlockById(sel.extent.blockId);
  return RichToolSnapshot(
    marks: s.effectiveMarksAtCaret(),
    headingLevel: block?.isHeading == true ? block!.headingLevel : 0,
    isListItem: block?.isListItem ?? false,
    ordered: block?.isListItem == true && block!.ordered,
    inQuote: (block?.quoteDepth ?? 0) > 0,
  );
}

RichEditorTool _tool(String id) =>
    richEditorTools.firstWhere((t) => t.id == id);

void main() {
  test('注册表 id 唯一', () {
    final ids = richEditorTools.map((t) => t.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('默认外显工具都在注册表里', () {
    final ids = richEditorTools.map((t) => t.id).toSet();
    for (final id in kDefaultRichVisibleTools) {
      expect(ids, contains(id), reason: '$id 不在注册表中');
    }
  });

  test('resolveVisibleRichTools 保留用户固定顺序', () {
    // 故意乱序传入，结果应按注册表顺序
    final got = resolveVisibleRichTools(['link', 'bold', 'italic']);
    expect(got.map((t) => t.id).toList(), ['link', 'bold', 'italic']);
  });

  test('resolveVisibleRichTools 忽略未知 id', () {
    final got = resolveVisibleRichTools(['bold', 'nope']);
    expect(got.map((t) => t.id).toList(), ['bold']);
  });

  group('工具动作真的改文档', () {
    test('粗体：对选区施加后，光标落回区内激活态为真', () {
      final s = _makeState();
      final id = s.blocks.first.id;
      // 选中「第一段」三个字
      s.updateSelection(
        EditorSelection(
          base: EditorPosition(blockId: id, offset: 0),
          extent: EditorPosition(blockId: id, offset: 3),
        ),
      );
      _tool('bold').run(_ctx(s));

      // 注意：effectiveMarksAtCaret 对非折叠选区按设计返回空集，
      // 所以要把光标折叠进已加粗的区间里再看激活态。
      _caret(s, 2);
      expect(_tool('bold').isActive!(_snap(s)), isTrue);
      expect(_tool('italic').isActive!(_snap(s)), isFalse);
    });

    test('无序列表：切换后块变列表项', () {
      final s = _makeState();
      _caret(s, 0);
      _tool('bulletList').run(_ctx(s));
      final snap = _snap(s);
      expect(snap.isListItem, isTrue);
      expect(snap.ordered, isFalse);
      expect(_tool('bulletList').isActive!(snap), isTrue);
      expect(_tool('numberedList').isActive!(snap), isFalse);
    });

    test('引用：切换后 inQuote 为真', () {
      final s = _makeState();
      _caret(s, 0);
      _tool('quote').run(_ctx(s));
      expect(_tool('quote').isActive!(_snap(s)), isTrue);
    });

    test('标题：转发级别给宿主回调', () {
      final s = _makeState();
      _caret(s, 0);
      final levels = <int>[];
      _tool('heading2').run(_ctx(s, onHeading: levels.add));
      expect(levels, [2]);
    });

    test('链接/图片/剧透：转发给宿主回调（需要弹窗或上传）', () {
      final s = _makeState();
      _caret(s, 0);
      var link = 0, image = 0, spoiler = 0;
      _tool('link').run(_ctx(s, onLink: () => link++));
      _tool('image').run(_ctx(s, onImage: () => image++));
      _tool('spoilerInline').run(_ctx(s, onSpoiler: () => spoiler++));
      expect([link, image, spoiler], [1, 1, 1]);
    });
  });
}
