// 本文件是 chat_channel_page.dart 的 part(私有类互引,拆物理文件
// 不拆库);新增聊天页组件按职责归档到对应 part。

part of 'chat_channel_page.dart';

/// 单条消息:规格对齐 AiChatMessageItem
/// (自己 primaryContainer 右对齐,对方 surfaceContainerLow 左对齐带头像;
///  非对称圆角 16/4;maxWidth 78%)
///
/// 交互:移动长按 = 全屏 overlay(气泡副本+反应条+菜单卡);
/// 桌面 = hover 工具条(回复/表情/更多)+ 右键锚点菜单。
class _MessageBubble extends StatefulWidget {
  final ChatMessage message;
  final bool isSelf;
  final bool clustered;

  /// 列表滚动中标志:滚动时抑制 hover 工具条(防划过反复闪现)
  final ValueListenable<bool> scrolling;

  /// 定位跳转落点的短时高亮
  final bool highlighted;

  /// 请求打开菜单:移动传 (bubbleRect, bubbleBuilder),桌面传 anchorPosition
  final void Function(
    Rect? bubbleRect,
    Widget Function(BuildContext)? bubbleBuilder,
    Offset? anchorPosition,
  )
  onMenuRequested;
  final VoidCallback onQuickReply;
  final void Function(String emoji) onQuickReact;
  final void Function(String emoji)? onReactionTap;

  /// 非空时气泡下显示"N 条回复"入口(仅主流的串首消息)
  final VoidCallback? onOpenThread;

  /// 引用条点击(跳到被回复的原消息)
  final VoidCallback? onReplyRefTap;
  final VoidCallback? onRetry;
  final VoidCallback? onDiscard;

  /// 收藏切换(hover 工具条书签钮)
  final VoidCallback? onToggleBookmark;

  /// 长按头像菜单"@用户"(插入输入框)
  final void Function(String username)? onMentionUser;

  /// 删除折叠(官方口径):连续删除段只有段尾渲染,显示"N 条已删除·查看"
  /// 入口;count=段长,onExpand 展开整段原文
  final int deletedRunCount;
  final bool deletedExpanded;
  final VoidCallback? onExpandDeleted;

  const _MessageBubble({
    required this.message,
    required this.isSelf,
    required this.clustered,
    required this.scrolling,
    this.highlighted = false,
    required this.onMenuRequested,
    required this.onQuickReply,
    required this.onQuickReact,
    this.onReactionTap,
    this.onOpenThread,
    this.onReplyRefTap,
    this.onRetry,
    this.onDiscard,
    this.onToggleBookmark,
    this.onMentionUser,
    this.deletedRunCount = 1,
    this.deletedExpanded = false,
    this.onExpandDeleted,
  });

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  final GlobalKey _bubbleKey = GlobalKey();

  /// 整行的 key:hover 工具条钉在行右上角(与内容宽度
  /// 无关;量 _bubbleKey 会随 shrinkWrap 内容宽漂移)
  final GlobalKey _rowKey = GlobalKey();

  /// 头像锚(用户卡片定位:锚整行会让浮层飘到行中间压消息流)
  final GlobalKey _avatarKey = GlobalKey();
  final LayerLink _avatarLink = LayerLink();

  /// 桌面 hover 工具条走 Overlay(全局最顶层):列表项内 Stack 溢出
  /// 绘制会被相邻项盖住(reverse 列表上邻项后绘制,z 序在列表内无解)。
  ///
  /// **全局单例**:entry/owner 是类级静态——每行各持一条时,快速划过
  /// 多行会在旧行 120ms 宽限内插入新行的条,屏上并存一堆(用户截图)。
  /// 任何行要显示前先无条件撤掉现存那条,全局同时最多一条。
  static OverlayEntry? _sharedBarEntry;
  static _MessageBubbleState? _sharedBarOwner;
  Timer? _hoverBarHideTimer;
  bool _pointerInBar = false;
  bool _pointerInRow = false;

  ChatMessage get message => widget.message;
  bool get isSelf => widget.isSelf;
  bool get clustered => widget.clustered;

  /// 工具条外置快捷表情:最近使用前几个一击回应
  List<String> _quickEmojis = const ['heart', '+1', 'laughing'];

