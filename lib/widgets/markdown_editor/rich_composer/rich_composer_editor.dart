/// 富文本 composer 编辑器 —— 自研 WYSIWYG 内核(fluxdo_render/editor)的
/// 主 app 宿主。实现 MarkdownEditor 的接口面,宿主页面(reply_sheet /
/// create_topic_page)按 feature flag 二选一渲染,其余逻辑零改动。
///
/// **controller 镜像策略**:TextEditingController 保持为对外真相源 ——
/// 编辑文档每次变更 debounce 序列化回写 controller.text,宿主的草稿保存
/// (监听 controller)/提交(controller.text → raw)/字数校验全部照旧。
/// 初始文本(草稿恢复)经 cook 链路导入;导入失败回调 onFallbackToPlain
/// 让宿主切回纯文本编辑器。
library;

import 'dart:async';
import 'dart:io' show File;
import 'dart:math' show max;

import 'package:chat_bottom_container/chat_bottom_container.dart';
import 'package:flutter/foundation.dart'
    show Uint8List, defaultTargetPlatform, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart'
    show
        CalloutKind,
        CodeBlockNode,
        OneboxNode,
        QuoteCardNode,
        EmojiRun,
        ImageRun,
        InlineNode,
        LocalDateRun,
        MentionRun,
        NodeFactory;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../constants.dart';
import '../../../models/mention_user.dart';
import '../../../services/app_error_handler.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../services/discourse_cook_service.dart';
import '../../../services/emoji_handler.dart';
import '../../../utils/clipboard_image_native.dart';
import '../../../utils/dialog_utils.dart';
import '../../../utils/fluxdo_render_callbacks.dart';
import '../../../utils/link_launcher.dart';
import '../../../utils/platform_utils.dart';
import '../../../utils/url_helper.dart';
import '../../common/fading_edge_scroll_view.dart';
import '../../common/smart_avatar.dart';
import '../../content/discourse_html_content/image_utils.dart';
import '../../mention/mention_autocomplete.dart';
import '../emoji_popover.dart';
import '../emoji_sticker_panel.dart';
import '../image_upload_dialog.dart';
import '../link_insert_dialog.dart';
import '../template_insert_dialog.dart';
import '../composer_shortcuts.dart' show composerShortcutHint;
import '../markdown_toolbar.dart' show MarkdownToolbarState;
import 'callout_edit_dialog.dart';
import 'composer_doc_codec.dart';
import 'html_to_markdown.dart';
import 'local_date_edit_dialog.dart';
import '../media_upload_helper.dart';
import '../cursor_swipe_control.dart';
import '../voice_recorder_sheet.dart';

/// 孤岛渲染工厂:复用 generic callbacks 的全部 builder(emoji 缓存池/
/// 图片管线/代码高亮…),编辑器里的岛与阅读端视觉一致。
NodeFactory buildComposerNodeFactory(BuildContext context) {
  final callbacks = FluxdoRenderCallbacks.generic(
    heroTagNamespace: 'rich_composer',
  );
  return NodeFactory(
    emojiImageBuilder: callbacks.emojiImageBuilder,
    imageContentBuilder: callbacks.imageContentBuilder,
    codeBlockHighlighter: callbacks.codeBlockHighlighter,
    quoteAvatarBuilder: callbacks.quoteAvatarBuilder,
    oneboxBuilder: callbacks.oneboxBuilder,
    imageGridBuilder: callbacks.imageGridBuilder,
    localDateBuilder: callbacks.localDateBuilder,
    mathBlockBuilder: callbacks.mathBlockBuilder,
    mathInlineBuilder: callbacks.mathInlineBuilder,
    svgBuilder: callbacks.svgBuilder,
  );
}

class RichComposerEditor extends StatefulWidget {
  const RichComposerEditor({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText = '',
    this.header,
    this.metaBar,
    this.emojiPanelHeight = 280.0,
    this.onEmojiPanelChanged,
    this.mentionDataSource,
    this.onFallbackToPlain,
    this.onSwitchToSource,
  });

  /// 对外真相源镜像(宿主草稿/提交读它)。
  final TextEditingController controller;

  final FocusNode? focusNode;
  final String hintText;

  /// 滚动头部(标题/标签等元数据区):放进编辑区滚动容器顶部,与正文
  /// 一起滚 —— 手机上写正文时头部自然滚出屏,编辑区满格(零跳变:
  /// 头部高度恒定,离场回场全由滚动驱动)。null 时无头部。
  final Widget? header;

  /// 底部属性条(编辑区与工具栏之间,如 ComposerMetaBar):
  /// 分类/标签/字数等元数据常驻可见可改,不随滚动离场。null 时无。
  final Widget? metaBar;
  final double emojiPanelHeight;
  final ValueChanged<bool>? onEmojiPanelChanged;
  final MentionDataSource? mentionDataSource;

  /// 初始导入失败(cook 不可用/草稿含不可解析内容)时回调 —— 宿主应
  /// 切回纯文本 MarkdownEditor。
  final VoidCallback? onFallbackToPlain;

  /// 用户主动点"源码模式"按钮。调用前编辑器已 flushToController
  /// (controller.text 即最新 markdown),宿主直接换 MarkdownEditor
  /// 即可,内容无缝衔接。null 时不显示切换按钮。
  final VoidCallback? onSwitchToSource;

  @override
  State<RichComposerEditor> createState() => RichComposerEditorState();
}

class RichComposerEditorState extends State<RichComposerEditor> {
  EditorState? _editor;
  bool _importing = true;

  Timer? _serializeDebounce;

  bool _showEmojiPanel = false;

  /// 编辑器焦点(注入 FluxdoEditor;键盘⇄表情面板联动的锚)。
  late final FocusNode _editorFocus =
      widget.focusNode ?? FocusNode(debugLabel: 'RichComposer');
  bool get _ownsFocus => widget.focusNode == null;

  /// 编辑区**祖先**焦点节点(ChatBottomPanelContainer.inputFocusNode
  /// 挂它):编辑器正文/表格 cell/代码块输入等任何子输入框聚焦时它都
  /// hasFocus —— 容器不会在"编辑器 → 表格 cell"焦点切换的间隙误判
  /// 离开输入区收键盘。canRequestFocus:false 不参与实际聚焦。
  final FocusNode _editorAreaFocus = FocusNode(
    debugLabel: 'RichComposerArea',
    canRequestFocus: false,
  );

  /// 编辑区滚动(header + 正文同一容器);宿主经 [scrollToTop] 把
  /// 滚出屏的头部(标题校验失败等场景)拉回可见。
  final ScrollController _scrollController = ScrollController();

  /// 键盘/表情面板容器(MarkdownEditor 同款:键盘态占位、表情态等高
  /// 面板、无键盘时底部安全区 —— 切换零跳变)。
  final _panelController = ChatBottomPanelContainerController<_RichPanelType>();
  _RichPanelType _currentPanel = _RichPanelType.none;

  /// 用户意图面板(防焦点竞争:表情面板打开期间焦点变化不得关面板)。
  _RichPanelType _intendedPanel = _RichPanelType.none;

  static final bool _isDesktop = PlatformUtils.isDesktop;

  /// EmojiStickerPanel 实例缓存(MarkdownEditor 同款:防 setState 级联
  /// 重建整个 emoji grid)。
  Widget? _emojiPanelChild;

  /// 桌面端表情悬浮弹层控制器(MarkdownEditor 同款;移动端 null)
  EmojiPopoverController? _emojiPopover;

  // mention 补全状态
  final LayerLink _mentionLink = LayerLink();
  OverlayEntry? _mentionOverlay;
  List<MentionUser> _mentionCandidates = const [];
  String _mentionQuery = '';
  Timer? _mentionDebounce;

  /// 岛渲染工厂:initState 建一次(build 里每帧新建会让孤岛 didUpdateWidget
  /// 判定 factory 变化 → 代码块每次打字重新高亮)。
  NodeFactory? _nodeFactory;

  /// 虚拟指针(手势光标二维形态):滑钮 pan 驱动编辑器浮动光标链。
  final _virtualPointer = FluxdoEditorVirtualPointer();

  @override
  void initState() {
    super.initState();
    // 预热 cook 引擎:551K JS bundle 的同步 eval 挪到打开编辑器时,
    // 否则落在首次序列化触发预览 cook 的时刻 —— 表现为"打第一个字超卡"。
    DiscourseCookService().warmUp();
    if (_isDesktop) {
      _emojiPopover = EmojiPopoverController()
        ..addListener(_onEmojiPopoverChanged);
    }
    if (kDebugMode) EditorImeClient.debugLogging = true;
    _importInitial();
  }

  /// 弹层开合同步 _showEmojiPanel(驱动工具栏表情按钮高亮)
  void _onEmojiPopoverChanged() {
    if (!mounted) return;
    final isOpen = _emojiPopover?.isOpen ?? false;
    if (_showEmojiPanel != isOpen) {
      setState(() => _showEmojiPanel = isOpen);
    }
  }

  Future<void> _importInitial() async {
    // 门禁导入:序列化回写 → 二次 cook 与原 raw 的 cook 对比,不等价
    // (不可序列化岛/语法缺口)→ 回调降级纯文本,防止编辑-提交毁帖。
    // 空文档/富 composer 自己存的草稿天然过门禁;唯一代价是打开时多一次
    // cook(warmUp 后毫秒级)。
    final doc = await markdownToDocGuarded(widget.controller.text);
    if (!mounted) return;
    if (doc == null) {
      widget.onFallbackToPlain?.call();
      return;
    }
    final editor = EditorState(blocks: doc);
    editor.addListener(_onDocChanged);
    setState(() {
      _editor = editor;
      _importing = false;
    });
  }

  @override
  void dispose() {
    // 镜像 debounce(800ms)窗口内的最后编辑先落盘到 controller ——
    // unmount 后序遍历,子先于宿主 dispose,此刻 controller 还活着、
    // 宿主的草稿监听也还挂着;不 flush 的话宿主 dispose 里的兜底草稿
    // 保存读到旧文本(丢最后一句话)。
    flushToController();
    _emojiPopover?.dispose();
    _serializeDebounce?.cancel();
    _mentionDebounce?.cancel();
    _removeMentionOverlay();
    _linkToolbarOverlay?.remove();
    _oneboxToolbarOverlay?.remove();
    _removeSlashOverlay();
    _removeImageOverlay();
    _altFocus.dispose();
    _slashScroll.dispose();
    if (_ownsFocus) _editorFocus.dispose();
    _editorAreaFocus.dispose();
    _scrollController.dispose();
    _editor?.removeListener(_onDocChanged);
    _editor?.dispose();
    super.dispose();
  }

  /// 编辑区滚回顶部(header 含标题输入,校验失败等场景需拉回可见)
  void scrollToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  // -----------------------------------------------------------------
  // doc → controller 镜像
  // -----------------------------------------------------------------

  bool _lastIsEmpty = true;

  void _onDocChanged() {
    // 只在「空 ↔ 非空」翻转时重建(hint 显隐依赖它);普通打字不 setState ——
    // FluxdoEditor 内部自己监听 state 重建,整个 composer 跟着每字全量
    // rebuild 是纯浪费(打字卡顿嫌疑之一)。
    final empty = _computeIsEmpty();
    if (empty != _lastIsEmpty && mounted) {
      setState(() => _lastIsEmpty = empty);
    }
    _serializeDebounce?.cancel();
    // 800ms:回写 controller 会触发宿主(字数/草稿监听)整页 setState,
    // 打字停顿后再做;草稿保存自身还有二级 debounce,不丢内容。
    _serializeDebounce = Timer(const Duration(milliseconds: 800), () {
      final editor = _editor;
      if (editor == null || !mounted) return;
      final sw = Stopwatch()..start();
      final raw = docToRaw(editor.blocks);
      if (raw == widget.controller.text) return;
      widget.controller.text = raw;
      if (kDebugMode && sw.elapsedMilliseconds > 8) {
        debugPrint(
          '[RichComposer] serialize+mirror '
          '${sw.elapsedMilliseconds}ms (${raw.length} chars)',
        );
      }
    });
    _updateMentionQuery();
    _updateSlashQuery();
  }

  bool _computeIsEmpty() {
    final editor = _editor;
    if (editor == null) return true;
    if (editor.blocks.length != 1) return false;
    final b = editor.blocks.first;
    if (b is! TextBlock) return false;
    // 空文档判定含块类型:'- ' 转成空列表项/'# ' 转成空标题/包了容器
    // 都不算空 —— 否则 hint 与列表圆点/标题光标叠画(实测截图)。
    return b.content.length == 0 && b.isParagraph && b.containers.isEmpty;
  }

