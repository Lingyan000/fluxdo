// 本文件是 chat_channel_page.dart 的 part(私有类互引,拆物理文件
// 不拆库);新增聊天页组件按职责归档到对应 part。

part of 'chat_channel_page.dart';

/// 移动端输入条底部面板类型(键盘位互换,编辑器同款机制)
enum _ComposerPanel { none, keyboard, emoji }

/// 待发附件:本地文件 + 上传状态(上传成功持有 upload id)
class _PendingAttachment {
  final String filePath;
  final String fileName;
  final bool isImage;
  int? uploadId;
  bool failed = false;

  _PendingAttachment({
    required this.filePath,
    required this.fileName,
    required this.isImage,
  });

  bool get uploading => uploadId == null && !failed;
}

/// 输入条:视觉规格对齐 AiChatInput
/// (外壳 surfaceContainerLow + 顶部圆角 16;输入框 filled surface 圆角 20;
///  发送键 IconButton.filled 36×36)
/// 能力:附件(拍照/相册/文件,选即传,带 upload_ids 发送)、@提及自动补全。
class _ChatComposer extends ConsumerStatefulWidget {
  final ChatComposerController controller;
  final FocusNode focusNode;
  final bool canSend;
  final ChatMessage? editing;
  final ChatMessage? replyingTo;

  /// 发送回调,附带已上传完成的 upload id 列表
  final void Function(List<int> uploadIds) onSend;

  /// 表情包直发:不进输入框,选中即作为独立消息发出
  final void Function(String markdown) onSendSticker;
  final VoidCallback onCancelContext;

  /// 面板开合上报:PopScope.canPop 是页面构建期快照,面板态只在
  /// composer 内部 setState 的话页面不重建,返回键会直接退页
  final ValueChanged<bool>? onPanelOpenChanged;