  @override
  void initState() {
    super.initState();
    if (PlatformUtils.isDesktop) {
      widget.scrolling.addListener(_onScrollingChanged);
      unawaited(
        loadQuickReactions(limit: 3).then((list) {
          if (mounted && list.isNotEmpty) _quickEmojis = list;
        }),
      );
    }
  }

  @override
  void dispose() {
    if (PlatformUtils.isDesktop) {
      widget.scrolling.removeListener(_onScrollingChanged);
    }
    _hoverBarHideTimer?.cancel();
    _removeHoverBar();
    super.dispose();
  }

  @override
  void didUpdateWidget(_MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 工具条是 OverlayEntry,不随行 rebuild;本行持有时数据变了手动重建
    // (收藏图标翻转/删除态切换等)。
    // 必须推迟到帧末:didUpdateWidget 处于 build 阶段,此刻 markNeedsBuild
    // (= 对 Overlay setState)非法,会炸整棵树(书签一点就崩的事故)
    if (_sharedBarOwner == this && widget.message != oldWidget.message) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _sharedBarOwner == this) {
          _sharedBarEntry?.markNeedsBuild();
        }
      });
    }
  }

  void _onScrollingChanged() {
    // 滚动中撤条(消息划过光标时 enter/exit 连环触发的闪现由此根治)
    if (widget.scrolling.value) {
      _removeHoverBar();
    } else if (_pointerInRow && mounted) {
      // 滚动停止且指针仍停在本行:补显(滚动中 enter 被拦掉后不会再
      // 触发,不补的话要移出去再移回来才出条)
      _showHoverBar();
    }
  }

  void _removeHoverBar() {
    // 只有 owner 才能撤(避免误撤别行刚插入的条)
    if (_sharedBarOwner == this) {
      _sharedBarEntry?.remove();
      _sharedBarEntry = null;
      _sharedBarOwner = null;
    }
    _pointerInBar = false;
  }

  /// 无条件撤当前屏上的条(不管归谁)——新行显示前调用
  static void _removeSharedBar() {
    _sharedBarEntry?.remove();
    _sharedBarEntry = null;
    _sharedBarOwner?._pointerInBar = false;
    _sharedBarOwner = null;
  }

  void _scheduleHideBar() {
    // 行 → 工具条之间有间隙,给 120ms 宽限迁移,双双离开才撤
    _hoverBarHideTimer?.cancel();
    _hoverBarHideTimer = Timer(const Duration(milliseconds: 120), () {
      if (!_pointerInRow && !_pointerInBar) _removeHoverBar();
    });
  }

  void _showHoverBar() {
    if (widget.scrolling.value) return;
    // 删除消息:折叠态不出条;展开态出受限条(官方=收藏+更多,无快捷表情/回复)
    if (message.isStaged) return;
    if (message.isDeleted && !widget.deletedExpanded) return;
    if (_sharedBarOwner == this && _sharedBarEntry != null) return;
    // 接管:先撤别行(或残留)的条,保证全局唯一
    _removeSharedBar();
    final box = _rowKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final overlay = Overlay.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;

    final entry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        // 钉整行右上角,半高悬出行顶;Overlay 层永远压不住
        top: rect.top - 14,
        right: screenWidth - rect.right + 12,
        child: MouseRegion(
          onEnter: (_) => _pointerInBar = true,
          onExit: (_) {
            _pointerInBar = false;
            _scheduleHideBar();
          },
          child: _HoverActionBar(
            // 删除消息(展开态):受限条——无快捷表情/回应/回复,
            // 保留收藏+更多(官方 canInteractWithMessage=!deletedAt)
            interactive: !message.isDeleted,
            quickEmojis: _quickEmojis,
            bookmarked: message.bookmark != null,
            onQuickEmoji: (emoji) {
              _removeHoverBar();
              widget.onQuickReact(emoji);
            },
            onReply: () {
              _removeHoverBar();
              widget.onQuickReply();
            },
            onPickReaction: () async {
              _removeHoverBar();
              final emoji = await showChatEmojiPicker(context, desktop: true);
              if (emoji != null) widget.onQuickReact(emoji);
            },
            // 收藏后不撤条:图标原地翻转(didUpdateWidget markNeedsBuild)
            onBookmark: () => widget.onToggleBookmark?.call(),
            onMore: (buttonContext) {
              final buttonBox = buttonContext.findRenderObject() as RenderBox?;
              final anchor = buttonBox?.localToGlobal(
                buttonBox.size.bottomLeft(Offset.zero),
              );
              _removeHoverBar();
              if (anchor != null) _openDesktopMenuAt(anchor);
            },
          ),
        ),
      ),
    );
    _sharedBarEntry = entry;
    _sharedBarOwner = this;
    overlay.insert(entry);
  }

  /// 点头像/名字:用户卡片(锚定头像,桌面浮层贴头像旁+跟随滚动,
  /// 移动停靠卡;话题页同款口径)
  void _openUserCard() {
    final user = message.user;
    if (user == null) return;
    final box =
        (_avatarKey.currentContext ?? _rowKey.currentContext)
                ?.findRenderObject()
            as RenderBox?;
    if (box == null || !box.hasSize) return;
    final anchorRect = box.localToGlobal(Offset.zero) & box.size;
    showUserCard(
      context: context,
      anchorRect: anchorRect,
      layerLink: _avatarKey.currentContext != null ? _avatarLink : null,
      username: user.username,
      avatarFallbackUrl: user.getAvatarUrl(size: 144),
      nameFallback: user.name,
    );
  }

  /// 移动端长按 reaction chip:弹名单(桌面走 chip Tooltip)
  void _showReactionUsers(ChatMessageReaction reaction) {
    if (PlatformUtils.isDesktop) return;
    HapticFeedback.selectionClick();
    final url = EmojiHandler().getEmojiUrl(reaction.emoji);
    unawaited(
      AppBottomSheet.show<void>(
        context: context,
        showCloseButton: false,
        contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        titleWidget: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (url.isNotEmpty)
              Image(image: emojiImageProvider(url), width: 22, height: 22)
            else
              Text(reaction.emoji),
            const SizedBox(width: 8),
            Text(':${reaction.emoji}: · ${reaction.count}'),
          ],
        ),
        builder: (sheetContext) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final user in reaction.users)
              ListTile(
                dense: true,
                leading: SmartAvatar(
                  imageUrl: user.getAvatarUrl(size: 64),
                  radius: 14,
                  fallbackText: user.username,
                ),
                title: Text(user.username),
              ),
          ],
        ),
      ),
    );
  }

  void _openMobileMenu() {
    if (_pressing) setState(() => _pressing = false);
    final renderBox =
        _bubbleKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final contentRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
    // 副本矩形外扩壳内边距(±10/±8):overlay 按 rect.width 定宽,壳的
    // padding 在定宽内部吃宽度会把正文挤到重新换行(三字消息竖排/
    // 长消息高度失真)。外扩后壳内正文保持原始量测宽,第 0 帧正文
    // 与列表逐像素重合。
    //
    // 壳本体(底色/圆角/投影)由 overlay 在飞行途中从全透明长出——
    // 这里只给内容衬对称 padding,不再自带 Material 底。早先的
    // "壳左缘不越沟槽"动态收窄也随之退役:第 0 帧壳不可见,盖不住
    // 头像;壳显形时消息已飞离原位。
    final rect = Rect.fromLTRB(
      contentRect.left - 10,
      contentRect.top - 8,
      contentRect.right + 10,
      contentRect.bottom + 8,
    );
    widget.onMenuRequested(
      rect,
      (ctx) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: _buildBubbleCore(ctx, interactive: false),
      ),
      null,
    );
  }

  void _openDesktopMenuAt(Offset globalPosition) {
    widget.onMenuRequested(null, null, globalPosition);
  }

  /// 行内 hover(移动无效):簇内行左沟槽时间的显隐
  bool _rowHovered = false;

  /// 移动端长按按压中:行底色反馈(菜单弹出前的蓄力提示)
  bool _pressing = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 扁平行:不分左右,自己/别人同为左对齐,靠名字配色区分。
    // 结构 = [64 左沟槽(簇首头像/簇内 hover 时间)][内容列(簇首头行+正文)]
    // 整行 hover 染色;高亮/hover 底色画在全宽行上。
    var rowColor = widget.highlighted
        ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.35)
        : _pressing
        ? theme.colorScheme.onSurface.withValues(alpha: 0.08)
        : _rowHovered && PlatformUtils.isDesktop
        ? theme.colorScheme.onSurface.withValues(alpha: 0.04)
        : Colors.transparent;

    if (message.isDeleted && !widget.deletedExpanded) {
      // 折叠态(官方 deletedAndCollapsed):整段一行入口,点击展开原文
      final count = widget.deletedRunCount;
      return _wrapRow(
        theme,
        rowColor,
        gutter: const SizedBox.shrink(),
        body: Align(
          alignment: Alignment.centerLeft,
          child: InkWell(
            onTap: widget.onExpandDeleted,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                count > 1
                    ? context.l10n.chat_deletedMany(count)
                    : context.l10n.chat_deletedOne,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error.withValues(alpha: 0.85),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ),
        ),
      );
    }
    // 展开的删除消息:正常渲染原文,危险色淡底标识(官方 -deleted 底色)
    if (message.isDeleted) {
      rowColor = Color.alphaBlend(
        theme.colorScheme.error.withValues(alpha: 0.06),
        rowColor,
      );
    }

    // 左沟槽:簇首=头像;簇内=hover 时淡入的小时间
    final Widget gutter;
    if (!clustered) {
      final avatar = CompositedTransformTarget(
        link: _avatarLink,
        child: KeyedSubtree(
          key: _avatarKey,
          child: SmartAvatar(
            imageUrl: message.user?.getAvatarUrl(size: 80),
            radius: 18,
            fallbackText: message.user?.username,
          ),
        ),
      );
      // 点头像=用户卡片(话题页口径,资料页从卡片进);长按=径向菜单
      gutter = message.user == null
          ? avatar
          : RadialLongPressMenu(
              onTap: _openUserCard,
              itemsBuilder: () => buildAvatarMenuItems(
                context,
                username: message.user!.username,
                onMentionUser: widget.onMentionUser,
              ),
              pressAreaIndicatorBuilder: (ctx, rect, opacity) => Opacity(
                opacity: opacity,
                child: SmartAvatar(
                  imageUrl: message.user?.getAvatarUrl(size: 80),
                  radius: rect.shortestSide / 2,
                  fallbackText: message.user?.username,
                  border: Border.all(
                    color: Theme.of(ctx).colorScheme.primary,
                    width: 2,
                  ),
                ),
              ),
              child: avatar,
            );
    } else {
      gutter = AnimatedOpacity(
        opacity: _rowHovered ? 1 : 0,
        duration: const Duration(milliseconds: 100),
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            TimeUtils.formatClockTime(message.createdAt),
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      );
    }

    // 簇首头行:名字(自己主色/他人 secondary 染色) + 小时间
    final Widget? header = clustered
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: GestureDetector(
                    onTap: message.user == null ? null : _openUserCard,
                    child: Text(
                      message.user?.name?.isNotEmpty == true
                          ? message.user!.name!
                          : (message.user?.username ?? ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isSelf
                            ? theme.colorScheme.primary
                            : theme.colorScheme.secondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  TimeUtils.formatClockTime(message.createdAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                if (message.edited) ...[
                  const SizedBox(width: 6),
                  Text(
                    context.l10n.chat_edited,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
                if (message.isDeleted) ...[
                  const SizedBox(width: 6),
                  Text(
                    context.l10n.chat_deletedTag,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error.withValues(alpha: 0.8),
                    ),
                  ),
                ],
                if (message.isStaged) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
          );

    // 回复引用行:头行上方,细字 + 竖线记号
    final Widget? replyRef = message.inReplyTo == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: InkWell(
              onTap: widget.onReplyRefTap,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Symbols.reply_rounded,
                    size: 13,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    message.inReplyTo!.user?.username ?? '',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: EmojiText(
                      chatPreviewText(
                        context,
                        message.inReplyTo!.excerpt ?? '',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );

    // 内容主体(正文全宽,无底色;右键/长按手势在整行 _wrapRow 上)
    final body = KeyedSubtree(
      key: _bubbleKey,
      child: Opacity(
        opacity: message.isStaged ? 0.6 : 1.0,
        child: _buildBubbleCore(context, interactive: true),
      ),
    );

    // reactions / thread / failed 行
    // hover 行(桌面)时尾部追加"加表情"胶囊(官方同款)
    final Widget? reactionsRow = message.reactions.isEmpty
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final r in message.reactions)
                  _ReactionChip(
                    reaction: r,
                    onTap: widget.onReactionTap == null
                        ? null
                        : () => widget.onReactionTap!(r.emoji),
                    onLongPress: () => _showReactionUsers(r),
                  ),
                if (PlatformUtils.isDesktop && _rowHovered)
                  _AddReactionChip(
                    onTap: () async {
                      final emoji = await showChatEmojiPicker(
                        context,
                        desktop: true,
                      );
                      if (emoji != null) widget.onQuickReact(emoji);
                    },
                  ),
              ],
            ),
          );

    final Widget? threadRow =
        widget.onOpenThread != null && message.thread != null
        ? Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _ThreadEntryCard(
              thread: message.thread!,
              onTap: widget.onOpenThread!,
            ),
          )
        : null;

    final Widget? failedRow = message.sendState == ChatMessageSendState.failed
        ? _buildFailedRow(theme)
        : null;

    return _wrapRow(
      theme,
      rowColor,
      gutter: gutter,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ?replyRef,
          ?header,
          body,
          ?reactionsRow,
          ?threadRow,
          ?failedRow,
        ],
      ),
    );
  }

  /// 行外壳:全宽底色 + [56 沟槽][内容] 两列;桌面挂 hover
  Widget _wrapRow(
    ThemeData theme,
    Color rowColor, {
    required Widget gutter,
    required Widget body,
  }) {
    final row = GestureDetector(
      // 热区=整行(含空白区);behavior 透明让内层链接/
      // 图片等交互照常命中
      onLongPress: PlatformUtils.isDesktop ? null : _openMobileMenu,
      // 按压蓄力反馈:按下即染色,松手/取消/菜单弹出后还原
      onLongPressDown: PlatformUtils.isDesktop
          ? null
          : (_) => setState(() => _pressing = true),
      onLongPressCancel: PlatformUtils.isDesktop
          ? null
          : () => setState(() => _pressing = false),
      onLongPressUp: PlatformUtils.isDesktop
          ? null
          : () => setState(() => _pressing = false),
      onSecondaryTapDown: PlatformUtils.isDesktop
          ? (d) => _openDesktopMenuAt(d.globalPosition)
          : null,
      behavior: HitTestBehavior.translucent,
      child: AnimatedContainer(
        key: _rowKey,
        duration: const Duration(milliseconds: 300),
        color: rowColor,
        padding: EdgeInsets.only(
          left: PlatformUtils.isDesktop ? 24 : 10,
          right: PlatformUtils.isDesktop ? 28 : 10,
          top: clustered ? 2 : 10,
          bottom: 2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 44, child: Center(child: gutter)),
            const SizedBox(width: 10),
            Expanded(child: body),
          ],
        ),
      ),
    );

    if (!PlatformUtils.isDesktop) return row;
    return MouseRegion(
      onEnter: (_) {
        _pointerInRow = true;
        if (!_rowHovered) setState(() => _rowHovered = true);
        _showHoverBar();
      },
      onExit: (_) {
        _pointerInRow = false;
        if (_rowHovered) setState(() => _rowHovered = false);
        _scheduleHideBar();
      },
      child: row,
    );
  }

  /// 消息正文(jumbo emoji / 富文本 + 附件);无底色无内边距(扁平行)。
  /// [interactive]=false 用于长按 overlay 副本(heroTag 换命名空间防撞)
  Widget _buildBubbleCore(BuildContext context, {required bool interactive}) {
    final theme = Theme.of(context);

    // 纯 emoji 消息:jumbo 大图(网页版同款)
    final jumbo = (message.uploads.isEmpty && message.inReplyTo == null)
        ? jumboEmojiUrls(message.cooked)
        : null;
    if (jumbo != null) {
      final size = jumbo.length == 1
          ? 42.0
          : jumbo.length <= 3
          ? 34.0
          : 28.0;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Wrap(
          spacing: 2,
          runSpacing: 2,
          children: [
            for (final url in jumbo)
              Image(image: emojiImageProvider(url), width: size, height: size),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FluxdoRenderCallbacks.generic(
          heroTagNamespace: interactive
              ? 'chat_${message.channelId}_${message.id}'
              : 'chat_overlay_${message.channelId}_${message.id}',
        ).render(
          cookedHtml: message.cooked,
          baseTextStyle: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
          // 桌面可划词(鼠标拖选);移动端长按已被消息菜单占用,
          // 划词走长按菜单里的"复制"
          selectionEnabled: interactive && PlatformUtils.isDesktop,
          shrinkWrapWidth: true,
          // 裁掉首末块自带外边距(<p> 有、jumbo/附件无 → 行内底部留白
          // 忽有忽无);行距统一由行 padding 控制
          trimTopMargin: true,
          trimBottomMargin: true,
        ),
        // 附件(chat 的 uploads 不进 cooked,单独渲染)
        if (message.uploads.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(
              top: message.cooked.trim().isEmpty ? 0 : 6,
            ),
            child: _MessageUploads(
              uploads: message.uploads,
              interactive: interactive,
              heroNamespace: 'chat_up_${message.channelId}_${message.id}',
            ),
          ),
      ],
    );
  }

  Widget _buildFailedRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.error_rounded, size: 14, color: theme.colorScheme.error),
          const SizedBox(width: 4),
          TextButton(
            onPressed: widget.onRetry,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
            ),
            child: Text(context.l10n.chat_resend),
          ),
          TextButton(
            onPressed: widget.onDiscard,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
            ),
            child: Text(context.l10n.chat_discard),
          ),
        ],
      ),
    );
  }
}