  /// 立即序列化(宿主提交前调用,确保 controller 是最新;镜像 debounce
  /// 窗口内提交也不丢内容)。
  void flushToController() {
    _serializeDebounce?.cancel();
    final editor = _editor;
    if (editor == null) return;
    final raw = docToRaw(editor.blocks);
    if (raw != widget.controller.text) {
      // 原子赋值 + 合法末尾选区。text setter 会把 selection 置
      // collapsed(-1);切到源码模式时 TextField attach 的**首帧**
      // setEditingState 就带着 -1 发给平台(EditableText 的聚焦纠偏
      // 发生在 _openInputConnection 之后)——Android restartInput /
      // macOS 输入模型以"无光标态"初始化,Gboard 等 IME 的退格基于
      // 其光标缓存,从此对既有文本失效 = 真机"切过去旧文字删不掉、
      // 新输入正常"。选区必须在这里就合法。
      widget.controller.value = TextEditingValue(
        text: raw,
        selection: TextSelection.collapsed(offset: raw.length),
      );
    }
  }

  // -----------------------------------------------------------------
  // 斜杠菜单(段首 `/` 唤起块插入 —— 类 Notion)
  // -----------------------------------------------------------------

  OverlayEntry? _slashOverlay;
  String? _slashQuery;
  int _slashSelected = 0;

  /// 光标全局矩形(FluxdoEditor 帧后上抛;斜杠/mention 浮层锚定用)。
  Rect? _caretGlobalRect;

