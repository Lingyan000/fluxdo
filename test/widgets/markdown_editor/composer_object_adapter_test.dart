import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_object_controller.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_object_adapter.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  const nodes = <BlockNode>[
    ParagraphNode(id: 'n', inlines: [TextRun('内容')]),
    HeadingNode(id: 'n', level: 2, inlines: [TextRun('标题')]),
    ListNode(id: 'n', ordered: false, items: []),
    BlockquoteNode(id: 'n', children: []),
    HorizontalRuleNode(id: 'n'),
    BlankLineNode(id: 'n'),
    CodeBlockNode(id: 'n', code: 'x', language: 'dart'),
    CodeBlockNode(id: 'n', code: 'graph TD; A-->B', language: 'mermaid'),
    QuoteCardNode(id: 'n', username: 'tester'),
    SpoilerBlockNode(id: 'n', children: []),
    OneboxNode(
      id: 'n',
      kind: OneboxKind.defaultKind,
      url: 'https://example.com',
    ),
    CalloutNode(id: 'n', kind: CalloutKind.note, typeRaw: 'note'),
    DetailsNode(id: 'n', summary: '详情', children: []),
    ImageGridNode(
      id: 'n',
      images: [ImageRun(src: 'image.png')],
    ),
    FootnotesSectionNode(id: 'n'),
    LazyVideoNode(
      id: 'n',
      provider: LazyVideoProvider.youtube,
      videoId: 'video',
      url: 'https://example.com/video',
    ),
    IframeNode(id: 'n', src: 'https://example.com/embed'),
    VideoNode(id: 'n', src: 'https://example.com/video.mp4'),
    AudioNode(id: 'n', src: 'https://example.com/audio.mp3'),
    TableNode(id: 'n', rows: [], columnCount: 1),
    PolicyNode(id: 'n', children: []),
    MathBlockNode(id: 'n', latex: 'x^2'),
    SvgNode(id: 'n', svgSource: '<svg></svg>'),
    PollNode(id: 'n', pollName: 'poll'),
    ChatTranscriptNode(id: 'n', username: 'tester'),
    DefinitionListNode(id: 'n', items: []),
  ];

  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    test('岛类型 ${node.runtimeType} #$i 共用整块操作，删除可撤销且不伤及邻块', () {
      final state = EditorState(
        blocks: [
          TextBlock(
            id: 'before',
            content: EditableTextContent(text: '保留前文'),
          ),
          IslandBlock(id: 'object', node: node),
          TextBlock(
            id: 'after',
            content: EditableTextContent(text: '保留后文'),
          ),
        ],
      );
      addTearDown(state.dispose);
      final controller = ComposerObjectController(
        context: () => throw StateError('结构命令不需要界面上下文'),
        editor: () => state,
        contentActions: FluxdoEditorContentActions(),
        resumeEditing: () {},
        focusEditor: () {},
        viewImage: (_, _) {},
        editIsland: (_) {},
        editContainer: (_) {},
        openLink: (_) {},
        requestMenu: (_) {},
      );
      addTearDown(controller.dispose);
      final menu = controller.presentation(const EditorBlockTarget('object'))!;
      expect(menu.label, isNot('内容块'));
      expect(menu.actions.any((action) => action.label == '在前面输入'), isTrue);
      expect(menu.actions.any((action) => action.label == '在后面输入'), isTrue);
      final before = [...state.blocks];
      menu.actions.singleWhere((action) => action.destructive).run!();
      expect(state.blocks.map((block) => block.id), ['before', 'after']);
      state.undo();
      expect(state.blocks, before);
      if (!islandSerializable(node)) {
        final adapter = ComposerObjectAdapter.forObject(
          resolveEditorObject(state, const EditorBlockTarget('object'))!,
        );
        expect(adapter.primary, isNull, reason: '无法无损写回的块不提供源码编辑');
      }
    });
  }
}