/// 桌面 hover 工具条:
/// [快捷表情×3 一击回应][加表情][回复][更多]
class _HoverActionBar extends StatelessWidget {
  /// false=删除消息的受限条:只保留收藏+更多(官方口径)
  final bool interactive;
  final List<String> quickEmojis;
  final bool bookmarked;
  final void Function(String emoji) onQuickEmoji;
  final VoidCallback onReply;
  final VoidCallback onPickReaction;
  final VoidCallback onBookmark;
  final void Function(BuildContext buttonContext) onMore;

  const _HoverActionBar({
    this.interactive = true,
    required this.quickEmojis,
    this.bookmarked = false,
    required this.onQuickEmoji,
    required this.onReply,
    required this.onPickReaction,
    required this.onBookmark,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final handler = EmojiHandler();
    return Material(
      color: theme.colorScheme.surfaceContainerLowest,
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 外置快捷表情:最近使用前 3,一击回应
            if (interactive)
              for (final emoji in quickEmojis)
                Tooltip(
                  message: ':$emoji:',
                  waitDuration: const Duration(milliseconds: 400),
                  child: InkWell(
                    onTap: () => onQuickEmoji(emoji),
                    borderRadius: BorderRadius.circular(8),
                    hoverColor: theme.colorScheme.onSurface.withValues(
                      alpha: 0.08,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Builder(
                        builder: (context) {
                          final url = handler.getEmojiUrl(emoji);
                          return url.isEmpty
                              ? Text(
                                  emoji,
                                  style: const TextStyle(fontSize: 16),
                                )
                              : Image(
                                  image: emojiImageProvider(url),
                                  width: 20,
                                  height: 20,
                                );
                        },
                      ),
                    ),
                  ),
                ),
            if (interactive) ...[
              SizedBox(
                height: 20,
                child: VerticalDivider(
                  width: 8,
                  thickness: 1,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.4,
                  ),
                ),
              ),
              _HoverBarButton(
                icon: Symbols.add_reaction_rounded,
                tooltip: context.l10n.chat_moreReactions,
                onTap: onPickReaction,
              ),
            ],
            _HoverBarButton(
              icon: bookmarked
                  ? Symbols.bookmark_remove_rounded
                  : Symbols.bookmark_rounded,
              tooltip: bookmarked
                  ? context.l10n.chat_menuRemoveBookmark
                  : context.l10n.chat_menuBookmark,
              onTap: onBookmark,
            ),
            if (interactive)
              _HoverBarButton(
                icon: Symbols.reply_rounded,
                tooltip: context.l10n.chat_menuReply,
                onTap: onReply,
              ),
            Builder(
              builder: (buttonContext) => _HoverBarButton(
                icon: Symbols.more_horiz_rounded,
                tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
                onTap: () => onMore(buttonContext),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HoverBarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _HoverBarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: Theme.of(
          context,
        ).colorScheme.onSurface.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