  /// 浮层按键拦截(编辑器 onKeyEvent 首先调):斜杠菜单激活时接管
  /// 上下/回车/Tab/Esc。
  bool _interceptKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // Cmd/Ctrl+K 插入链接(对齐 Discourse composer;内核不处理 keyK,
    // 弹窗动作属宿主层 —— 与剪贴板三键同理不进纯状态层)
    if (_slashOverlay == null &&
        event.logicalKey == LogicalKeyboardKey.keyK &&
        (defaultTargetPlatform == TargetPlatform.macOS
            ? HardwareKeyboard.instance.isMetaPressed
            : HardwareKeyboard.instance.isControlPressed)) {
      _insertLink();
      return true;
    }
    if (_slashOverlay == null) return false;
    final items = _slashFiltered;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _slashSelected = (_slashSelected + 1) % items.length;
        _slashOverlay!.markNeedsBuild();
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _ensureSlashSelectedVisible(),
        );
        return true;
      case LogicalKeyboardKey.arrowUp:
        _slashSelected = (_slashSelected - 1 + items.length) % items.length;
        _slashOverlay!.markNeedsBuild();
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _ensureSlashSelectedVisible(),
        );
        return true;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
      case LogicalKeyboardKey.tab:
        if (_slashSelected < items.length) {
          _runSlashAction(items[_slashSelected].$4);
        }
        return true;
      case LogicalKeyboardKey.escape:
        _dismissSlash();
        return true;
    }
    return false;
  }

  /// 候选:(关键字集, 标签, 图标, 动作)。关键字含中文与英文别名。
  late final List<(List<String>, String, IconData, Future<void> Function())>
  _slashItems = [
    (
      ['h1', 'heading', '标题', 'bt'],
      '标题 1',
      Icons.title_rounded,
      () async => _applySlashBlock((s) => s.setHeading(1)),
    ),
    (
      ['h2', '标题2'],
      '标题 2',
      Icons.title_rounded,
      () async => _applySlashBlock((s) => s.setHeading(2)),
    ),
    (
      ['h3', '标题3'],
      '标题 3',
      Icons.title_rounded,
      () async => _applySlashBlock((s) => s.setHeading(3)),
    ),
    (
      ['ul', 'list', '列表', 'lb', 'wxlb'],
      '无序列表',
      Icons.format_list_bulleted_rounded,
      () async => _applySlashBlock((s) => s.toggleList(ordered: false)),
    ),
    (
      ['ol', '有序', 'yxlb'],
      '有序列表',
      Icons.format_list_numbered_rounded,
      () async => _applySlashBlock((s) => s.toggleList(ordered: true)),
    ),
    (
      ['quote', '引用', 'yy'],
      '引用',
      Icons.format_quote_rounded,
      () async => _applySlashBlock((s) => s.toggleQuote()),
    ),
    (
      ['table', '表格', 'bg'],
      '表格',
      Icons.table_chart_outlined,
      () async =>
          insertMarkdownSnippet('| 列 1 | 列 2 |\n|---|---|\n| 内容 | 内容 |'),
    ),
    (
      ['code', '代码', 'dm'],
      '代码块',
      Icons.code_rounded,
      () async => insertMarkdownSnippet('```dart\n// 代码\n```'),
    ),
    (
      ['math', '公式', 'gs'],
      '公式块',
      Icons.functions_rounded,
      () async => insertMarkdownSnippet(
        r'$$'
        '\nE=mc^2\n'
        r'$$',
      ),
    ),
    (
      ['hr', 'divider', '分隔', 'fgx'],
      '分隔线',
      Icons.horizontal_rule_rounded,
      () async => insertMarkdownSnippet('---'),
    ),
    (
      ['details', '折叠', 'zd'],
      '折叠详情',
      Icons.expand_circle_down_outlined,
      () async => insertMarkdownSnippet('[details="点开看"]\n折叠内容\n[/details]'),
    ),
    (
      ['spoiler', '剧透', 'jt'],
      '剧透遮罩',
      Icons.blur_on_rounded,
      () async => insertMarkdownSnippet('[spoiler]\n剧透内容\n[/spoiler]'),
    ),
    (
      ['date', '日期', '时间', 'rq', 'sj'],
      '日期时间',
      Icons.event_rounded,
      () async => _insertLocalDate(),
    ),
    (
      ['image', '图片', 'tp'],
      '上传图片',
      Icons.image_outlined,
      () async => _pickAndUploadImages(),
    ),
    (
      ['callout', '标注', 'bz', 'note'],
      '标注 Callout',
      Icons.sticky_note_2_outlined,
      () async => _insertCallout(),
    ),
    (
      ['link', '链接', 'lj'],
      '插入链接',
      Icons.link_rounded,
      () async => _insertLink(),
    ),
    (
      ['audio', '音频', 'yp'],
      '上传音频',
      Icons.audiotrack_rounded,
      () async => _pickAndInsertMedia(isAudio: true),
    ),
    (
      ['video', '视频', 'sp'],
      '上传视频',
      Icons.videocam_outlined,
      () async => _pickAndInsertMedia(isAudio: false),
    ),
    (
      ['voice', '语音', 'luyin'],
      '语音消息',
      Icons.mic_rounded,
      () async => _recordAndInsertVoice(),
    ),
    (
      ['template', '模板', 'mb'],
      '我的模板',
      Icons.assignment_outlined,
      () async => _insertTemplate(),
    ),
  ];

  List<(List<String>, String, IconData, Future<void> Function())>
  get _slashFiltered {
    final q = (_slashQuery ?? '').toLowerCase();
    if (q.isEmpty) return _slashItems;
    return [
      for (final item in _slashItems)
        if (item.$1.any((k) => k.contains(q)) || item.$2.contains(q)) item,
    ];
  }

  /// 光标前缀 = 段首 `/query` → 弹菜单(块级插入语义只在段首,行中的
  /// `/` 是普通字符 —— Notion 同款)。
  void _updateSlashQuery() {
    final editor = _editor;
    if (editor == null) return;
    final sel = editor.selection;
    if (sel == null || !sel.isCollapsed) {
      _dismissSlash();
      return;
    }
    final block = editor.textBlockById(sel.extent.blockId);
    if (block == null || editor.hasComposing) {
      _dismissSlash();
      return;
    }
    final before = block.content.text.substring(0, sel.extent.offset);
    final m = RegExp(r'^/([\w一-鿿]*)$').firstMatch(before);
    if (m == null) {
      _dismissSlash();
      return;
    }
    final query = m.group(1)!;
    if (query == _slashQuery && _slashOverlay != null) {
      _slashOverlay!.markNeedsBuild();
      return;
    }
    _slashQuery = query;
    _slashSelected = 0; // 过滤集变了,选中项重置到首个
    if (_slashFiltered.isEmpty) {
      _dismissSlash();
      return;
    }
    if (_slashOverlay == null) {
      _showSlashOverlay();
    } else {
      _slashOverlay!.markNeedsBuild();
    }
  }

  /// 键盘选中项滚动到可视区用。
  final ScrollController _slashScroll = ScrollController();

  void _showSlashOverlay() {
    _removeSlashOverlay();
    _slashSelected = 0;
    _slashOverlay = OverlayEntry(
      builder: (context) {
        // 锚定光标(全局矩形):默认弹光标下方;近安全区底翻到上方。
        // 安全区:底 = 屏高 - 软键盘;顶 = 状态栏(翻上方时菜单不得
        // 顶进状态栏 —— 上翻用 bottom 定位,高度不够会向上溢出,
        // maxHeight 必须按光标上方实际空间收缩)。
        final caret = _caretGlobalRect;
        final screen = MediaQuery.sizeOf(context);
        final safeTop = MediaQuery.viewPaddingOf(context).top + 8;
        final safeBottom =
            screen.height - MediaQuery.viewInsetsOf(context).bottom - 8;
        const menuWidth = 244.0;
        // 7 行 × 40 + 边距(半行截断暗示可滚);小屏/键盘挤压时收缩
        var menuMaxHeight = 302.0.clamp(
          120.0,
          (safeBottom - 24).clamp(120.0, 302.0),
        );
        double left;
        double? top;
        double? bottom;
        if (caret != null) {
          left = caret.left.clamp(8.0, screen.width - menuWidth - 8);
          final below = safeBottom - caret.bottom;
          final above = caret.top - safeTop;
          if (below >= menuMaxHeight + 16 || below >= above) {
            top = caret.bottom + 6;
            menuMaxHeight = menuMaxHeight.clamp(
              120.0,
              (below - 12).clamp(120.0, 302.0),
            );
          } else {
            bottom = screen.height - caret.top + 6;
            menuMaxHeight = menuMaxHeight.clamp(
              120.0,
              (above - 12).clamp(120.0, 302.0),
            );
          }
        } else {
          left = 16;
          bottom = screen.height - safeBottom + 80;
        }
        final items = _slashFiltered;
        if (_slashSelected >= items.length) _slashSelected = 0;
        return Positioned(
          left: left,
          top: top,
          bottom: bottom,
          width: menuWidth,
          child: _FloatingPanel(
            maxHeight: menuMaxHeight,
            child: ListView.builder(
              controller: _slashScroll,
              shrinkWrap: true,
              padding: const EdgeInsets.all(4),
              itemCount: items.length,
              itemExtent: 40,
              itemBuilder: (context, i) {
                final (_, label, icon, action) = items[i];
                return _SlashMenuRow(
                  icon: icon,
                  label: label,
                  selected: i == _slashSelected,
                  onTap: () => _runSlashAction(action),
                );
              },
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(_slashOverlay!);
  }

  /// 键盘导航后把选中项滚进可视区(itemExtent 固定行高,直接算)。
  void _ensureSlashSelectedVisible() {
    if (!_slashScroll.hasClients) return;
    const itemH = 40.0;
    final top = _slashSelected * itemH;
    final bottom = top + itemH;
    final viewTop = _slashScroll.offset;
    final viewBottom = viewTop + _slashScroll.position.viewportDimension;
    if (top < viewTop) {
      _slashScroll.jumpTo(top);
    } else if (bottom > viewBottom) {
      _slashScroll.jumpTo(bottom - _slashScroll.position.viewportDimension);
    }
  }

  /// 执行候选:先删 `/query` 前缀,再跑动作。
  Future<void> _runSlashAction(Future<void> Function() action) async {
    final editor = _editor;
    _dismissSlash();
    if (editor == null) return;
    final sel = editor.selection;
    if (sel != null && sel.isCollapsed) {
      final block = editor.textBlockById(sel.extent.blockId);
      if (block != null) {
        final before = block.content.text.substring(0, sel.extent.offset);
        final m = RegExp(r'^/[\w一-鿿]*$').firstMatch(before);
        if (m != null) {
          editor.updateSelection(
            EditorSelection(
              base: EditorPosition(blockId: block.id, offset: 0),
              extent: EditorPosition(
                blockId: block.id,
                offset: sel.extent.offset,
              ),
            ),
          );
          editor.deleteSelection();
        }
      }
    }
    await action();
  }

  /// 块属性类候选(标题/列表/引用):直接对当前块执行命令。
  Future<void> _applySlashBlock(void Function(EditorState) command) async {
    final editor = _editor;
    if (editor == null) return;
    command(editor);
  }

  void _dismissSlash() {
    _slashQuery = null;
    _removeSlashOverlay();
  }

  void _removeSlashOverlay() {
    _slashOverlay?.remove();
    _slashOverlay = null;
  }

  // -----------------------------------------------------------------
  // mention 补全(监听光标前缀 @word)
  // -----------------------------------------------------------------

  void _updateMentionQuery() {
    final dataSource = widget.mentionDataSource;
    final editor = _editor;
    if (dataSource == null || editor == null) return;
    final sel = editor.selection;
    if (sel == null || !sel.isCollapsed) {
      _dismissMention();
      return;
    }
    final block = editor.textBlockById(sel.extent.blockId);
    if (block == null) {
      _dismissMention();
      return;
    }
    final before = block.content.text.substring(0, sel.extent.offset);
    final m = RegExp(r'@([\w_-]*)$').firstMatch(before);
    if (m == null) {
      _dismissMention();
      return;
    }
    final query = m.group(1)!;
    if (query == _mentionQuery && _mentionOverlay != null) return;
    _mentionQuery = query;
    _mentionDebounce?.cancel();
    _mentionDebounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      try {
        final result = await dataSource(query);
        if (!mounted || _mentionQuery != query) return;
        _mentionCandidates = result.users;
        if (_mentionCandidates.isEmpty) {
          _dismissMention();
        } else {
          _showMentionOverlay();
        }
      } catch (_) {
        _dismissMention();
      }
    });
  }

  void _showMentionOverlay() {
    _removeMentionOverlay();
    _mentionOverlay = OverlayEntry(
      builder: (context) {
        // 锚定光标(斜杠菜单同款):下方优先;上翻时高度按光标上方
        // 空间收缩(不顶进状态栏)
        final caret = _caretGlobalRect;
        final screen = MediaQuery.sizeOf(context);
        final safeTop = MediaQuery.viewPaddingOf(context).top + 8;
        final safeBottom =
            screen.height - MediaQuery.viewInsetsOf(context).bottom - 8;
        const menuWidth = 260.0;
        var menuMaxHeight = 220.0;
        double left;
        double? top;
        double? bottom;
        if (caret != null) {
          left = caret.left.clamp(8.0, screen.width - menuWidth - 8);
          final below = safeBottom - caret.bottom;
          final above = caret.top - safeTop;
          if (below >= menuMaxHeight + 16 || below >= above) {
            top = caret.bottom + 4;
            menuMaxHeight = menuMaxHeight.clamp(
              120.0,
              (below - 12).clamp(120.0, 220.0),
            );
          } else {
            bottom = screen.height - caret.top + 4;
            menuMaxHeight = menuMaxHeight.clamp(
              120.0,
              (above - 12).clamp(120.0, 220.0),
            );
          }
        } else {
          left = 16;
          bottom = screen.height - safeBottom + 80;
        }
        return Positioned(
          left: left,
          top: top,
          bottom: bottom,
          width: menuWidth,
          child: _FloatingPanel(
            maxHeight: menuMaxHeight,
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.all(4),
              itemCount: _mentionCandidates.length,
              itemBuilder: (context, i) {
                final user = _mentionCandidates[i];
                return _MentionRow(
                  user: user,
                  onTap: () => _insertMention(user),
                );
              },
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(_mentionOverlay!);
  }

  void _insertMention(MentionUser user) {
    final editor = _editor;
    if (editor == null) return;
    final sel = editor.selection;
    if (sel == null) return;
    final block = editor.textBlockById(sel.extent.blockId);
    if (block == null) return;
    final before = block.content.text.substring(0, sel.extent.offset);
    final m = RegExp(r'@([\w_-]*)$').firstMatch(before);
    if (m == null) return;
    // 删掉 @query 前缀,插入 mention 原子 + 空格
    editor.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: block.id, offset: m.start),
        extent: EditorPosition(blockId: block.id, offset: sel.extent.offset),
      ),
    );
    editor.deleteSelection();
    editor.insertAtom(
      MentionRun(username: user.username, href: '/u/${user.username}'),
    );
    editor.insertText(' ');
    _dismissMention();
  }

  void _dismissMention() {
    _mentionQuery = '';
    _mentionDebounce?.cancel();
    _removeMentionOverlay();
  }

  void _removeMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
  }

  // -----------------------------------------------------------------
  // emoji / sticker / 上传 / 插入
  // -----------------------------------------------------------------

  /// 表情面板开关(MarkdownEditor._togglePanel 同构:移动端经
  /// ChatBottomPanelContainer 与键盘等高互切零跳变;桌面走悬浮弹层)。
  void _toggleEmojiPanel() {
    // 桌面端:悬浮弹层,不收 IME、焦点/光标原地不动;
    // _showEmojiPanel 由 popover listener 同步(驱动按钮高亮)
    if (_isDesktop) {
      _emojiPopover!.toggle(context, panel: _ensureEmojiPanelChild());
      return;
    }
    if (_intendedPanel == _RichPanelType.emoji) {
      _intendedPanel = _RichPanelType.none;
      // 切回键盘:显式 TextInput.show —— 编辑器自管连接一直挂着且
      // 焦点从未离开,requestFocus 无事发生、syncFromState 判无变化
      // 不调平台,键盘不会自己弹(与点编辑区切回同一根因)
      _panelController.updatePanelType(ChatBottomPanelType.keyboard);
      _editorFocus.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
      setState(() => _showEmojiPanel = false);
      widget.onEmojiPanelChanged?.call(false);
    } else {
      _intendedPanel = _RichPanelType.emoji;
      // 编辑器自管 IME(非 TextField):面板打开时显式收软键盘 ——
      // 连接保持(硬件键盘仍可打),焦点/光标不丢;容器的
      // forceHandleFocus 只管 TextField 场景,对自管连接不作为。
      SystemChannels.textInput.invokeMethod('TextInput.hide');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _panelController.updatePanelType(
          ChatBottomPanelType.other,
          data: _RichPanelType.emoji,
          forceHandleFocus: ChatBottomHandleFocus.requestFocus,
        );
      });
      setState(() => _showEmojiPanel = true);
      widget.onEmojiPanelChanged?.call(true);
    }
  }

  /// 表情面板开着时点编辑区 → 切回键盘态(MarkdownEditor 的 readOnly
  /// Listener 同构:面板意图保持逻辑会拦掉容器自动切换,必须显式收)。
  /// 显式 TextInput.show:编辑器自管连接一直挂着,tap 落同位置时
  /// selection 不变、syncFromState 不触发平台调用 → 键盘不出来
  /// ("关了面板但键盘没弹"的根因);连接在,show 幂等安全。
  void _onEditorAreaPointerDown() {
    if (_intendedPanel == _RichPanelType.none) return;
    _intendedPanel = _RichPanelType.none;
    _panelController.updatePanelType(ChatBottomPanelType.keyboard);
    SystemChannels.textInput.invokeMethod('TextInput.show');
    setState(() => _showEmojiPanel = false);
    widget.onEmojiPanelChanged?.call(false);
  }

  /// 关闭表情面板(供外部调用,如返回键拦截/标题栏点击 ——
  /// MarkdownEditor.closeEmojiPanel 同构):收面板不弹键盘。
  /// 宿主页 PopScope 只认 onEmojiPanelChanged 回落 canPop,这里
  /// 直接同步状态,不等容器 onPanelTypeChange 转一圈。
  void closeEmojiPanel() {
    if (_isDesktop) {
      _emojiPopover?.hide();
      return;
    }
    if (_intendedPanel == _RichPanelType.none &&
        _currentPanel != _RichPanelType.emoji) {
      return;
    }
    _intendedPanel = _RichPanelType.none;
    _panelController.updatePanelType(
      ChatBottomPanelType.none,
      forceHandleFocus: ChatBottomHandleFocus.none,
    );
    if (_showEmojiPanel) {
      setState(() => _showEmojiPanel = false);
      widget.onEmojiPanelChanged?.call(false);
    }
  }

  /// 面板高度:键盘高度已知用键盘高(等高切换),否则 emojiPanelHeight
  /// 兜底;都含底部安全区。
  double get _panelHeight {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    final kb = _panelController.keyboardHeight;
    return kb > 0
        ? max(kb, safeBottom)
        : max(widget.emojiPanelHeight, safeBottom);
  }

  /// 构建(或复用)EmojiStickerPanel 缓存实例,docked 与桌面悬浮弹层共用
  Widget _ensureEmojiPanelChild() {
    _emojiPanelChild ??= EmojiStickerPanel(
      // 桌面悬浮弹层:搜索走内联视图,布局按小窗收紧;
      // 面板内开 Navigator 层 sheet(表情包市场)前先收弹层
      inlineSearch: _isDesktop,
      compact: _isDesktop,
      onDismissRequested: _isDesktop ? () => _emojiPopover?.hide() : null,
      onEmojiSelected: (emoji) => _insertEmoji(emoji.name),
      // sticker markdown(含 ,30% 缩放后缀)走 cook 链路整段导入
      onStickerSelected: insertMarkdownSnippet,
      // 富编辑器的 backspace 原生处理岛/容器边界,直接复用
      onBackspace: () => _editor?.backspace(),
    );
    return _emojiPanelChild!;
  }

  Widget _buildEmojiPanel() {
    return SizedBox(height: _panelHeight, child: _ensureEmojiPanelChild());
  }

  void _insertEmoji(String name) {
    final editor = _editor;
    if (editor == null) return;
    final url = EmojiHandler().getEmojiUrl(name);
    editor.insertAtom(EmojiRun(name: name, url: url));
  }

  /// 万能插入原语:markdown 片段 → cook 链路 → 富内容块,粘贴语义并入
  /// 光标处。所有"+"菜单项(表格/公式/details/…)与链接/图片全走这条 ——
  /// 插入面 = markdown 语法面,零专用代码。cook 失败/超时降级纯文本。
  Future<void> insertMarkdownSnippet(String markdown) async {
    final editor = _editor;
    if (editor == null || markdown.isEmpty) return;
    // 从未聚焦过(选区 null)→ 落到文档末尾,插入不静默丢
    if (editor.selection == null) {
      final last = editor.blocks.last;
      editor.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: last.id, offset: last.selectionLength),
        ),
      );
    }
    final sw = kDebugMode ? (Stopwatch()..start()) : null;
    final fragment = await markdownToDoc(markdown);
    if (!mounted) return;
    final before = editor.blocks.length;
    if (fragment != null && fragment.isNotEmpty) {
      editor.pasteBlocks(fragment);
    } else {
      editor.pastePlainText(markdown);
    }
    if (kDebugMode) {
      debugPrint(
        '[RichComposer] insert "${markdown.split('\n').first}" '
        'cook=${sw!.elapsedMilliseconds}ms frag=${fragment?.length} '
        'blocks $before→${editor.blocks.length} sel=${editor.selection}',
      );
    }
  }

  /// 上传图片(选图 → 确认框 → 上传 → 插图片岛;单图流程,多图循环单图)。
  Future<void> _pickAndUploadImages() async {
    try {
      final images = await ImagePicker().pickMultiImage();
      if (images.isEmpty || !mounted) return;
      for (final img in images) {
        if (!mounted) return;
        final confirmed = await showImageUploadDialog(
          context,
          imagePath: img.path,
          imageName: img.name,
        );
        if (confirmed == null) continue;
        setState(() => _uploadingCount++);
        try {
          final uploadResult = await DiscourseService().uploadImage(
            confirmed.path,
          );
          // 预置 short_url → 完整 url 解析缓存(编辑器里的图立即可显)
          final url = uploadResult.url;
          if (url != null) {
            DiscourseImageUtils.seedUploadUrl(uploadResult.shortUrl, url);
          }
          if (!mounted) return;
          insertUploadedImage(
            shortUrl: uploadResult.shortUrl,
            alt: confirmed.originalName,
            width: uploadResult.width,
            height: uploadResult.height,
          );
        } finally {
          if (mounted) setState(() => _uploadingCount--);
        }
      }
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  int _uploadingCount = 0;

  /// 音视频上传插入(插入菜单):file_picker 选 → .xz 改名上传 →
  /// <audio>/<video> 标签经 cook 岛化插入。
  Future<void> _pickAndInsertMedia({required bool isAudio}) async {
    final picked = await FilePicker.platform.pickFiles(
      type: isAudio ? FileType.audio : FileType.video,
    );
    final file = picked?.files.single;
    final path = file?.path;
    if (file == null || path == null || !mounted) return;
    setState(() => _uploadingCount++);
    try {
      final tag = await uploadMediaFileAsTag(
        context,
        path: path,
        name: file.name,
        isAudio: isAudio,
      );
      if (tag == null || !mounted) return;
      await insertMarkdownSnippet(tag);
    } finally {
      if (mounted) setState(() => _uploadingCount--);
    }
  }

  /// 语音消息:录音面板 → 上传([wrap=voice] 语音条标签)→ 插入。
  Future<void> _recordAndInsertVoice() async {
    final path = await showVoiceRecorderSheet(context);
    if (path == null || !mounted) return;
    setState(() => _uploadingCount++);
    try {
      final tag = await uploadMediaFileAsTag(
        context,
        path: path,
        name: path.split('/').last,
        isAudio: true,
        voice: true,
      );
      if (tag == null || !mounted) return;
      await insertMarkdownSnippet(tag);
    } finally {
      if (mounted) setState(() => _uploadingCount--);
    }
  }

  /// 用户自定义模板(MD 模式「模板」同一选择器):内容为 markdown,
  /// 经 cook 导入链富内容化插入。
  Future<void> _insertTemplate() async {
    final template = await showTemplateInsertDialog(context);
    if (template == null || !mounted) return;
    await insertMarkdownSnippet(template.content);
  }

  /// 插入/施加链接:选区非空 → 对选中文字加 link mark(文字保留);
  /// 折叠 → 对话框输入文字+URL 后插入(经 cook)。
  Future<void> _insertLink() async {
    final editor = _editor;
    if (editor == null) return;
    final sel = editor.selection;
    final hasRange = sel != null && !sel.isCollapsed && sel.isSingleBlock;

    final result = await showLinkInsertDialog(context);
    if (result == null || !mounted) return;
    final text = result['text'] ?? '';
    final url = result['url'] ?? '';
    if (url.isEmpty) return;

    if (hasRange && editor.selection == sel) {
      editor.applyLink(url);
      return;
    }
    await insertMarkdownSnippet('[${text.isEmpty ? url : text}]($url)');
  }

  /// "+"插入菜单:每项 = 一段模板 markdown(经 cook 变成对应块类型)。
  /// 覆盖编辑白名单外的全部常用块 —— 验证任何类型不再需要手写语法。
  Future<void> _showInsertMenu(BuildContext anchorContext) async {
    final entries = <(String, String, IconData)>[
      (
        '表格',
        '| 列 1 | 列 2 |\n|---|---|\n| 内容 | 内容 |',
        Icons.table_chart_outlined,
      ),
      ('代码块', '```dart\n// 代码\n```', Icons.code_rounded),
      (
        '公式块',
        r'$$'
            '\nE=mc^2\n'
            r'$$',
        Icons.functions_rounded,
      ),
      ('分隔线', '---', Icons.horizontal_rule_rounded),
      (
        '折叠详情',
        '[details="点开看"]\n折叠内容\n[/details]',
        Icons.expand_circle_down_outlined,
      ),
      ('剧透遮罩', '[spoiler]\n剧透内容\n[/spoiler]', Icons.blur_on_rounded),
      ('引用卡', '[quote]\n引用内容\n[/quote]', Icons.format_quote_rounded),
    ];

    // 锚定"+"按钮矩形(anchorContext = 按钮自己的 context)—— 此前用
    // composer 整体 context 定位,菜单弹到编辑器区域角落(与按钮无关)。
    final btnBox = anchorContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (btnBox == null || overlay == null) return;
    final btnRect =
        btnBox.localToGlobal(Offset.zero, ancestor: overlay) & btnBox.size;

    final menuScheme = Theme.of(context).colorScheme;
    PopupMenuItem<String> item(String value, IconData icon, String label) =>
        PopupMenuItem<String>(
          value: value,
          height: 40,
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: menuScheme.surfaceContainerHighest.withValues(
                    alpha: 0.6,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(icon, size: 15, color: menuScheme.onSurfaceVariant),
              ),
              const SizedBox(width: 10),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        );

    final selected = await showMenu<String>(
      context: context,
      // 锚点 = 按钮顶边,菜单向上展开(工具栏在底部)
      position: RelativeRect.fromLTRB(
        btnRect.left,
        btnRect.top - 8,
        overlay.size.width - btnRect.right,
        overlay.size.height - btnRect.top + 8,
      ),
      // 浮层统一规格(_FloatingPanel 同款):圆角 12 + 细边框 + 浮层底
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: menuScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      color: menuScheme.surfaceContainerLow,
      constraints: const BoxConstraints(maxWidth: 230),
      items: [
        for (final (label, md, icon) in entries) item(md, icon, label),
        // 链接:与工具栏链接按钮同一流程(选区加 mark/对话框插入)
        item('__callout__', Icons.sticky_note_2_outlined, '标注 Callout'),
        item('__link__', Icons.link_rounded, '插入链接'),
        // 日期时间:弹属性对话框选时间再插原子(不再是死模板)
        item('__date__', Icons.event_rounded, '日期时间'),
        // 音视频:选文件改名 .xz 上传后插 <audio>/<video> 标签
        item('__audio__', Icons.audiotrack_rounded, '上传音频'),
        item('__video__', Icons.videocam_outlined, '上传视频'),
        item('__voice__', Icons.mic_rounded, '语音消息'),
        const PopupMenuDivider(height: 8),
        // 用户自定义模板(与 MD 模式「模板」同一选择器,内容经 cook)
        item('__template__', Icons.assignment_outlined, '我的模板…'),
        item('__custom__', Icons.data_object_rounded, 'Markdown 片段…'),
      ],
    );
    if (selected == null || !mounted) return;
    if (selected == '__custom__') {
      await _insertCustomMarkdown();
    } else if (selected == '__date__') {
      await _insertLocalDate();
    } else if (selected == '__audio__' || selected == '__video__') {
      await _pickAndInsertMedia(isAudio: selected == '__audio__');
    } else if (selected == '__voice__') {
      await _recordAndInsertVoice();
    } else if (selected == '__callout__') {
      await _insertCallout();
    } else if (selected == '__link__') {
      await _insertLink();
    } else if (selected == '__template__') {
      await _insertTemplate();
    } else {
      await insertMarkdownSnippet(selected);
    }
  }

  /// 插入日期时间:属性对话框 → date 原子插入光标处(行内语义,
  /// 对齐官方 composer 的 modal 插入)。
  Future<void> _insertLocalDate() async {
    final editor = _editor;
    if (editor == null) return;
    final run = await showLocalDateEditDialog(context);
    if (run == null || !mounted) return;
    if (editor.selection == null) {
      final last = editor.blocks.last;
      editor.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: last.id, offset: last.selectionLength),
        ),
      );
    }
    editor.insertAtom(run);
  }

  /// 自由 markdown 输入(兜底:poll/policy/iframe 等任意语法都能进来,
  /// 走 cook 后所见即所得 —— 相当于局部源码模式)。
  Future<void> _insertCustomMarkdown() async {
    final text = await _showMarkdownDialog(
      title: '插入 Markdown 片段',
      confirmLabel: '插入',
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    await insertMarkdownSnippet(text);
  }

  /// 岛源码编辑:双击岛 → 对话框(初值 = 岛的 markdown)→ 确认后重
  /// cook 替换。一次覆盖所有岛类型 —— 岛内 WYSIWYG 前的通用编辑通道。
  /// 清空 = 删岛。(表格不走这:cell 原位编辑见 [_onTableEdited]。)
  Future<void> _editIsland(IslandBlock island) async {
    final editor = _editor;
    if (editor == null) return;

    final source = serializeIslandNode(island.node);
    final text = await _showMarkdownDialog(
      title: '编辑源码',
      confirmLabel: '应用',
      initialText: source,
    );
    if (text == null || !mounted) return;
    if (text.trim().isEmpty) {
      editor.replaceIsland(island.id, const []);
      return;
    }
    if (text == source) return; // 没改
    final fragment = await markdownToDoc(text);
    if (!mounted) return;
    if (fragment == null) {
      // cook 不可用:不动原岛(比替换成纯文本更安全)
      return;
    }
    editor.replaceIsland(island.id, fragment);
  }

  /// 表格 cell 原位编辑确认:新表格 markdown → cook → 替换岛。
  Future<void> _onTableEdited(IslandBlock island, String markdown) async {
    final editor = _editor;
    if (editor == null) return;
    final fragment = await markdownToDoc(markdown);
    if (!mounted || fragment == null || fragment.isEmpty) return;
    editor.replaceIsland(island.id, fragment);
  }

  /// 代码块岛内编辑提交:结构化节点原位形变,不经 cook(fence 冲突由
  /// 序列化器处理:内容含 ``` 自动升 ````)。
  void _onCodeBlockEdited(IslandBlock island, String code, String? language) {
    final editor = _editor;
    if (editor == null || island.node is! CodeBlockNode) return;
    editor.updateIslandNode(
      island.id,
      CodeBlockNode(id: island.node.id, code: code, language: language),
    );
  }

  /// 剪贴板富格式粘贴,优先级:text/html → 纯位图 → (回落)纯文本。
  ///
  /// - html(网页/Word 复制):→ markdown 清洗 → cook 导入链。结构
  ///   保留,网页图走外链不吃上传流量(官方 composer 同取舍);
  /// - 纯位图(截图 Cmd+V,无 html 无文本):上传站内 → 图原子。
  ///   确认框+上传是长流程,fire-and-forget 不占粘贴调用 —— 插入由
  ///   [insertUploadedImage] 在上传完成时按彼时光标位执行;
  /// - 位图 + 文本并存(Excel 单元格等):文本优先(返回 null 回落),
  ///   避免双插。
  ///
  /// 任一步落空返回 null,FluxdoEditor 回落纯文本路径 —— 内容不丢。
  Future<List<EditorBlock>?> _importRichPaste() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null; // 平台无系统剪贴板访问
    final reader = await clipboard.read();
    if (reader.canProvide(Formats.htmlText)) {
      final html = await reader.readValue(Formats.htmlText);
      if (html != null && html.trim().isNotEmpty) {
        final md = clipboardHtmlToMarkdown(html);
        if (md != null) return markdownToDoc(md);
      }
      // html 存在但转换落空 → 文本回落。不碰位图:带 html 的位图多是
      // 网页复制附带的渲染快照,上传它反而错。
      return null;
    }
    if (!reader.canProvide(Formats.plainText)) {
      final img = await MarkdownToolbarState.readImageFromReader(reader);
      if (img != null) {
        unawaited(_uploadPastedImage(img.$1, img.$2));
        return null;
      }
      // 原生兜底(Windows):剪贴板历史(Win+V)放的 OLE data object 只在
      // OLE 层声明标记类格式,位图挂在原始 Win32 剪贴板上,super_clipboard
      // 枚举不到 —— 表现为「Win+V 粘贴图片没反应」。探针实测原生能拿到
      // CF_DIB 并成功转出 PNG,见 clipboard_image_native.dart。
      final native = readClipboardImageNative();
      if (native != null) {
        unawaited(_uploadPastedImage(native, 'png'));
      }
    }
    return null;
  }

  /// 粘贴位图上传:临时文件 → 确认框(与选图插入同 UX,可改名/取消误粘)
  /// → 上传 → 图原子插入。与 [_pickAndUploadImages] 单图流程同构。
  Future<void> _uploadPastedImage(Uint8List bytes, String ext) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final fileName = 'paste_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final tempFile = File(p.join(tempDir.path, fileName));
      await tempFile.writeAsBytes(bytes);
      if (!mounted) return;
      final confirmed = await showImageUploadDialog(
        context,
        imagePath: tempFile.path,
        imageName: fileName,
      );
      if (confirmed == null) return;
      setState(() => _uploadingCount++);
      try {
        final uploadResult = await DiscourseService().uploadImage(
          confirmed.path,
        );
        final url = uploadResult.url;
        if (url != null) {
          DiscourseImageUtils.seedUploadUrl(uploadResult.shortUrl, url);
        }
        if (!mounted) return;
        insertUploadedImage(
          shortUrl: uploadResult.shortUrl,
          alt: confirmed.originalName,
          width: uploadResult.width,
          height: uploadResult.height,
        );
      } finally {
        if (mounted) setState(() => _uploadingCount--);
      }
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  // -----------------------------------------------------------------
  // 图片原子浮层(官方 ImageNodeView 复刻:上工具条 + 下 alt 输入条)
  // -----------------------------------------------------------------

  ImageAtomSelection? _imageSel;
  // -----------------------------------------------------------------
  // 链接工具条(官方 link-toolbar 对齐:光标进链接浮出
  // [编辑|复制|取消链接|加载预览|访问])
  // -----------------------------------------------------------------

  LinkCaretInfo? _linkCaret;
  OverlayEntry? _linkToolbarOverlay;

  void _onLinkCaret(LinkCaretInfo? info) {
    _linkCaret = info;
    if (info == null) {
      _linkToolbarOverlay?.remove();
      _linkToolbarOverlay = null;
      return;
    }
    if (_linkToolbarOverlay == null) {
      _showLinkToolbar();
    } else {
      _linkToolbarOverlay!.markNeedsBuild();
    }
  }

  /// 链接是否独占一段(加载预览仅此时可用:替换整段为裸 URL 经 cook
  /// 成 onebox —— 官方 show-preview 对行内链接同样隐藏)。
  bool _linkIsWholeParagraph(LinkCaretInfo info) {
    final editor = _editor;
    if (editor == null) return false;
    final block = editor.textBlockById(info.blockId);
    if (block == null || !block.isParagraph || block.containers.isNotEmpty) {
      return false;
    }
    final t = block.content.text;
    // info 可能是上一帧的(onLinkCaret 帧后上抛):删除中 end 会大于
    // 已变短的文本,substring 直接 RangeError 红屏刷屏 —— 陈旧即 false
    if (info.start < 0 || info.end > t.length || info.start > info.end) {
      return false;
    }
    return t.substring(0, info.start).trim().isEmpty &&
        t.substring(info.end).trim().isEmpty;
  }

  /// 浮层重建帧的陈旧 info 防御:块还在、区间仍在文本内才算活着
  /// (编辑/删除进行中先隐藏,帧后新 info 到达再现)。
  bool _linkCaretAlive(LinkCaretInfo info) {
    final editor = _editor;
    if (editor == null) return false;
    final block = editor.textBlockById(info.blockId);
    if (block == null) return false;
    return info.start >= 0 &&
        info.end <= block.content.length &&
        info.start <= info.end;
  }

  void _showLinkToolbar() {
    _linkToolbarOverlay = OverlayEntry(
      builder: (context) {
        final info = _linkCaret;
        if (info == null || !_linkCaretAlive(info)) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        final screen = MediaQuery.sizeOf(context);
        final href = info.href ?? '';

        // href 缩略标签(官方 visit 按钮的 translatedLabel 同款:剥站内
        // origin / mailto / https 前缀)
        var label = href;
        final origin = UrlHelper.resolveUrl('');
        if (origin.isNotEmpty && label.startsWith(origin)) {
          label = label.substring(origin.length);
          if (label.isEmpty) label = '/';
        }
        label = label.replaceFirst(RegExp(r'^(mailto:|https://)'), '');

        Widget btn(IconData icon, String tooltip, VoidCallback onTap) =>
            Tooltip(
              message: tooltip,
              // 桌面 hover 即弹提示 + 条重定位时残影叠字:加等待窗
              waitDuration: const Duration(milliseconds: 600),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(icon, size: 17, color: scheme.onSurfaceVariant),
                ),
              ),
            );

        const barH = 40.0;
        final top = info.rangeGlobal.top - barH - 6 < kToolbarHeight
            ? info.rangeGlobal.bottom + 6
            : info.rangeGlobal.top - barH - 6;

        // 水平锚定链接(此前居中屏幕,链接在左条飘中间):Align 比例
        // 定位 —— 链接中心在可用宽的比例映射到 -1..1,免测条宽且天然
        // 不越屏(官方 float-kit placement bottom + fallback 的近似)。
        final availW = screen.width - 24;
        final anchorX = info.rangeGlobal.center.dx.clamp(
          12.0,
          screen.width - 12.0,
        );
        final alignX = availW <= 0 ? 0.0 : (((anchorX - 12) / availW) * 2 - 1);

        return Positioned(
          left: 12,
          right: 12,
          top: top.clamp(8.0, screen.height - barH - 8),
          child: Align(
            alignment: Alignment(alignX.clamp(-1.0, 1.0), 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TapRegion(
                  // 与编辑器同组:点工具条不收光标态
                  groupId: 'rich-composer-link-toolbar',
                  child: _FloatingPanel(
                    maxHeight: barH + 4,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        btn(Icons.edit_rounded, '编辑链接', _editLinkAtCaret),
                        btn(Icons.copy_rounded, '复制链接', () {
                          Clipboard.setData(ClipboardData(text: href));
                          ScaffoldMessenger.maybeOf(this.context)?.showSnackBar(
                            const SnackBar(
                              content: Text('链接已复制'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        }),
                        btn(Icons.link_off_rounded, '移除链接', _unlinkAtCaret),
                        if (_linkIsWholeParagraph(info))
                          btn(
                            Icons.expand_rounded,
                            '加载预览',
                            _convertLinkToPreview,
                          ),
                        Container(
                          width: 1,
                          height: 20,
                          color: scheme.outlineVariant.withValues(alpha: 0.5),
                        ),
                        // 访问:图标 + href 缩略标签
                        Tooltip(
                          message: '访问链接',
                          child: InkWell(
                            onTap: href.isEmpty
                                ? null
                                : () => launchContentLink(this.context, href),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.open_in_new_rounded,
                                    size: 15,
                                    color: scheme.primary,
                                  ),
                                  const SizedBox(width: 5),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 150,
                                    ),
                                    child: Text(
                                      label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.primary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(_linkToolbarOverlay!);
  }

  /// 编辑链接:预填当前文字+href,提交 = 选中原区间 → 删 → 插新
  /// [text](url)(insertMarkdownSnippet 同 cook 链,官方 replaceText
  /// 同语义)。
  Future<void> _editLinkAtCaret() async {
    final info = _linkCaret;
    final editor = _editor;
    if (info == null || editor == null || !_linkCaretAlive(info)) {
      return;
    }
    final result = await showLinkInsertDialog(
      context,
      initialText: info.text,
      initialUrl: info.href,
      editing: true,
    );
    if (result == null || !mounted) return;
    final url = result['url'] ?? '';
    if (url.isEmpty) return;
    final text = (result['text'] ?? '').trim();
    editor.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: info.blockId, offset: info.start),
        extent: EditorPosition(blockId: info.blockId, offset: info.end),
      ),
    );
    await insertMarkdownSnippet('[${text.isEmpty ? url : text}]($url)');
  }

  /// 取消链接:对链接区间 removeLink(文字保留)。
  void _unlinkAtCaret() {
    final info = _linkCaret;
    final editor = _editor;
    if (info == null || editor == null || !_linkCaretAlive(info)) {
      return;
    }
    editor.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: info.blockId, offset: info.start),
        extent: EditorPosition(blockId: info.blockId, offset: info.end),
      ),
    );
    editor.removeLink();
    // 光标落链接尾(collapsed),工具条随 onLinkCaret(null) 自动收
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: info.blockId, offset: info.end),
      ),
    );
  }

  /// 加载预览(官方 show-preview):链接独占段 → 先取 onebox 数据种进
  /// cook 引擎(不种的话裸 URL 再 cook 仍是 loading 态链接,出不了
  /// 卡片),再整段替换为裸 URL 经 cook → onebox 岛。
  Future<void> _convertLinkToPreview() async {
    final info = _linkCaret;
    final editor = _editor;
    if (info == null || editor == null || !_linkCaretAlive(info)) {
      return;
    }
    final href = info.href;
    if (href == null || href.isEmpty) return;
    if (!_linkIsWholeParagraph(info)) return;
    final block = editor.textBlockById(info.blockId);
    if (block == null) return;

    final cookService = DiscourseCookService();
    final cooked = await cookService.cook(href);
    if (cooked != null) {
      // 取回 onebox HTML 种进引擎(内部去重,失败静默 —— 拿不到数据
      // 时下面的插入产物仍是可编辑裸链接,无损)
      await cookService.resolveOneboxes(cooked);
    }
    if (!mounted) return;

    // 选中整段内容(含链接前后空白)→ 粘贴语义替换为 onebox 岛
    editor.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: info.blockId, offset: 0),
        extent: EditorPosition(
          blockId: info.blockId,
          offset: block.content.length,
        ),
      ),
    );
    await insertMarkdownSnippet(href);
  }

  // -----------------------------------------------------------------
  // onebox 工具条(官方 onebox-toolbar:复制 | 移除预览 | 访问)
  // -----------------------------------------------------------------

  IslandSelection? _islandSel;
  OverlayEntry? _oneboxToolbarOverlay;

  /// 岛的 onebox 身份:OneboxNode(外链卡)恒有 url;QuoteCardNode 仅
  /// oneboxUrl 标记非空(站内话题 onebox 展开物)时算 —— 真引用卡不出。
  String? _oneboxUrlOf(IslandBlock island) => switch (island.node) {
        OneboxNode(:final url) => (url == null || url.isEmpty) ? null : url,
        QuoteCardNode(:final oneboxUrl) =>
          (oneboxUrl == null || oneboxUrl.isEmpty) ? null : oneboxUrl,
        _ => null,
      };

  void _onIslandSelected(IslandSelection? sel) {
    _islandSel = sel;
    final url = sel == null ? null : _oneboxUrlOf(sel.island);
    if (url == null) {
      _oneboxToolbarOverlay?.remove();
      _oneboxToolbarOverlay = null;
      return;
    }
    if (_oneboxToolbarOverlay == null) {
      _showOneboxToolbar();
    } else {
      _oneboxToolbarOverlay!.markNeedsBuild();
    }
  }

  void _showOneboxToolbar() {
    _oneboxToolbarOverlay = OverlayEntry(builder: (context) {
      final sel = _islandSel;
      final url = sel == null ? null : _oneboxUrlOf(sel.island);
      if (sel == null || url == null) return const SizedBox.shrink();
      final scheme = Theme.of(context).colorScheme;
      final screen = MediaQuery.sizeOf(context);

      Widget btn(IconData icon, String tooltip, VoidCallback onTap) =>
          Tooltip(
            message: tooltip,
            waitDuration: const Duration(milliseconds: 600),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(icon, size: 17, color: scheme.onSurfaceVariant),
              ),
            ),
          );

      const barH = 40.0;
      final rect = sel.globalRect;
      final top = rect.top - barH - 6 < kToolbarHeight
          ? rect.bottom + 6
          : rect.top - barH - 6;
      final availW = screen.width - 24;
      final anchorX = rect.center.dx.clamp(12.0, screen.width - 12.0);
      final alignX =
          availW <= 0 ? 0.0 : (((anchorX - 12) / availW) * 2 - 1);

      return Positioned(
        left: 12,
        right: 12,
        top: top.clamp(8.0, screen.height - barH - 8),
        child: Align(
          alignment: Alignment(alignX.clamp(-1.0, 1.0), 0),
          child: TapRegion(
            groupId: 'rich-composer-onebox-toolbar',
            child: _FloatingPanel(
              maxHeight: barH + 4,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                btn(Icons.copy_rounded, '复制链接', () {
                  Clipboard.setData(ClipboardData(text: url));
                  ScaffoldMessenger.maybeOf(this.context)?.showSnackBar(
                    const SnackBar(
                      content: Text('链接已复制'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }),
                btn(Icons.close_fullscreen_rounded, '移除预览',
                    _removeOneboxPreview),
                Container(
                  width: 1,
                  height: 20,
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
                btn(Icons.open_in_new_rounded, '访问链接',
                    () => launchContentLink(this.context, url)),
              ]),
            ),
          ),
        ),
      );
    });
    Overlay.of(context).insert(_oneboxToolbarOverlay!);
  }

  /// 移除预览(官方 removePreview):onebox 岛 → 可编辑链接文字段
  /// (文本=href 的 link mark;裸 URL 序列化规则保 raw 不变)。
  void _removeOneboxPreview() {
    final sel = _islandSel;
    final editor = _editor;
    if (sel == null || editor == null) return;
    final url = _oneboxUrlOf(sel.island);
    if (url == null) return;
    final content = EditableTextContent(
      text: url,
      marks: [
        MarkSpan(start: 0, end: url.length, kind: MarkKind.link, attr: url),
      ],
    );
    editor.replaceIsland(sel.island.id, [
      TextBlock(id: editor.nextBlockId(), content: content),
    ]);
  }

  OverlayEntry? _imageOverlay;

  /// alt 输入条展开态与草稿(浮层重建间保持)。
  bool _altExpanded = false;
  TextEditingController? _altController;
  final FocusNode _altFocus = FocusNode(debugLabel: 'image-alt');

  void _onImageAtomSelectionChanged(ImageAtomSelection? sel) {
    _imageSel = sel;
    if (sel == null) {
      _removeImageOverlay();
      return;
    }
    if (_imageOverlay == null) {
      _showImageOverlay();
    } else {
      _imageOverlay!.markNeedsBuild();
    }
  }

  void _removeImageOverlay() {
    _imageOverlay?.remove();
    _imageOverlay = null;
    _altExpanded = false;
    _altController?.dispose();
    _altController = null;
  }

  // -----------------------------------------------------------------
  // grid 内图片(交互已内聚在子包 EditorImageGrid:删除/移出/alt/模式
  // 全在网格容器里 —— 官方 composer 同构。宿主只管查看器。)
  // -----------------------------------------------------------------

  /// grid 内已子选中的图再点 → 查看器(图片原子同链路)。
  Future<void> _openGridImageViewer(GridImageSelection sel) async {
    await _openImageRun(
      sel.image,
      heroTag: 'rich_composer_grid_${sel.islandId}_${sel.imageIndex}',
    );
  }

  /// 展开 alt 输入(官方 expandInput:展开后 select() 全选)。
  /// autofocus 在 OverlayEntry 反复 markNeedsBuild 场景不可靠(重建期
  /// 焦点可能被编辑器抢回),帧后显式 requestFocus + 全选。
  void _expandAltInput() {
    final img = _imageSel?.image;
    if (img == null) return;
    _altExpanded = true;
    _altController?.dispose();
    _altController = TextEditingController(text: img.alt);
    _imageOverlay?.markNeedsBuild();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_altExpanded || _altController == null) return;
      _altFocus.requestFocus();
      _altController!.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _altController!.text.length,
      );
    });
  }

  void _showImageOverlay() {
    _altExpanded = false;
    _imageOverlay = OverlayEntry(
      builder: (context) {
        final sel = _imageSel;
        if (sel == null) return const SizedBox.shrink();
        final rect = sel.globalRect;
        final img = sel.image;
        final screen = MediaQuery.sizeOf(context);
        final scheme = Theme.of(context).colorScheme;

        final effScale = (img.scale ?? 100).round();
        final hasWxH =
            (img.origWidth ?? img.width) != null &&
            (img.origHeight ?? img.height) != null;

        // 键盘上方安全底(移动端浮层不压键盘)
        final safeBottom =
            screen.height - MediaQuery.viewInsetsOf(context).bottom - 8;

        // 上:工具条(顶部空间不足翻到图下方与 alt 条错层)
        const barH = 44.0; // 40px 图标钮 + 面板边
        final barAbove = rect.top - barH - 6 >= 8;
        final barLeft = rect.left.clamp(8.0, screen.width - 220.0);
        final barTop = (barAbove ? rect.top - barH - 6 : rect.bottom + 6).clamp(
          8.0,
          (safeBottom - barH).clamp(8.0, double.infinity),
        );

        // 下:alt 条(clamp 进安全区;放不下与 bar 同侧错层)
        final altWidth = rect.width.clamp(180.0, 320.0);
        const altH = 40.0;
        final altTop = (barAbove ? rect.bottom + 6 : rect.bottom + barH + 12)
            .clamp(8.0, (safeBottom - altH).clamp(8.0, double.infinity));

        Widget iconBtn(
          IconData icon,
          String tooltip, {
          VoidCallback? onTap,
          Color? color,
        }) {
          final enabled = onTap != null;
          return Tooltip(
            message: tooltip,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                // 18 + 11×2 = 40px 触控目标(移动可点性;桌面统一无碍)
                padding: const EdgeInsets.all(11),
                child: Icon(
                  icon,
                  size: 18,
                  color: enabled
                      ? (color ?? scheme.onSurfaceVariant)
                      : scheme.onSurfaceVariant.withValues(alpha: 0.3),
                ),
              ),
            ),
          );
        }

        return Stack(
          children: [
            Positioned(
              left: barLeft,
              top: barTop,
              child: _FloatingPanel(
                maxHeight: barH,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    iconBtn(
                      Symbols.zoom_out_rounded,
                      '缩小',
                      onTap: hasWxH && effScale > 50
                          ? () => _scaleImage(-25)
                          : null,
                    ),
                    iconBtn(
                      Symbols.zoom_in_rounded,
                      '放大',
                      onTap: hasWxH && effScale < 100
                          ? () => _scaleImage(25)
                          : null,
                    ),
                    Container(
                      width: 1,
                      height: 20,
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    iconBtn(
                      Symbols.grid_view_rounded,
                      '加入网格',
                      onTap: _addSelectedImageToGrid,
                    ),
                    iconBtn(
                      Symbols.delete_outline_rounded,
                      '删除图片',
                      onTap: _deleteSelectedImage,
                      color: scheme.error,
                    ),
                  ],
                ),
              ),
            ),
            // alt 输入条(官方 image-alt-text-input:collapsed 单行 1.5em →
            // 展开 4.25em textarea **变高**;Enter 保存收起、Shift+Enter 换行、
            // Esc 还原;展开即聚焦全选)
            Positioned(
              left: rect.left.clamp(8.0, screen.width - altWidth - 8),
              top: altTop,
              width: altWidth,
              child: _FloatingPanel(
                maxHeight: 108,
                child: _altExpanded
                    ? Focus(
                        onKeyEvent: (node, event) {
                          if (event is! KeyDownEvent) {
                            return KeyEventResult.ignored;
                          }
                          if (event.logicalKey == LogicalKeyboardKey.escape) {
                            // Esc:还原收起(不保存)
                            _altExpanded = false;
                            _altController?.text = img.alt;
                            _imageOverlay?.markNeedsBuild();
                            return KeyEventResult.handled;
                          }
                          // Enter 保存收起(官方 keydown Enter → onClose);
                          // Shift+Enter 留给换行。多行 TextField 的 Enter
                          // 默认换行、onSubmitted 不触发,必须在这拦。
                          if (event.logicalKey == LogicalKeyboardKey.enter &&
                              !HardwareKeyboard.instance.isShiftPressed) {
                            _saveAlt(_altController?.text ?? '');
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: TextField(
                          controller: _altController ??= TextEditingController(
                            text: img.alt,
                          ),
                          focusNode: _altFocus,
                          autofocus: true,
                          // 官方展开 4.25em ≈ 3 行:展开 = 变高
                          minLines: 3,
                          maxLines: 3,
                          style: const TextStyle(fontSize: 13, height: 1.5),
                          decoration: const InputDecoration(
                            hintText: '替代文本',
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            border: InputBorder.none,
                          ),
                          onTapOutside: (_) => _saveAlt(_altController!.text),
                        ),
                      )
                    : InkWell(
                        onTap: _expandAltInput,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Text(
                            img.alt.isEmpty ? '替代文本' : img.alt,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: img.alt.isEmpty
                                  ? scheme.onSurfaceVariant.withValues(
                                      alpha: 0.6,
                                    )
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        );
      },
    );
    Overlay.of(context).insert(_imageOverlay!);
  }

  /// 缩放 ±25(官方 SCALE_STEP;50-100 clamp)。显示尺寸按 cook engine
  /// 同款 floor 乘法;origWidth/origHeight 固化 raw 声明尺寸,序列化写
  /// `|WxH, N%`。reselect 保持整选 → 浮层原位刷新 disabled 态。
  void _scaleImage(int delta) {
    final editor = _editor;
    final sel = _imageSel;
    if (editor == null || sel == null) return;
    final img = sel.image;
    final next = ((img.scale ?? 100) + delta).clamp(50, 100).round();
    final origW = img.origWidth ?? img.width;
    final origH = img.origHeight ?? img.height;
    if (origW == null || origH == null) return;
    editor.replaceAtomAt(
      sel.blockId,
      sel.offset,
      img.copyWith(
        scale: next.toDouble(),
        origWidth: origW,
        origHeight: origH,
        width: (origW * next / 100).floorToDouble(),
        height: (origH * next / 100).floorToDouble(),
      ),
      reselect: true,
    );
  }

  void _saveAlt(String text) {
    final editor = _editor;
    final sel = _imageSel;
    _altExpanded = false;
    if (editor == null || sel == null) {
      _imageOverlay?.markNeedsBuild();
      return;
    }
    final t = text.trim();
    if (t == sel.image.alt) {
      _imageOverlay?.markNeedsBuild();
      return;
    }
    editor.replaceAtomAt(
      sel.blockId,
      sel.offset,
      sel.image.copyWith(alt: t),
      reselect: true,
    );
  }

  void _deleteSelectedImage() {
    // 选区恰是原子区间,deleteSelection 删图;选中事件自动回 null 关浮层
    _editor?.deleteSelection();
  }

  void _addSelectedImageToGrid() {
    final editor = _editor;
    final sel = _imageSel;
    if (editor == null || sel == null) return;
    addImageAtomToGrid(editor, sel.blockId, sel.offset);
  }

  /// 已选中的图再点 → 图片查看器(upload:// 先解析;missing 静默不开)。
  /// 查看器是透明路由全屏页,盖不住 app Overlay 里的工具条浮层 —— 打开
  /// 期间移除浮层,关闭后按当前选中态恢复。
  Future<void> _openImageViewer(ImageAtomSelection sel) async {
    _removeImageOverlay();
    await _openImageRun(
      sel.image,
      heroTag: 'rich_composer_img_${sel.blockId}_${sel.offset}',
    );
    // 返回后选中若还在(编辑器选区未动),浮层恢复
    if (mounted && _imageSel != null && _imageOverlay == null) {
      _showImageOverlay();
    }
  }

  /// 打开 ImageRun 的查看器(原子/grid 子选中共用):upload:// 缓存/
  /// 异步解析,missing 静默不开;await 到查看器关闭。
  Future<void> _openImageRun(ImageRun img, {required String heroTag}) async {
    final raw = img.lightboxUrl ?? img.origSrc ?? img.src;
    String resolved;
    if (DiscourseImageUtils.isUploadUrl(raw)) {
      final r =
          DiscourseImageUtils.getCachedUploadUrl(raw) ??
          await DiscourseImageUtils.resolveUploadUrl(raw);
      if (r == null || !mounted) return;
      resolved = r;
    } else {
      resolved = UrlHelper.resolveUrlWithCdn(raw);
    }
    if (!mounted) return;
    await DiscourseImageUtils.openViewer(
      context: context,
      imageUrl: DiscourseImageUtils.getOriginalUrl(resolved),
      heroTag: heroTag,
    );
  }

  /// 单击可编辑原子:date chip → 属性对话框 → replaceAtomAt。
  Future<void> _onAtomTap(String blockId, int offset, InlineNode atom) async {
    final editor = _editor;
    if (editor == null || atom is! LocalDateRun) return;
    final next = await showLocalDateEditDialog(context, initial: atom);
    if (next == null || !mounted) return;
    editor.replaceAtomAt(blockId, offset, next);
  }

  /// 点 details/callout 壳标题 → 弹单行输入改标题(groupId 不变,壳
  /// Element 复用,只有属性变;undo 一步)。
  Future<void> _editContainerTitle(ContainerFrame frame) async {
    final editor = _editor;
    if (editor == null) return;

    // Callout:全属性原位编辑(类型/标题/折叠三态),与插入同一对话框
    if (frame is CalloutFrame) {
      final spec = await showCalloutEditDialog(
        context,
        type: frame.typeRaw,
        title: frame.title ?? '',
        foldable: frame.foldable,
      );
      if (spec == null || !mounted) return;
      final title = spec.title.trim();
      final next = CalloutFrame(
        groupId: frame.groupId,
        kind: CalloutKind.fromType(spec.type),
        typeRaw: spec.type,
        title: title.isEmpty ? null : title,
        foldable: spec.foldable,
      );
      if (next != frame) {
        editor.updateContainerFrame(frame.groupId, next);
      }
      return;
    }

    if (frame is! DetailsFrame) return;
    final text = await showAppDialog<String>(
      context: context,
      builder: (ctx) =>
          _SingleLineInputDialog(title: '折叠标题', initialText: frame.summary),
    );
    if (text == null || text == frame.summary || !mounted) return;
    editor.updateContainerFrame(
      frame.groupId,
      DetailsFrame(groupId: frame.groupId, summary: text, open: frame.open),
    );
  }

  /// 插入 Callout:属性对话框 → Obsidian 语法经 cook 容器化。
  Future<void> _insertCallout() async {
    final spec = await showCalloutEditDialog(context);
    if (spec == null || !mounted) return;
    await insertMarkdownSnippet('> ${spec.headerMarkdown}\n> 内容');
  }

  /// markdown 多行输入对话框(插入片段/岛编辑共用;showAppDialog 统一
  /// app 弹窗风格)。
  Future<String?> _showMarkdownDialog({
    required String title,
    required String confirmLabel,
    String? initialText,
  }) {
    // controller 必须归对话框 State 所有(LinkInsertDialog 同款):
    // pop 后 future 立即 resolve,但退场动画还在播,外部立刻 dispose
    // 会让动画帧里的 TextField 摸已析构 controller(真机崩溃实锤,
    // 并连带触发 Element 半更新 → _dependents 断言红屏)。
    return showAppDialog<String>(
      context: context,
      builder: (ctx) => _MarkdownInputDialog(
        title: title,
        confirmLabel: confirmLabel,
        initialText: initialText,
      ),
    );
  }

  /// 上传完成后在光标处插入图片原子(官方 inline image 同语义;渲染层
  /// data-orig-src 异步解析)。scale 留 null(=100 档,序列化不写后缀,
  /// raw 形态与官方上传一致);选中图后工具条可缩放。
  void insertUploadedImage({
    required String shortUrl,
    String alt = '',
    int? width,
    int? height,
  }) {
    final editor = _editor;
    if (editor == null) return;
    final sel = editor.selection;
    // 从未聚焦 / 光标停在岛上(整选态):落到最后一个文本块尾
    if (sel == null || editor.textBlockById(sel.extent.blockId) == null) {
      final lastText = editor.blocks.lastWhere(
        (b) => b is TextBlock,
        orElse: () => editor.blocks.last,
      );
      if (lastText is! TextBlock) return;
      editor.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(
            blockId: lastText.id,
            offset: lastText.selectionLength,
          ),
        ),
      );
    }
    editor.insertAtom(
      ImageRun(
        src: shortUrl,
        alt: alt,
        width: width?.toDouble(),
        height: height?.toDouble(),
      ),
    );
  }

  // -----------------------------------------------------------------
  // build
  // -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final editor = _editor;
    if (_importing || editor == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: LoadingSpinner(size: 24),
        ),
      );
    }

    final isEmpty = _lastIsEmpty = _computeIsEmpty();

    return Column(
      children: [
        Expanded(
          child: CompositedTransformTarget(
            link: _mentionLink,
            // 滚动结构:header(标题/标签等元数据)与编辑器同在一个
            // CustomScrollView —— 手机上写正文时头部随内容滚出屏,
            // 编辑区满格;头部高度恒定,零跳变。
            // 不用 SliverFillRemaining:它对 child 调 getMaxIntrinsicHeight
            // (整文档每帧算内在高度,岛内自定义 RenderObject 不支持时
            // 会被 tight 布局裁内容);编辑器 minHeight 仍由显式
            // ConstrainedBox 撑(viewport 高 - 上下 padding)——
            // ConstrainedBox.enforce 不受 Stack loosen 影响(**不能换
            // Align 等 loosen 约束的 widget**,编辑器会收缩回内容尺寸
            // —— "只有第一行能唤起键盘"的根因)。代价:有 header 时
            // 空文档也能把 header 滚出屏(编辑区恒可满屏,可接受)。
            child: LayoutBuilder(
              builder: (context, viewport) => CustomScrollView(
                controller: _scrollController,
                slivers: [
                  if (widget.header != null)
                    SliverToBoxAdapter(child: widget.header),
                  SliverToBoxAdapter(
                    // Listener:表情面板开着时点编辑区任意处 → 切回键盘态
                    // (原始 down,不进手势竞技场不干扰编辑器 tap)。
                    // 只包编辑器区不包 header:点标题不走该路径。
                    // Focus(_editorAreaFocus):编辑区**祖先**焦点 ——
                    // ChatBottomPanelContainer 的 inputFocusNode 挂它,
                    // 表格 cell/alt 输入等子输入框聚焦时祖先仍 hasFocus,
                    // 容器不误判"离开输入区"收键盘(表格 cell 键盘被
                    // 秒收的根因)。
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) => _onEditorAreaPointerDown(),
                      child: Focus(
                        focusNode: _editorAreaFocus,
                        canRequestFocus: false,
                        skipTraversal: true,
                        child: Stack(
                          children: [
                            ConstrainedBox(
                              // padding 在内,故 min = 全视口高
                              constraints: BoxConstraints(
                                minHeight: viewport.maxHeight,
                              ),
                              child: Padding(
                                // 水平 20 = 与 header 标题对齐(源码模式
                                // 同值);垂直 12 兼吸收表格悬挂柄溢出
                                padding: const EdgeInsets.fromLTRB(
                                    20, 12, 20, 12),
                                child: FluxdoEditor(
                                  state: editor,
                                  autofocus: true,
                                  focusNode: _editorFocus,
                                  nodeFactory: _nodeFactory ??=
                                      buildComposerNodeFactory(context),
                                  // 粘贴导入:剪贴板 markdown → cook 链路 →
                                  // 编辑块(失败/不可用时 FluxdoEditor 内部
                                  // 降级纯文本粘贴)
                                  markdownImporter: markdownToDoc,
                                  virtualPointer: _virtualPointer,
                                  // 富粘贴:剪贴板 text/html(网页/Word)
                                  // → markdown 清洗 → 同一条 cook 导入链;
                                  // 无 html/转换落空回落上面纯文本路径
                                  richPasteImporter: _importRichPaste,
                                  // 双击岛 → 源码编辑对话框
                                  onIslandEditRequest: _editIsland,
                                  // 点 details/callout 壳标题 → 原位改标题
                                  onContainerTitleEdit: _editContainerTitle,
                                  // 表格 cell 原位编辑 → 重建 markdown 经
                                  // cook 替换
                                  onTableEdited: _onTableEdited,
                                  // 代码块岛内原位编辑 → 结构化节点直换
                                  // (不经 cook)
                                  onCodeBlockEdited: _onCodeBlockEdited,
                                  // 单击 date chip → 属性编辑对话框
                                  onAtomTap: _onAtomTap,
                                  // 图片原子选中 → 浮出工具条(缩放/删除/
                                  // 加网格)+ alt 条
                                  onImageAtomSelectionChanged:
                                      _onImageAtomSelectionChanged,
                                  // 已选中的图再点 → 打开查看器
                                  onImageAtomOpenRequest: _openImageViewer,
                                  // grid 内图交互内聚在子包;宿主只接查看器
                                  onGridImageOpenRequest: _openGridImageViewer,
                                  // 光标全局矩形上抛(斜杠/mention 浮层锚定
                                  // 用)。矩形变化且浮层活跃 → 重建重锚定:
                                  // 浮层首建发生在文档变更回调里(同步),
                                  // 彼时矩形还是上一帧旧值,不跟随的话初始
                                  // 位置错、直到下次 markNeedsBuild(如按
                                  // 上下键)才跳到正确位置。
                                  // collapsed 光标进出链接 → 链接工具条
                                  // (编辑/复制/取消链接/预览/访问)
                                  onLinkCaret: _onLinkCaret,
                                  // 岛整选 → onebox 工具条(复制/移除
                                  // 预览/访问)
                                  onIslandSelected: _onIslandSelected,
                                  onCaretRectChanged: (r) {
                                    if (r == _caretGlobalRect) return;
                                    _caretGlobalRect = r;
                                    _slashOverlay?.markNeedsBuild();
                                    _mentionOverlay?.markNeedsBuild();
                                  },
                                  // 浮层激活时接管上下/回车/Esc(否则被编辑
                                  // 器拿去移光标)
                                  keyEventInterceptor: _interceptKeyEvent,
                                  baseTextStyle: Theme.of(
                                    context,
                                  ).textTheme.bodyLarge?.copyWith(height: 1.5),
                                ),
                              ),
                            ),
                            if (isEmpty)
                              Positioned(
                                // 与编辑区 padding 同源:水平 20(对齐
                                // header 标题),垂直 12 + 4(块 vertical
                                // padding)= 首行文字基线
                                left: 20,
                                top: 16,
                                child: IgnorePointer(
                                  child: Text(
                                    widget.hintText,
                                    style: Theme.of(context).textTheme.bodyLarge
                                        ?.copyWith(
                                          height: 1.5,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.outline,
                                        ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 底部属性条(分类/标签/字数常驻,不随滚动离场)
        if (widget.metaBar != null) widget.metaBar!,
        // 单一底部工具栏(与 MarkdownToolbar 同构:左表情胶囊 + 中部
        // 可滚工具 + 右胶囊;FaIcon 图标语言 + compact 密度)
        _RichToolbar(
          state: editor,
          isEmojiPanelVisible: _showEmojiPanel,
          onToggleEmoji: _toggleEmojiPanel,
          // 桌面端表情按钮由弹层锚点包裹(跟随定位 + toggle 无闪烁)
          emojiPopover: _emojiPopover,
          uploading: _uploadingCount > 0,
          onPickImage: _pickAndUploadImages,
          onInsertLink: _insertLink,
          onInsertMenu: _showInsertMenu,
          // 手势光标(虚拟指针):幽灵光标跟手+实光标吸附+贴边自动滚;
          // 桌面有物理键盘,不占工具栏
          onPointerStart: _isDesktop
              ? null
              : ({required extend}) => _virtualPointer.start(extend: extend),
          onPointerMove: _isDesktop ? null : _virtualPointer.moveBy,
          onPointerEnd: _isDesktop ? null : _virtualPointer.end,
          onSwitchToSource: widget.onSwitchToSource == null
              ? null
              : () {
                  // 先落盘再切换:controller.text 即最新 markdown,
                  // 宿主换 MarkdownEditor 后内容无缝衔接
                  flushToController();
                  // 关键:两编辑器共用同一 focusNode,富文本用自管 IME
                  // (EditorImeClient 持全局 TextInput 连接)。切换是
                  // AnimatedSwitcher 150ms 动画,期间富↔源并存;焦点始终
                  // 停在同一 focusNode(hasFocus 不变)→ 富文本 _ime.detach
                  // (只在失焦时触发)不会跑 → 源码 TextField 抢不到有效
                  // 连接 = 切过去无法输入/删除。unfocus 主动让富文本失焦
                  // 放开连接,再延迟交棒回同一 node —— 彼时富文本已
                  // 退场,挂着它的源码 TextField attach 即干净重连,
                  // 切完立刻能打能删(不用点一下正文)。
                  _editorFocus.unfocus();
                  widget.onSwitchToSource!();
                  if (!_ownsFocus) {
                    final node = _editorFocus;
                    final controller = widget.controller;
                    // 宿主已换 KeyedSubtree 直切(无 150ms 并存窗口),
                    // 80ms 只等本帧 dispose 落定
                    Timer(const Duration(milliseconds: 80), () {
                      // 本 State 已 dispose,不查 mounted;node/controller
                      // 归宿主所有。220ms 内页面整体退场会撞已 dispose
                      // 对象 —— fire-and-forget 场景,吞掉即可。
                      try {
                        if (!controller.selection.isValid) {
                          controller.selection = TextSelection.collapsed(
                            offset: controller.text.length,
                          );
                        }
                        if (node.canRequestFocus) node.requestFocus();
                      } catch (_) {}
                    });
                  }
                },
        ),
        // 键盘/表情面板容器(MarkdownEditor 同款 ChatBottomPanelContainer:
        // 键盘态=原生键盘高占位、表情态=等高面板、无键盘=底部安全区;
        // 键盘⇄表情切换零跳变,编辑器自管 IME 一样适用 —— 容器只看
        // viewInsets/原生键盘监听,不关心输入连接归属)
        ChatBottomPanelContainer<_RichPanelType>(
          controller: _panelController,
          inputFocusNode: _editorAreaFocus,
          otherPanelWidget: (type) => type == _RichPanelType.emoji
              ? _buildEmojiPanel()
              : const SizedBox.shrink(),
          onPanelTypeChange: (panelType, data) {
            _RichPanelType next;
            switch (panelType) {
              case ChatBottomPanelType.none:
                next = _RichPanelType.none;
              case ChatBottomPanelType.keyboard:
                next = _RichPanelType.keyboard;
              case ChatBottomPanelType.other:
                next = data ?? _RichPanelType.none;
            }
            // 表情面板意图保持中,忽略焦点竞争引发的状态请求
            if (_intendedPanel != _RichPanelType.none &&
                next != _intendedPanel) {
              return;
            }
            final wasEmoji = _currentPanel == _RichPanelType.emoji;
            final isEmoji = next == _RichPanelType.emoji;
            setState(() => _currentPanel = next);
            if (wasEmoji != isEmoji) {
              if (!isEmoji) _intendedPanel = _RichPanelType.none;
              if (_showEmojiPanel != isEmoji) {
                setState(() => _showEmojiPanel = isEmoji);
                widget.onEmojiPanelChanged?.call(isEmoji);
              }
            }
          },
          customPanelContainer: (panelType, data) {
            final surface = Theme.of(context).colorScheme.surface;
            // 表情面板意图保持中,无论容器报什么态都续显面板
            if (_intendedPanel == _RichPanelType.emoji &&
                panelType != ChatBottomPanelType.other) {
              return ColoredBox(color: surface, child: _buildEmojiPanel());
            }
            switch (panelType) {
              case ChatBottomPanelType.keyboard:
                return _KeyboardPlaceholder(
                  color: surface,
                  nativeKeyboardHeight: _panelController.keyboardHeight,
                );
              case ChatBottomPanelType.other:
                if (data == _RichPanelType.emoji) {
                  return ColoredBox(color: surface, child: _buildEmojiPanel());
                }
                return const SizedBox.shrink();
              case ChatBottomPanelType.none:
                return _SafeAreaPlaceholder(color: surface);
            }
          },
        ),
      ],
    );
  }
}

/// 富 composer 的统一底部工具栏。
///
/// 视觉与 [MarkdownToolbar] 完全同构:左右胶囊(圆角 22 +
/// surfaceContainerHighest 0.45)+ 中部渐隐可滚工具排 + FaIcon 16 +
/// onSurfaceVariant/primary 双态 + compact 密度。区别只在命令目标:
/// 纯文本改 controller.text,这里调 EditorState 命令。
///
/// 激活态签名驱动重建(EditorToolbar 同款):纯打字签名不变零重建。
/// 富 composer 面板类型(ChatBottomPanelContainer 泛型)。
enum _RichPanelType { none, keyboard, emoji }

/// 键盘占位:原生键盘高(与表情面板同高度源,切换等高零跳变)。
class _KeyboardPlaceholder extends StatelessWidget {
  const _KeyboardPlaceholder({
    required this.color,
    required this.nativeKeyboardHeight,
  });

  final Color color;
  final double nativeKeyboardHeight;

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return ColoredBox(
      color: color,
      child: SizedBox(
        width: double.infinity,
        height: max(nativeKeyboardHeight, safeBottom),
      ),
    );
  }
}

/// 无键盘时的底部安全区占位(全面屏 home indicator 区,工具栏不贴底)。
class _SafeAreaPlaceholder extends StatelessWidget {
  const _SafeAreaPlaceholder({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return ColoredBox(
      color: color,
      child: SizedBox(width: double.infinity, height: safeBottom),
    );
  }
}

class _RichToolbar extends StatefulWidget {
  const _RichToolbar({
    required this.state,
    required this.isEmojiPanelVisible,
    required this.onToggleEmoji,
    required this.uploading,
    required this.onPickImage,
    required this.onInsertLink,
    required this.onInsertMenu,
    this.onPointerStart,
    this.onPointerMove,
    this.onPointerEnd,
    this.onSwitchToSource,
    this.emojiPopover,
  });

  final EditorState state;
  final bool isEmojiPanelVisible;
  final VoidCallback onToggleEmoji;
  final bool uploading;
  final VoidCallback onPickImage;
  final VoidCallback onInsertLink;
  final void Function(BuildContext anchorContext) onInsertMenu;

  /// 桌面端表情悬浮弹层控制器(非 null 时表情按钮被锚点包裹)
  final EmojiPopoverController? emojiPopover;

  /// 手势光标(虚拟指针):滑钮 pan 驱动浮动光标二维漂移;
  /// [onPointerStart] null 不显示。
  final bool Function({required bool extend})? onPointerStart;
  final ValueChanged<Offset>? onPointerMove;
  final VoidCallback? onPointerEnd;

  final VoidCallback? onSwitchToSource;

  @override
  State<_RichToolbar> createState() => _RichToolbarState();
}

typedef _Sig = ({
  int marksBits,
  int kindIndex,
  int headingLevel,
  bool ordered,
  bool inQuote,
});

class _RichToolbarState extends State<_RichToolbar> {
  late _Sig _sig = _compute();

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
  }

  @override
  void didUpdateWidget(covariant _RichToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onState);
      widget.state.addListener(_onState);
      _sig = _compute();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    final next = _compute();
    if (next != _sig && mounted) {
      setState(() => _sig = next);
    }
  }

  _Sig _compute() {
    final state = widget.state;
    final marks = state.effectiveMarksAtCaret();
    final sel = state.selection;
    final block = sel == null ? null : state.textBlockById(sel.extent.blockId);
    return (
      marksBits: marks.fold(0, (a, k) => a | (1 << k.index)),
      kindIndex: block?.kind.index ?? -1,
      headingLevel: block?.isHeading == true ? block!.headingLevel : 0,
      ordered: block?.isListItem == true && block!.ordered,
      inQuote: (block?.quoteDepth ?? 0) > 0,
    );
  }

  bool _hasMark(MarkKind kind) => (_sig.marksBits & (1 << kind.index)) != 0;

  /// tooltip 快捷键后缀:桌面端按平台标注(⌘B / Ctrl+B,事实源
  /// composer_shortcuts.dart);移动端无物理键盘不标。
  static String _tip(String label, String toolId) {
    if (!PlatformUtils.isDesktop) return label;
    return '$label${composerShortcutHint(toolId) ?? ''}';
  }

  /// 行内剧透:有选区 → toggle mark;折叠光标 → 插占位文字并整选
  /// (官方 rich editor inputRule 同款:立即可打字覆盖占位)。
  void _toggleInlineSpoiler() {
    final state = widget.state;
    final sel = state.selection;
    if (sel != null && !sel.isCollapsed) {
      state.toggleMark(MarkKind.spoilerInline);
      return;
    }
    if (sel == null) return;
    final block = state.textBlockById(sel.extent.blockId);
    if (block == null) return;
    const placeholder = '剧透内容';
    final start = sel.extent.offset;
    state.insertText(placeholder);
    // 选中占位并施加 mark(选区保留 —— 用户直接打字即替换)
    state.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: block.id, offset: start),
        extent: EditorPosition(
          blockId: block.id,
          offset: start + placeholder.length,
        ),
      ),
    );
    state.toggleMark(MarkKind.spoilerInline);
  }

  /// 表情按钮:桌面端(emojiPopover != null)由弹层锚点包裹,且不切
  /// keyboard 图标(那是移动端"切回键盘"语义,悬浮弹层不收键盘)
  Widget _buildEmojiButton(ThemeData theme, Color pillColor) {
    final popover = widget.emojiPopover;
    final button = _Pill(
      color: pillColor,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        icon: FaIcon(
          widget.isEmojiPanelVisible && popover == null
              ? FontAwesomeIcons.keyboard
              : FontAwesomeIcons.faceSmile,
          size: 20,
          color: widget.isEmojiPanelVisible
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        onPressed: widget.onToggleEmoji,
      ),
    );
    if (popover == null) return button;
    return EmojiPopoverAnchor(controller: popover, child: button);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.state;
    final pillColor = theme.colorScheme.surfaceContainerHighest.withValues(
      alpha: 0.45,
    );
    final isListItem = _sig.kindIndex == TextBlockKind.listItem.index;

    return Container(
      color: theme.colorScheme.surface,
      child: Focus(
        canRequestFocus: false,
        descendantsAreFocusable: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Row(
            children: [
              // 左:表情按钮(胶囊背景,固定)
              _buildEmojiButton(theme, pillColor),
              // 中:格式/插入工具(可滚动,无背景)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: FadingEdgeScrollView(
                    fadeLeft: true,
                    fadeRight: true,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _btn(
                            FontAwesomeIcons.bold,
                            _tip('粗体', 'bold'),
                            active: _hasMark(MarkKind.strong),
                            onTap: () => state.toggleMark(MarkKind.strong),
                          ),
                          _btn(
                            FontAwesomeIcons.italic,
                            _tip('斜体', 'italic'),
                            active: _hasMark(MarkKind.em),
                            onTap: () => state.toggleMark(MarkKind.em),
                          ),
                          _btn(
                            FontAwesomeIcons.strikethrough,
                            _tip('删除线', 'strikethrough'),
                            active: _hasMark(MarkKind.lineThrough),
                            onTap: () => state.toggleMark(MarkKind.lineThrough),
                          ),
                          _btn(
                            FontAwesomeIcons.code,
                            _tip('行内代码', 'inlineCode'),
                            active: _hasMark(MarkKind.inlineCode),
                            onTap: () => state.toggleMark(MarkKind.inlineCode),
                          ),
                          _btn(
                            FontAwesomeIcons.eyeSlash,
                            '行内剧透',
                            active: _hasMark(MarkKind.spoilerInline),
                            onTap: _toggleInlineSpoiler,
                          ),
                          _divider(theme),
                          _headingBtn(theme),
                          _btn(
                            FontAwesomeIcons.listUl,
                            _tip('无序列表', 'bulletList'),
                            active: isListItem && !_sig.ordered,
                            onTap: () => state.toggleList(ordered: false),
                          ),
                          _btn(
                            FontAwesomeIcons.listOl,
                            _tip('有序列表', 'numberedList'),
                            active: isListItem && _sig.ordered,
                            onTap: () => state.toggleList(ordered: true),
                          ),
                          _btn(
                            FontAwesomeIcons.quoteRight,
                            _tip('引用', 'quote'),
                            active: _sig.inQuote,
                            onTap: state.toggleQuote,
                          ),
                          _divider(theme),
                          _btn(
                            FontAwesomeIcons.link,
                            _tip('插入链接', 'link'),
                            onTap: widget.onInsertLink,
                          ),
                          widget.uploading
                              ? const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 12),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : _btn(
                                  FontAwesomeIcons.image,
                                  '上传图片',
                                  onTap: widget.onPickImage,
                                ),
                          // Builder:拿"+"按钮自己的 context —— 菜单锚定
                          // 按钮矩形(否则弹到编辑器区域角落)
                          Builder(
                            builder: (btnCtx) => _btn(
                              FontAwesomeIcons.circlePlus,
                              '插入块(表格/代码/公式…)',
                              onTap: () => widget.onInsertMenu(btnCtx),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // 手势光标(虚拟指针):按住滑钮二维漂移驱动光标
              if (widget.onPointerStart != null) ...[
                _Pill(
                  color: pillColor,
                  child: CursorSwipeControl(
                    onPointerStart: widget.onPointerStart,
                    onPointerMove: widget.onPointerMove,
                    onPointerEnd: widget.onPointerEnd,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              // 右:源码模式切换(胶囊背景;含当前模式徽标 —— 用户能
              // 看出自己在富文本态、点击去向是源码)
              if (widget.onSwitchToSource != null)
                _Pill(
                  color: pillColor,
                  child: Tooltip(
                    message: '切换到源码模式',
                    child: InkWell(
                      onTap: widget.onSwitchToSource,
                      borderRadius: BorderRadius.circular(18),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Symbols.code_rounded,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'MD',
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.0,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 工具组间竖分隔线(粗/斜/删/码 | 标题/列表/引用 | 链接/图/插入)。
  Widget _divider(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Container(
      width: 1,
      height: 18,
      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
    ),
  );

  /// 标准工具按钮(MarkdownToolbar._ToolbarButton 同参:FaIcon 16 +
  /// compact + onSurfaceVariant;激活态 primary)。
  Widget _btn(
    FaIconData icon,
    String tooltip, {
    bool active = false,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: FaIcon(icon, size: 16),
      onPressed: onTap,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        foregroundColor: active
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
        backgroundColor: active
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : null,
      ),
    );
  }

  /// 标题按钮:弹菜单选 H1-H3/正文(纯文本工具栏单 heading 按钮的
  /// 富文本版 —— 块级命令需要明确级别)。
  Widget _headingBtn(ThemeData theme) {
    final active = _sig.headingLevel > 0;
    return PopupMenuButton<int>(
      tooltip: '标题',
      position: PopupMenuPosition.over,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      color: theme.colorScheme.surfaceContainerLow,
      itemBuilder: (context) => [
        for (final level in [1, 2, 3])
          PopupMenuItem(
            value: level,
            child: Row(
              children: [
                Text(
                  '标题 $level',
                  style: TextStyle(
                    fontSize: 18.0 - level * 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                // 快捷键标注(桌面端;⌘⌥1.. / Ctrl+Alt+1..)
                if (PlatformUtils.isDesktop) ...[
                  const SizedBox(width: 12),
                  Text(
                    (composerShortcutHint('heading$level') ?? '').trim(),
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        const PopupMenuItem(value: 0, child: Text('正文')),
      ],
      onSelected: (level) => widget.state.setHeading(level == 0 ? null : level),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: active
            ? Text(
                'H${_sig.headingLevel}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              )
            : FaIcon(
                FontAwesomeIcons.heading,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
      ),
    );
  }
}

/// 工具栏两侧的胶囊背景容器(MarkdownToolbar._ToolbarPill 同款)。
class _Pill extends StatelessWidget {
  const _Pill({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.all(2),
      child: child,
    );
  }
}

/// markdown 多行输入对话框(controller 归本 State 所有 —— 退场动画期
/// 仍存活,dispose 时机正确)。
class _MarkdownInputDialog extends StatefulWidget {
  const _MarkdownInputDialog({
    required this.title,
    required this.confirmLabel,
    this.initialText,
  });

  final String title;
  final String confirmLabel;
  final String? initialText;

  @override
  State<_MarkdownInputDialog> createState() => _MarkdownInputDialogState();
}

class _MarkdownInputDialogState extends State<_MarkdownInputDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLines: 10,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(
            hintText: '任意 Discourse markdown/bbcode…',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 单行输入对话框(壳标题编辑用;controller 生命周期同上)。
class _SingleLineInputDialog extends StatefulWidget {
  const _SingleLineInputDialog({
    required this.title,
    required this.initialText,
  });

  final String title;
  final String initialText;

  @override
  State<_SingleLineInputDialog> createState() => _SingleLineInputDialogState();
}

class _SingleLineInputDialogState extends State<_SingleLineInputDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

/// 编辑器浮层统一容器(斜杠菜单/mention 面板):圆角 12 + 细边框 +
/// 柔和投影 + surface 底 —— 对齐 app 弹层视觉,替代裸 Material elevation。
class _FloatingPanel extends StatelessWidget {
  const _FloatingPanel({required this.maxHeight, required this.child});

  final double maxHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      // Material 祖先:面板内容常含 InkWell/TextField(图片工具条按钮、
      // alt 输入条),OverlayEntry 不在页面 Material 树下,缺它直接
      // "No Material widget found" 红屏。transparency 不遮 Container 装饰。
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: child,
        ),
      ),
    );
  }
}

/// 斜杠菜单行:图标底板 + 紧凑行高 + 圆角选中态(Notion 风)。
class _SlashMenuRow extends StatelessWidget {
  const _SlashMenuRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: selected ? 0.9 : 0.6,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    icon,
                    size: 15,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? scheme.primary : scheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.keyboard_return_rounded,
                    size: 13,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// mention 候选行:头像 + @用户名/显示名(纯文本编辑器 mention 面板
/// 同视觉语言)。
class _MentionRow extends StatelessWidget {
  const _MentionRow({required this.user, required this.onTap});

  final MentionUser user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatarUrl = user.getAvatarUrl(AppConstants.baseUrl, size: 48);
    final showName =
        (user.name?.isNotEmpty ?? false) && user.name != user.username;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                if (avatarUrl != null && avatarUrl.isNotEmpty)
                  SmartAvatar(
                    imageUrl: avatarUrl,
                    radius: 12,
                    fallbackText: user.username,
                  )
                else
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: scheme.primaryContainer,
                    child: Text(
                      user.username.isEmpty
                          ? '?'
                          : user.username[0].toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '@${user.username}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (showName)
                        Text(
                          user.name!,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