  const _ChatComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.canSend,
    required this.editing,
    required this.replyingTo,
    required this.onSend,
    required this.onSendSticker,
    required this.onCancelContext,
    this.onPanelOpenChanged,
  });

  @override
  ConsumerState<_ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends ConsumerState<_ChatComposer> {
  final ImagePicker _imagePicker = ImagePicker();

  /// 桌面表情弹层:锚定输入条表情按钮
  final EmojiPopoverController? _emojiPopover = PlatformUtils.isDesktop
      ? EmojiPopoverController()
      : null;
  Widget? _emojiPanelChild;

  /// 移动端键盘位面板(chat_bottom_container,编辑器同款):
  /// 表情面板与键盘等高互换,不再用底部抽屉(与输入框脱节)
  final _panelController = ChatBottomPanelContainerController<_ComposerPanel>();
  _ComposerPanel _currentPanel = _ComposerPanel.none;

  /// 面板意图(编辑器 _intendedPanel 同款):updatePanelType 是异步生效,
  /// 快速连点时用意图位判定目标态,不依赖回调回填的 _currentPanel
  _ComposerPanel _intendedPanel = _ComposerPanel.none;

  /// 表情面板打开时输入框只读:点击不弹键盘(编辑器同坑同修——
  /// 不设只读的话,点输入框系统直接弹键盘,面板/键盘叠加闪跳)。
  /// 移动端初始即只读+聚焦:进入页面光标就闪烁(用户点名"进来没有
  /// 闪烁"),键盘由用户点输入框主动唤起——点输入框触发 onPointerUp
  /// 切键盘(见 _buildField)
  bool _readOnly = !PlatformUtils.isDesktop;

  /// 是否有自定义面板在开(页面返回键拦截用)
  bool get isPanelOpen =>
      _intendedPanel != _ComposerPanel.none ||
      _currentPanel == _ComposerPanel.emoji;

  bool _lastReportedOpen = false;

  void _reportPanelOpen() {
    final open = isPanelOpen;
    if (open != _lastReportedOpen) {
      _lastReportedOpen = open;
      widget.onPanelOpenChanged?.call(open);
    }
  }

  /// 收起面板(返回键/页面级调用;不聚焦输入框、不弹键盘)。
  /// 不解除 readOnly、不摘焦点:关闭面板 = 输入框停在"光标闪烁、
  /// 键盘不弹"的待命态(TG 口径,用户点名)。readOnly 由 onPanelTypeChange
  /// 按目标态维护——切回键盘才解除。要用键盘,点输入框或表情切换钮
  /// 主动唤起。
  void closePanel() {
    _intendedPanel = _ComposerPanel.none;
    _panelController.updatePanelType(
      ChatBottomPanelType.none,
      forceHandleFocus: ChatBottomHandleFocus.none,
    );
    _reportPanelOpen();
  }

  /// 表情面板当前是否打开(意图位;长按消息等浮层 push 前记录用)
  bool get isEmojiPanelOpen => _intendedPanel == _ComposerPanel.emoji;

  /// 长按消息等浮层 pop 后恢复表情面板。
  ///
  /// 浮层(overlay 路由)push 会让输入框失焦、pop 让焦点恢复,触发
  /// ChatBottomPanelContainer 的 inputFocusNodeListener 把面板从表情
  /// 切到键盘(弹键盘)——用户点名这不是目标行为。此前开着表情面板的
  /// 话,pop 后重新拉回表情面板(readOnly 压住键盘),而不是弹键盘。
  void restoreEmojiPanel() {
    if (!mounted) return;
    _intendedPanel = _ComposerPanel.emoji;
    _setReadOnly(true);
    _reportPanelOpen();
    _panelController.updatePanelType(
      ChatBottomPanelType.other,
      data: _ComposerPanel.emoji,
      forceHandleFocus: ChatBottomHandleFocus.requestFocus,
    );
  }

  void _setReadOnly(bool value) {
    if (_readOnly != value) setState(() => _readOnly = value);
  }

  final List<_PendingAttachment> _attachments = [];

  // ---- @提及自动补全 ----
  Timer? _mentionDebounce;
  List<MentionUser> _mentionCandidates = [];

  /// 当前触发中的 @词头在文本里的范围(替换用);null=未触发
  (int, int)? _mentionRange;

  /// 候选条走 Overlay 悬浮在输入条上方(锚定 composer),不占布局
  /// ——放 Column 里会顶起输入区,消息流跟着跳
  final LayerLink _composerLink = LayerLink();
  OverlayEntry? _mentionOverlay;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    // 弹层开合同步表情按钮高亮:关闭路径不止按钮(外点/ESC/resize
    // 都走 controller 内部),必须监听而非在点击处手动 setState
    _emojiPopover?.addListener(_onEmojiPopoverChanged);
    if (!PlatformUtils.isDesktop) {
      // 进入页面 autofocus 聚焦,会被面板容器的焦点监听切成 keyboard
      // 态(键盘占位闪现一帧)。readOnly 待命态下拉回 none:输入条贴底、
      // 光标闪烁、键盘不弹。用户要输入时点输入框主动唤起。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_readOnly && _currentPanel == _ComposerPanel.keyboard) {
          _panelController.updatePanelType(
            ChatBottomPanelType.none,
            forceHandleFocus: ChatBottomHandleFocus.none,
          );
        }
      });
    }
  }

  void _onEmojiPopoverChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _mentionDebounce?.cancel();
    _removeMentionOverlay();
    _emojiPopover?.removeListener(_onEmojiPopoverChanged);
    _emojiPopover?.dispose();
    super.dispose();
  }

  /// 桌面弹层面板(只建一次;移动端不用):表情+表情包双 Tab。
  /// 表情插入输入框;表情包直发,不进输入框
  Widget _ensureEmojiPanel() {
    _emojiPanelChild ??= EmojiStickerPanel(
      inlineSearch: true,
      compact: true,
      onDismissRequested: () => _emojiPopover?.hide(),
      onEmojiSelected: (emoji) {
        _insertAtCursor(':${emoji.name}:');
        _emojiPopover?.hide();
      },
      onStickerSelected: (markdown) {
        _emojiPopover?.hide();
        widget.onSendSticker(markdown);
      },
    );
    return _emojiPanelChild!;
  }

  void _removeMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
  }

  void _syncMentionOverlay() {
    final show = _mentionCandidates.isNotEmpty && _mentionRange != null;
    if (!show) {
      _removeMentionOverlay();
      return;
    }
    if (_mentionOverlay != null) {
      _mentionOverlay!.markNeedsBuild();
      return;
    }
    _mentionOverlay = OverlayEntry(
      builder: (overlayContext) => Positioned(
        width: MediaQuery.sizeOf(overlayContext).width,
        child: CompositedTransformFollower(
          link: _composerLink,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.bottomLeft,
          offset: const Offset(0, -4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _MentionCandidateBar(
              candidates: _mentionCandidates,
              onSelect: _applyMention,
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_mentionOverlay!);
  }

  bool get _hasReadyAttachment => _attachments.any((a) => a.uploadId != null);
  bool get _hasUploading => _attachments.any((a) => a.uploading);

  bool get _canSendNow =>
      // 编辑态不允许带新附件(网页版同语义:编辑只改文本)
      widget.editing != null
      ? widget.canSend
      : (widget.canSend || _hasReadyAttachment) && !_hasUploading;

  // ========== 附件 ==========

  Future<void> _pickFromCamera() async {
    final picked = await _imagePicker.pickImage(
      source: ImageSource.camera,
      maxWidth: 4096,
      maxHeight: 4096,
    );
    if (picked != null) _addAndUpload(picked.path, isImage: true);
  }

  Future<void> _pickFromGallery() async {
    final picked = await _imagePicker.pickMultiImage(
      maxWidth: 4096,
      maxHeight: 4096,
    );
    for (final file in picked) {
      _addAndUpload(file.path, isImage: true);
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    for (final file in result.files) {
      final path = file.path;
      if (path == null) continue;
      final ext = file.extension?.toLowerCase() ?? '';
      _addAndUpload(
        path,
        isImage: const {
          'jpg',
          'jpeg',
          'png',
          'gif',
          'webp',
          'avif',
        }.contains(ext),
      );
    }
  }

  void _addAndUpload(String path, {required bool isImage}) {
    final attachment = _PendingAttachment(
      filePath: path,
      fileName: path.split(Platform.pathSeparator).last,
      isImage: isImage,
    );
    setState(() => _attachments.add(attachment));
    _upload(attachment);
  }

  Future<void> _upload(_PendingAttachment attachment) async {
    try {
      final service = ref.read(discourseServiceProvider);
      final result = await service.uploadFile(attachment.filePath);
      if (!mounted) return;
      setState(() {
        attachment.uploadId = result.id;
        attachment.failed = result.id == null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => attachment.failed = true);
      ToastService.showError(e.toString());
    }
  }

  void _handleSend() {
    if (!_canSendNow) return;
    final uploadIds = [
      for (final a in _attachments)
        if (a.uploadId != null) a.uploadId!,
    ];
    widget.onSend(uploadIds);
    setState(_attachments.clear);
  }

  // ========== @提及 ==========

  void _onTextChanged() {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      _dismissMention();
      return;
    }
    // 光标前找 @词头:@ 前必须是行首或空白,词身为 [\w.-]*
    final beforeCursor = text.substring(0, selection.baseOffset);
    final match = RegExp(r'(^|\s)@([\w.\-]*)$').firstMatch(beforeCursor);
    if (match == null) {
      _dismissMention();
      return;
    }
    final term = match.group(2)!;
    final atStart = match.start + match.group(1)!.length;
    _mentionRange = (atStart, selection.baseOffset);
    _mentionDebounce?.cancel();
    _mentionDebounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final service = ref.read(discourseServiceProvider);
        final result = await service.searchUsers(
          term: term,
          includeGroups: false,
          limit: 6,
        );
        if (!mounted || _mentionRange == null) return;
        setState(() => _mentionCandidates = result.users);
        _syncMentionOverlay();
      } catch (_) {
        // 静默:候选条缺席不影响输入
      }
    });
  }

  void _dismissMention() {
    _mentionDebounce?.cancel();
    if (_mentionRange != null || _mentionCandidates.isNotEmpty) {
      setState(() {
        _mentionRange = null;
        _mentionCandidates = [];
      });
    }
    _removeMentionOverlay();
  }

  void _applyMention(MentionUser user) {
    final range = _mentionRange;
    if (range == null) return;
    final text = widget.controller.text;
    final replaced =
        '${text.substring(0, range.$1)}@${user.username} '
        '${text.substring(range.$2)}';
    final cursor = range.$1 + user.username.length + 2;
    widget.controller.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: cursor),
    );
    _dismissMention();
  }

  // ========== UI ==========

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final editing = widget.editing;
    final replyingTo = widget.replyingTo;
    final contextMessage = editing ?? replyingTo;

    // 悬浮卡:四周圆角 + 外边距 + 描边投影;移动端底部安全区/键盘
    // 占位交给下方 ChatBottomPanelContainer,卡本身静止态不再留间距
    // (卡下直接是导航条沉浸区);键盘/表情面板起来时留 8,输入行
    // 不贴键盘/面板顶(用户点名"键盘弹起时不能一点边距没有")
    final composerCard = CompositedTransformTarget(
      link: _composerLink,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          8,
          0,
          8,
          PlatformUtils.isDesktop
              ? 8 + bottomPadding
              : (_currentPanel == _ComposerPanel.none ? 0 : 8),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 待发附件预览行
                if (_attachments.isNotEmpty) ...[
                  SizedBox(
                    height: 64,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _attachments.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (context, index) => _PendingAttachmentTile(
                        attachment: _attachments[index],
                        onRemove: () =>
                            setState(() => _attachments.removeAt(index)),
                        onRetry: () {
                          setState(() => _attachments[index].failed = false);
                          _upload(_attachments[index]);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                // 编辑/回复上下文条
                if (contextMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            editing != null
                                ? Symbols.edit_rounded
                                : Symbols.reply_rounded,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  editing != null
                                      ? context.l10n.chat_editingBanner
                                      : context.l10n.chat_replyingTo(
                                          replyingTo!.user?.username ?? '',
                                        ),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                EmojiText(
                                  chatPreviewText(
                                    context,
                                    contextMessage.excerpt?.isNotEmpty == true
                                        ? contextMessage.excerpt!
                                        : contextMessage.message,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Symbols.close_rounded, size: 18),
                            visualDensity: VisualDensity.compact,
                            onPressed: widget.onCancelContext,
                          ),
                        ],
                      ),
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // 表情按钮(桌面锚定弹层,移动底部面板);
                    // 移动端面板开着时换键盘图标(示意再点切回键盘)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 1, right: 4),
                      child: _wrapEmojiAnchor(
                        Builder(
                          builder: (context) {
                            final panelOpen =
                                _emojiPopover?.isOpen == true ||
                                _intendedPanel == _ComposerPanel.emoji;
                            return IconButton(
                              onPressed: _pickEmoji,
                              icon: Icon(
                                panelOpen && !PlatformUtils.isDesktop
                                    ? Symbols.keyboard_alt_rounded
                                    : Symbols.sentiment_satisfied_rounded,
                                size: 22,
                                fill: panelOpen ? 1 : 0,
                              ),
                              style: IconButton.styleFrom(
                                minimumSize: const Size(36, 36),
                                padding: EdgeInsets.zero,
                              ),
                              color: panelOpen
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                              tooltip: context.l10n.chat_emoji,
                            );
                          },
                        ),
                      ),
                    ),
                    Expanded(child: _buildField(context, theme)),
                    // 附件(编辑态隐藏):输入框右侧、发送键左边
                    // (通用 IM 秩序 [表情][输入框][附件][发送];之前在最左
                    // 不合 IM 习惯,用户点名)
                    if (editing == null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 1, left: 4),
                        child: Builder(
                          builder: (buttonContext) => IconButton(
                            onPressed: () => _showAttachmentMenu(buttonContext),
                            icon: const Icon(
                              Symbols.attach_file_rounded,
                              size: 22,
                            ),
                            style: IconButton.styleFrom(
                              minimumSize: const Size(36, 36),
                              padding: EdgeInsets.zero,
                            ),
                            color: theme.colorScheme.onSurfaceVariant,
                            tooltip: context.l10n.chat_attach,
                          ),
                        ),
                      ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 1),
                      child: IconButton.filled(
                        onPressed: _canSendNow ? _handleSend : null,
                        icon: _hasUploading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: LoadingSpinner(),
                              )
                            : Icon(
                                editing != null
                                    ? Symbols.check_rounded
                                    : Symbols.send_rounded,
                                size: 20,
                              ),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(36, 36),
                          padding: EdgeInsets.zero,
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.onPrimary,
                          disabledBackgroundColor: theme.colorScheme.onSurface
                              .withValues(alpha: 0.1),
                        ),
                        tooltip: context.l10n.chat_send,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (PlatformUtils.isDesktop) return composerCard;
    // 移动端:悬浮卡下挂键盘位面板容器(键盘占位/表情面板等高互换,
    // 编辑器同款机制;Scaffold 已关 resizeToAvoidBottomInset)。
    // 底部透过:容器外壳透明,导航条(小白条)区域不设实底,消息内容
    // 滚到屏幕最底时透出去(对齐首页 extendBody 的沉浸语义,用户点名
    // "内容能透过小白条")。表情面板自身带 0.95 底,键盘态被系统键盘
    // 盖住,透明外壳不会漏底。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        composerCard,
        ChatBottomPanelContainer<_ComposerPanel>(
          controller: _panelController,
          inputFocusNode: widget.focusNode,
          // 外壳透明(非默认纯白,也不跟主题涂色):三态占位区都透出
          // 底层消息。若改回不透明色,深色主题下会重新闪白/把底部堵死
          panelBgColor: Colors.transparent,
          // 静止态导航条高度显式喂给容器:包内置的 safeArea 测量是
          // 异步的,首帧可能为 0(卡会瞬间贴手势条再跳开)
          safeAreaBottom: MediaQuery.viewPaddingOf(context).bottom,
          otherPanelWidget: (type) => type == _ComposerPanel.emoji
              ? _buildDockedEmojiPanel()
              : const SizedBox.shrink(),
          onPanelTypeChange: (panelType, data) {
            setState(() {
              _currentPanel = switch (panelType) {
                ChatBottomPanelType.none => _ComposerPanel.none,
                ChatBottomPanelType.keyboard => _ComposerPanel.keyboard,
                ChatBottomPanelType.other => data ?? _ComposerPanel.none,
              };
              // 面板态离开 emoji 时同步意图位:变键盘或面板收起都清空
              // ——否则外部失焦关面板(长按消息等)后 _intendedPanel 停在
              // emoji,表情按钮图标跟着错成键盘图标(用户点名)。
              // readOnly **不由这里解除**:解除只发生在用户主动动作
              // (点输入框 onPointerUp / 表情按钮 _pickEmoji 先 _setReadOnly
              // false)。否则进入页面的 autofocus 聚焦被容器焦点监听切成
              // keyboard 态,这里一解除 readOnly 就凭空弹键盘
              if (_currentPanel != _ComposerPanel.emoji) {
                if (_currentPanel == _ComposerPanel.keyboard ||
                    _currentPanel == _ComposerPanel.none) {
                  _intendedPanel = _ComposerPanel.none;
                }
              }
            });
            _reportPanelOpen();
          },
        ),
      ],
    );
  }

  /// 附件/工具菜单:双模式(桌面=+按钮锚点弹出,移动=底部弹层),
  /// 动作声明一份,showAdaptiveMenu 按端分流
  Future<void> _showAttachmentMenu(BuildContext buttonContext) async {
    final l10n = context.l10n;
    final action = await showAdaptiveMenu<String>(
      context: context,
      anchorContext: buttonContext,
      items: [
        if (!PlatformUtils.isDesktop)
          AdaptiveMenuItem(
            value: 'camera',
            icon: Symbols.photo_camera_rounded,
            label: l10n.chat_attachCamera,
          ),
        AdaptiveMenuItem(
          value: 'gallery',
          icon: Symbols.photo_library_rounded,
          label: l10n.chat_attachGallery,
        ),
        AdaptiveMenuItem(
          value: 'file',
          icon: Symbols.attach_file_rounded,
          label: l10n.chat_attachFile,
        ),
        const AdaptiveMenuDivider(),
        AdaptiveMenuItem(
          value: 'template',
          icon: Symbols.description_rounded,
          label: l10n.chat_insertTemplate,
        ),
        AdaptiveMenuItem(
          value: 'datetime',
          icon: Symbols.calendar_clock_rounded,
          label: l10n.chat_insertDateTime,
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'camera':
        await _pickFromCamera();
      case 'gallery':
        await _pickFromGallery();
      case 'file':
        await _pickFile();
      case 'template':
        await _insertTemplate();
      case 'datetime':
        await _insertDateTime();
    }
  }

  /// 光标处插入文本(选区替换,光标落在插入尾)
  void _insertAtCursor(String text) {
    final controller = widget.controller;
    final value = controller.value;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    final newText = value.text.replaceRange(start, end, text);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    widget.focusNode.requestFocus();
  }

  Widget _wrapEmojiAnchor(Widget button) {
    final popover = _emojiPopover;
    if (popover == null) return button;
    return EmojiPopoverAnchor(controller: popover, child: button);
  }

  /// 表情选择:插入 :shortcode:(输入框内联渲染成图,发送后服务端 cook)
  /// 桌面=按钮上方锚定弹层;移动=键盘位面板互换(编辑器同款)
  Future<void> _pickEmoji() async {
    final popover = _emojiPopover;
    if (popover != null) {
      popover.toggle(context, panel: _ensureEmojiPanel());
      return;
    }
    if (_intendedPanel == _ComposerPanel.emoji) {
      // 再点=切回键盘
      setState(() => _intendedPanel = _ComposerPanel.none);
      _setReadOnly(false);
      _reportPanelOpen();
      _panelController.updatePanelType(ChatBottomPanelType.keyboard);
      widget.focusNode.requestFocus();
    } else {
      setState(() => _intendedPanel = _ComposerPanel.emoji);
      _reportPanelOpen();
      // 只读防系统键盘;帧末再切面板(编辑器同款时序:readOnly 先生效)
      _setReadOnly(true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _panelController.updatePanelType(
          ChatBottomPanelType.other,
          data: _ComposerPanel.emoji,
          forceHandleFocus: ChatBottomHandleFocus.requestFocus,
        );
      });
    }
  }

  /// 键盘位表情面板高度:键盘高已知用键盘高,否则 300 兜底
  double get _dockedPanelHeight {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    final keyboardHeight = _panelController.keyboardHeight;
    return keyboardHeight > 0
        ? math.max(keyboardHeight, safeBottom)
        : math.max(300.0, safeBottom);
  }

  Widget _buildDockedEmojiPanel() {
    return TextFieldTapRegion(
      child: SizedBox(
        height: _dockedPanelHeight,
        child: EmojiStickerPanel(
          onEmojiSelected: (emoji) => _insertAtCursor(':${emoji.name}:'),
          // 表情包直发:不进输入框,面板保持打开可连发
          onStickerSelected: widget.onSendSticker,
          onBackspace: () =>
              deleteBackwardWithEmojiShortcodes(widget.controller),
        ),
      ),
    );
  }

  /// 插入模板(复用站点 templates/我的模板)
  Future<void> _insertTemplate() async {
    List<Template> templates;
    try {
      templates = await ref.read(discourseServiceProvider).getTemplates();
    } catch (e) {
      ToastService.showError(e.toString());
      return;
    }
    if (!mounted) return;
    if (templates.isEmpty) {
      ToastService.showInfo(context.l10n.chat_noTemplates);
      return;
    }
    final picked = await AppBottomSheet.showDraggable<Template>(
      context: context,
      title: context.l10n.chat_insertTemplate,
      initialSize: 0.5,
      bodyBuilder: (sheetContext, scrollController) => ListView.builder(
        controller: scrollController,
        itemCount: templates.length,
        itemBuilder: (itemContext, index) {
          final template = templates[index];
          return ListTile(
            title: Text(template.title),
            subtitle: Text(
              template.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.pop(itemContext, template),
          );
        },
      ),
    );
    if (picked != null && mounted) _insertAtCursor(picked.content);
  }

  /// 插入日期/时间:选日期(可选时间),生成 Discourse [date] 语法,
  /// 渲染端(含气泡)会按读者时区本地化显示
  Future<void> _insertDateTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (!mounted) return;
    final dateStr =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final buffer = StringBuffer('[date=')..write(dateStr);
    if (time != null) {
      buffer.write(
        ' time=${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:00',
      );
    }
    buffer.write(' timezone="${TimeUtils.localTimezone}"]');
    _insertAtCursor(buffer.toString());
  }

  static String? _mentionAvatarUrl(MentionUser user) {
    final template = user.avatarTemplate;
    if (template == null || template.isEmpty) return null;
    return UrlHelper.resolveUrlWithCdn(template.replaceAll('{size}', '96'));
  }

  InputDecoration _fieldDecoration(BuildContext context, ThemeData theme) {
    return InputDecoration(
      hintText: context.l10n.chat_inputHint,
      hintStyle: TextStyle(
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      isDense: true,
      filled: true,
      fillColor: theme.colorScheme.surface,
      hoverColor: Colors.transparent,
    );
  }

  Widget _buildField(BuildContext context, ThemeData theme) {
    final field = TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      // 全端自动聚焦:桌面正常输入;移动端初始 readOnly,聚焦只点亮光标
      // 闪烁、不弹键盘(配合 showCursor)。要输入,点输入框唤起键盘
      autofocus: true,
      readOnly: _readOnly,
      // 面板收起(none)时输入框停在"只读+有焦点"的待命态(光标闪烁、
      // 键盘不弹,TG 口径);Flutter 默认 readOnly 不显示光标,必须显式
      // showCursor 否则关面板后光标跟着消失(用户点名)
      showCursor: true,
      minLines: 1,
      maxLines: 5,
      textInputAction: TextInputAction.newline,
      // 退格命中 :shortcode: 局部时扩删整个表情(boost 输入条同款),
      // 否则删一下只掉个冒号,表情"炸回"文本
      inputFormatters: const [EmojiShortcodeDeleteFormatter()],
      decoration: _fieldDecoration(context, theme),
    );
    if (!PlatformUtils.isDesktop) {
      // 面板开着(readOnly)时点输入框=收面板换键盘(编辑器同款)
      return Listener(
        onPointerUp: (_) {
          if (_readOnly) {
            _intendedPanel = _ComposerPanel.none;
            _setReadOnly(false);
            _reportPanelOpen();
            _panelController.updatePanelType(ChatBottomPanelType.keyboard);
          }
        },
        child: field,
      );
    }
    // 桌面:Enter 发送 / Shift+Enter 换行;候选条打开时 Enter 选第一个
    return Shortcuts(
      shortcuts: {LogicalKeySet(LogicalKeyboardKey.enter): const _SendIntent()},
      child: Actions(
        actions: {
          _SendIntent: CallbackAction<_SendIntent>(
            onInvoke: (_) {
              if (_mentionCandidates.isNotEmpty && _mentionRange != null) {
                _applyMention(_mentionCandidates.first);
              } else {
                _handleSend();
              }
              return null;
            },
          ),
        },
        child: field,
      ),
    );
  }
}

/// 待发附件缩略卡:图片显示缩略图,文件显示图标;上传中蒙层转圈,
/// 失败蒙层可点重试;右上角删除
class _PendingAttachmentTile extends StatelessWidget {
  final _PendingAttachment attachment;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  const _PendingAttachmentTile({
    required this.attachment,
    required this.onRemove,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Container(
          width: 64,
          height: 64,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: attachment.isImage
              ? Image.file(
                  File(attachment.filePath),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const Icon(Symbols.broken_image_rounded),
                )
              : Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Symbols.description_rounded, size: 22),
                      const SizedBox(height: 2),
                      Text(
                        attachment.fileName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 8,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        // 上传中/失败蒙层
        if (attachment.uploading || attachment.failed)
          Positioned.fill(
            child: Material(
              color: Colors.black.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
              child: attachment.failed
                  ? InkWell(
                      onTap: onRetry,
                      borderRadius: BorderRadius.circular(12),
                      child: const Icon(
                        Symbols.refresh_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    )
                  : const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: LoadingSpinner(),
                      ),
                    ),
            ),
          ),
        // 删除按钮
        Positioned(
          top: 2,
          right: 2,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Symbols.close_rounded,
                size: 12,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}

