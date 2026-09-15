import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

enum ComposerObjectCommand {
  viewImage,
  imageSize,
  imageAlt,
  joinGrid,
  moveOutOfGrid,
  gridMovePrevious,
  gridMoveNext,
  gridLayout,
  splitGrid,
  openLink,
  removePreview,
  editSource,
  editText,
  editContainer,
  unwrapContainer,
}

/// 类型只声明能力；选中、菜单生命周期和通用命令不在各类型里重复实现。
class ComposerObjectAdapter {
  const ComposerObjectAdapter(
    this.label, {
    this.primary,
    this.commands = const [],
  });
  final String label;
  final ComposerObjectCommand? primary;
  final List<ComposerObjectCommand> commands;

  factory ComposerObjectAdapter.forObject(ResolvedEditorObject object) =>
      switch (object.target) {
        EditorImageTarget() => const ComposerObjectAdapter(
          '图片',
          primary: ComposerObjectCommand.viewImage,
          commands: [
            ComposerObjectCommand.imageSize,
            ComposerObjectCommand.imageAlt,
            ComposerObjectCommand.joinGrid,
          ],
        ),
        EditorGridImageTarget() => ComposerObjectAdapter(
          ((object.block as IslandBlock).node as ImageGridNode).mode ==
                  ImageGridMode.carousel
              ? '轮播图片'
              : '网格图片',
          primary: ComposerObjectCommand.viewImage,
          commands: [
            ComposerObjectCommand.imageAlt,
            ComposerObjectCommand.moveOutOfGrid,
            ComposerObjectCommand.gridMovePrevious,
            ComposerObjectCommand.gridMoveNext,
          ],
        ),
        EditorContainerTarget() => ComposerObjectAdapter(
          composerContainerLabel(object.frame!),
          primary: object.frame is DetailsFrame || object.frame is CalloutFrame
              ? ComposerObjectCommand.editContainer
              : null,
          commands: const [ComposerObjectCommand.unwrapContainer],
        ),
        EditorBlockTarget() => _blockAdapter(
          object.block,
          copyable: object.canCopy,
        ),
      };

  static ComposerObjectAdapter _blockAdapter(
    EditorBlock block, {
    required bool copyable,
  }) {
    final label = composerBlockLabel(block);
    if (block is TextBlock) {
      return ComposerObjectAdapter(
        label,
        primary: ComposerObjectCommand.editText,
      );
    }
    final node = (block as IslandBlock).node;
    if (node is ImageGridNode) {
      return ComposerObjectAdapter(
        label,
        commands: const [
          ComposerObjectCommand.gridLayout,
          ComposerObjectCommand.splitGrid,
        ],
      );
    }
    final editable =
        copyable && node is! HorizontalRuleNode && node is! BlankLineNode;
    if (composerObjectLink(node) != null) {
      return ComposerObjectAdapter(
        label,
        primary: ComposerObjectCommand.openLink,
        commands: [
          if (node is OneboxNode || node is QuoteCardNode)
            ComposerObjectCommand.removePreview,
          if (editable) ComposerObjectCommand.editSource,
        ],
      );
    }
    return ComposerObjectAdapter(
      label,
      primary: editable ? ComposerObjectCommand.editSource : null,
    );
  }
}

String composerContainerLabel(ContainerFrame frame) => switch (frame) {
  QuoteFrame() => '引用',
  QuoteCardFrame() => '引用卡片',
  SpoilerFrame() => '剧透块',
  DetailsFrame() => '折叠详情',
  CalloutFrame() => '提示框',
};

/// 穷尽节点类型，新增节点时必须明确名称和能力，不能悄悄落入“内容块”。
String composerBlockLabel(EditorBlock block) => switch (block) {
  TextBlock(:final kind) => switch (kind) {
    TextBlockKind.paragraph => '段落',
    TextBlockKind.heading => '标题',
    TextBlockKind.listItem => '列表项',
  },
  IslandBlock(:final node) => switch (node) {
    ParagraphNode() => '段落',
    HeadingNode() => '标题',
    ListNode() => '列表',
    BlockquoteNode() => '引用',
    HorizontalRuleNode() => '分隔线',
    BlankLineNode() => '空行',
    CodeBlockNode(:final language) => language == 'mermaid' ? '流程图' : '代码块',
    QuoteCardNode() => '引用卡片',
    SpoilerBlockNode() => '剧透块',
    OneboxNode() => '链接卡片',
    CalloutNode() => '提示框',
    DetailsNode() => '折叠详情',
    ImageGridNode(:final mode) =>
      mode == ImageGridMode.carousel ? '图片轮播' : '图片网格',
    FootnotesSectionNode() => '脚注',
    LazyVideoNode() => '视频卡片',
    IframeNode() => '嵌入内容',
    VideoNode() => '视频',
    AudioNode(:final voice) => voice ? '语音' : '音频',
    TableNode() => '表格',
    PolicyNode() => '确认内容',
    MathBlockNode() => '公式',
    SvgNode() => '矢量图',
    PollNode() => '投票',
    ChatTranscriptNode() => '聊天记录',
    DefinitionListNode() => '定义列表',
  },
};

String? composerObjectLink(BlockNode node) {
  final link = switch (node) {
    OneboxNode(:final url) => url,
    LazyVideoNode(:final url) => url,
    QuoteCardNode(:final oneboxUrl) => oneboxUrl,
    IframeNode(:final src) ||
    VideoNode(:final src) ||
    AudioNode(:final src) => src,
    _ => null,
  };
  if (link == null || link.isEmpty) return null;
  final uri = Uri.tryParse(link);
  return link.startsWith('/') || uri?.scheme == 'https' || uri?.scheme == 'http'
      ? link
      : null;
}
