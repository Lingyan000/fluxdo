import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/discourse/discourse_service.dart';
import '../../../../services/emoji_handler.dart';
import '../../../../services/preloaded_data_service.dart';
import '../../../../utils/platform_utils.dart';
import 'post_reaction_picker.dart';

/// 获取 emoji 图片 URL（未加载完成时返回空字符串，由 errorBuilder 处理）
String _getEmojiUrl(String emojiName) {
  return EmojiHandler().getEmojiUrl(emojiName);
}

/// 帖子底部操作栏
class PostActionBar extends StatefulWidget {
  final Post post;
  final bool isGuest;
  final bool isOwnPost;
  final bool isLiking;
  final List<PostReaction> reactions;
  final PostReaction? currentUserReaction;
  final GlobalKey likeButtonKey;
  final List<Post> replies;
  final ValueNotifier<bool> isLoadingRepliesNotifier;
  final ValueNotifier<bool> showRepliesNotifier;
  final VoidCallback onToggleLike;
  final void Function(String reactionId) onReactionSelected;
  final void Function(String? reactionId) onShowReactionUsers;
  final VoidCallback? onReply;
  final VoidCallback onShowMoreMenu;
  final VoidCallback onToggleReplies;
  final bool hideRepliesButton;
  final VoidCallback? onAddBoost;
  final bool canBoost;
  final bool hasBoosts;

  /// 操作栏左侧插槽(post-voting 问答话题的赞成/反对控件)
  final Widget? leadingSlot;

  /// post-voting(问答)话题:官方语义——答案帖无回复按钮(评论代替
  /// 追问),答案帖默认无点赞(post_voting_enable_likes_on_answers);
  /// 问题帖回复按钮语义变「回答」。
  final bool isPostVotingTopic;

  const PostActionBar({
    super.key,
    required this.post,
    required this.isGuest,
    required this.isOwnPost,
    required this.isLiking,
    required this.reactions,
    required this.currentUserReaction,
    required this.likeButtonKey,
    required this.replies,
    required this.isLoadingRepliesNotifier,
    required this.showRepliesNotifier,
    required this.onToggleLike,
    required this.onReactionSelected,
    required this.onShowReactionUsers,
    this.onReply,
    required this.onShowMoreMenu,
    required this.onToggleReplies,
    this.hideRepliesButton = false,
    this.onAddBoost,
    this.canBoost = false,
    this.hasBoosts = false,
    this.leadingSlot,
    this.isPostVotingTopic = false,
  });

  @override
  State<PostActionBar> createState() => _PostActionBarState();
}

class _PostActionBarState extends State<PostActionBar>
    with TickerProviderStateMixin {
  Timer? _hoverTimer;

  /// 已预热过的 reaction 图 URL(进程级):站点 reaction 就那几张,
  /// 第一次长按前解码进内存,面板弹出时不会看到空槽位再逐个跳出来
  static final Set<String> _warmedEmojiUrls = {};

  /// 触摸端按下预反馈:长按要等 350ms 才有动静,这段空白由按钮本身填。
  /// onTapDown 由竞技场在 100ms 后裁决触发,按钮缩小压暗;长按胜出、
  /// 抬手或滚动接管都会走 onTapCancel/onTapUp 复原。
  bool _pressed = false;

  /// 选中的表情飞抵按钮时按钮弹跳一下,表达"落进去了"
  late final AnimationController _bounce;
  late final Animation<double> _bounceScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.1)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.1, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 65,
    ),
  ]).animate(_bounce);

  late final ReactionPickerController _pickerController =
      ReactionPickerController(
    vsync: this,
    onReactionSelected: (id) {
      widget.onReactionSelected(id);
      _bounce.forward(from: 0);
    },
  );

  @override
  void initState() {
    super.initState();
    // 先初始化，避免访客或自己的帖子在 dispose 时才首次创建 ticker。
    _bounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _warmReactionImages();
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _bounce.dispose();
    _pickerController.dispose();
    super.dispose();
  }

  void _warmReactionImages() {
    if (widget.isGuest || widget.isOwnPost) return;
    for (final id in DiscourseService().enabledReactionsSync) {
      final url = _getEmojiUrl(id);
      if (url.isEmpty || !_warmedEmojiUrls.add(url)) continue;
      precacheImage(emojiImageProvider(url), context).ignore();
    }
  }

  // ============================== 触发逻辑 ==============================

  /// 以 like 按钮为锚点打开 picker。
  /// 按钮未布局或站点没有启用任何 reaction 时返回 false。
  bool _openPicker(ReactionPickerMode mode) {
    final box = widget.likeButtonKey.currentContext?.findRenderObject()
        as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final reactions = DiscourseService().enabledReactionsSync;
    if (reactions.isEmpty) return false;
    _pickerController.open(
      context: context,
      buttonRect: box.localToGlobal(Offset.zero) & box.size,
      reactions: reactions,
      currentUserReaction: widget.currentUserReaction,
      theme: Theme.of(context),
      mode: mode,
    );
    return true;
  }

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  /// 移动端长按:手势在竞技场胜出(按住 [kReactionPickerLongPressDuration]
  /// 且位移未超 slop)才打开 picker,按下阶段不做任何事,滚动列表时
  /// picker 不会闪出来。打开即可拖动选择。
  void _handleLongPressStart(LongPressStartDetails details) {
    _setPressed(false);
    if (!_openPicker(ReactionPickerMode.touch)) return;
    HapticFeedback.mediumImpact();
    _pickerController.updateHighlight(details.globalPosition);
  }

  /// 触摸端手势表:tap 走各自回调,长按打开 picker。
  /// 长按胜出后 Tap 识别器已被竞技场拒绝,onTap 不会再触发,无需去重。
  /// 桌面端 picker 由 hover 触发,不注册长按避免两条路径打架。
  Map<Type, GestureRecognizerFactory> _touchGestures(VoidCallback onTap) => {
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          TapGestureRecognizer.new,
          (instance) {
            instance.onTap = onTap;
            if (!PlatformUtils.isDesktop) {
              instance.onTapDown = (_) => _setPressed(true);
              instance.onTapUp = (_) => _setPressed(false);
              instance.onTapCancel = () => _setPressed(false);
            }
          },
        ),
        if (!PlatformUtils.isDesktop)
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(
              duration: kReactionPickerLongPressDuration,
            ),
            (instance) {
              instance.onLongPressStart = _handleLongPressStart;
              instance.onLongPressMoveUpdate = (d) =>
                  _pickerController.updateHighlight(d.globalPosition);
              instance.onLongPressEnd = (_) => _pickerController.releaseTouch();
              instance.onLongPressCancel = _pickerController.close;
            },
          ),
      };

  /// 桌面端 hover:300ms 延迟后打开
  void _onHoverEnter() {
    if (_pickerController.isOpen) return;
    _hoverTimer?.cancel();
    _hoverTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _openPicker(ReactionPickerMode.desktop);
    });
  }

  void _onHoverExit() {
    _hoverTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final leftButton = (widget.post.replyCount > 0 && !widget.hideRepliesButton)
        ? _buildRepliesButton(theme)
        : null;
    final rightActions = _buildRightActions(theme);

    // 右侧整组放进 Wrap：放得下时单行右对齐，放不下时自动换行，
    // 不做宽度估算，由布局系统自己决定
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (widget.leadingSlot != null) ...[
          widget.leadingSlot!,
          const SizedBox(width: 8),
        ],
        if (leftButton != null) ...[
          leftButton,
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: rightActions,
          ),
        ),
      ],
    );
  }

  Widget _buildRepliesButton(ThemeData theme) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.isLoadingRepliesNotifier,
      builder: (context, isLoadingReplies, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: widget.showRepliesNotifier,
          builder: (context, showReplies, _) {
            return GestureDetector(
              onTap: isLoadingReplies ? null : widget.onToggleReplies,
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: showReplies
                      ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                      : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: showReplies
                        ? theme.colorScheme.primary.withValues(alpha: 0.2)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLoadingReplies && widget.replies.isEmpty)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else ...[
                      Icon(
                        Symbols.chat_bubble_rounded,
                        size: 15,
                        color: showReplies
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${widget.post.replyCount}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: showReplies
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        showReplies
                            ? Symbols.keyboard_arrow_up_rounded
                            : Symbols.keyboard_arrow_down_rounded,
                        size: 18,
                        color: showReplies
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  List<Widget> _buildRightActions(ThemeData theme) {
    final actions = <Widget>[];
    // 问答话题官方语义:答案帖(非首帖)隐藏点赞与回复(评论代替追问);
    // 问题帖保留点赞,回复语义变「回答」。likes 开关按站点设置
    // post_voting_enable_likes_on_answers(缺省 false)。
    final isPvAnswer = widget.isPostVotingTopic && widget.post.postNumber != 1;
    final pvLikesOnAnswers =
        PreloadedDataService()
                .siteSettingsSync?['post_voting_enable_likes_on_answers'] ==
            true;
    if (!widget.isGuest) {
      final hideLike = isPvAnswer && !pvLikesOnAnswers;
      if ((!widget.isOwnPost || widget.reactions.isNotEmpty) && !hideLike) {
        actions.add(_buildLikeReactionArea(theme));
      }
      if (!widget.isOwnPost && widget.canBoost && !widget.hasBoosts) {
        actions.add(_iconCircle(
          theme,
          tooltip: 'Boost',
          icon: Symbols.rocket_launch_rounded,
          onTap: widget.onAddBoost,
        ));
      }
      if (!isPvAnswer) {
        actions.add(_iconCircle(
          theme,
          tooltip: widget.isPostVotingTopic
              ? S.current.postVoting_answer
              : context.l10n.common_reply,
          icon: Symbols.reply_rounded,
          onTap: widget.onReply,
        ));
      }
    }
    actions.add(_iconCircle(
      theme,
      icon: Symbols.more_horiz_rounded,
      onTap: widget.onShowMoreMenu,
    ));
    return actions;
  }

  Widget _iconCircle(
    ThemeData theme, {
    String? tooltip,
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    Widget child = GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        width: 36,
        decoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    // Tooltip(OverlayPortal + 手势 + MouseRegion)单个构建 ~0.8ms,
    // 且触摸端长按气泡几乎不可达(这些按钮是即时 tap 动作),只在
    // 桌面端保留(hover 提示有真实价值)。楼层挂载路径上每省一点
    // 都直接改善滚动帧预算。
    if (tooltip != null && PlatformUtils.isDesktop) {
      child = Tooltip(message: tooltip, child: child);
    }
    return child;
  }

  /// 表情叠叠乐：最多 3 个重叠排列，第一个在最上层。
  /// 描边沿表情自身轮廓（贴纸效果）：把表情染成底色后向四周偏移绘制在底层，
  /// 再叠原图，避免圆形底盘的生硬感。
  Widget _buildReactionStack(ThemeData theme) {
    final shown = widget.reactions.take(3).toList();
    const double size = 16;
    const double step = 11; // 相邻表情的水平偏移
    return SizedBox(
      width: size + (shown.length - 1) * step,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 倒序绘制，让靠前的表情盖在上层
          for (var i = shown.length - 1; i >= 0; i--)
            Positioned(
              left: i * step,
              child: _OutlinedEmoji(
                image: emojiImageProvider(_getEmojiUrl(shown[i].id)),
                // 描边的作用是「咬掉」压在下面的表情一圈，
                // 最下层没有压着任何表情，无需描边
                outlineColor:
                    i == shown.length - 1 ? null : theme.colorScheme.surface,
                size: size,
              ),
            ),
        ],
      ),
    );
  }

  /// 构建点赞/回应区域
  ///
  /// 手势分配：
  /// - 点击 reaction stack（左半区，仅在已有 reactions 时存在）→ 查看回应人
  /// - 长按 reaction stack / like 图标 → 长按识别成功后打开 picker，
  ///   滑到表情松手即选，未滑中则停驻后点选
  /// - 点击 like 图标（右半区）→ toggleLike
  /// - 桌面端 hover 300ms → 触发 picker（直接进入选择模式）
  Widget _buildLikeReactionArea(ThemeData theme) {
    final reactionStackContent = (widget.reactions.isNotEmpty)
        ? Container(
            height: 36,
            padding: const EdgeInsets.only(left: 12),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!(widget.reactions.length == 1 &&
                    widget.reactions.first.id == 'heart')) ...[
                  _buildReactionStack(theme),
                  const SizedBox(width: 4),
                ],
                Text(
                  '${widget.reactions.fold(0, (sum, r) => sum + r.count)}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: widget.currentUserReaction != null
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          )
        : null;

    Widget? reactionStack;
    if (reactionStackContent != null) {
      reactionStack = widget.isOwnPost
          ? GestureDetector(
              onTap: () => widget.onShowReactionUsers(null),
              behavior: HitTestBehavior.opaque,
              child: reactionStackContent,
            )
          : RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: _touchGestures(() => widget.onShowReactionUsers(null)),
              child: reactionStackContent,
            );
    }

    // like 图标本身
    final likeIcon = Container(
      height: 36,
      padding: EdgeInsets.only(
        left: widget.reactions.isNotEmpty ? 0 : 12,
        right: 12,
      ),
      alignment: Alignment.center,
      child: widget.currentUserReaction != null
          ? Image(
              image:
                  emojiImageProvider(_getEmojiUrl(widget.currentUserReaction!.id)),
              width: 20,
              height: 20,
              errorBuilder: (_, _, _) => const Icon(Symbols.favorite_rounded, size: 20),
            )
          : Icon(
              Symbols.favorite_rounded,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
    );

    // like 图标的手势层：tap = toggleLike；long press = Tapback 风格 picker。
    // 自己的帖子：无 tap、无长按
    final likeButton = widget.isOwnPost
        ? likeIcon
        : RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: _touchGestures(() {
              if (!widget.isLiking) widget.onToggleLike();
            }),
            child: likeIcon,
          );

    Widget area = Container(
      height: 36,
      decoration: BoxDecoration(
        color: widget.currentUserReaction != null
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: widget.currentUserReaction != null
              ? theme.colorScheme.primary.withValues(alpha: 0.2)
              : Colors.transparent,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?reactionStack,
          likeButton,
        ],
      ),
    );

    // 按下预反馈(缩小压暗)与选中落地弹跳。key 挂在变换之外:
    // RenderTransform 自身的尺寸/位置不受其 transform 影响,
    // 按下态下测出的锚点 Rect 仍是按钮的真实布局矩形。
    if (!widget.isOwnPost) {
      area = KeyedSubtree(
        key: widget.likeButtonKey,
        child: ScaleTransition(
          scale: _bounceScale,
          child: AnimatedScale(
            scale: _pressed ? 0.96 : 1.0,
            duration: Duration(milliseconds: _pressed ? 100 : 160),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: _pressed ? 0.82 : 1.0,
              duration: const Duration(milliseconds: 120),
              child: area,
            ),
          ),
        ),
      );
    } else {
      area = KeyedSubtree(key: widget.likeButtonKey, child: area);
    }

    // 桌面端：hover 延迟触发表情选择器
    if (PlatformUtils.isDesktop && !widget.isOwnPost) {
      area = MouseRegion(
        onEnter: (_) => _onHoverEnter(),
        onExit: (_) => _onHoverExit(),
        child: area,
      );
    }

    return area;
  }
}

/// 带轮廓描边的表情：底层用染成 outlineColor 的表情副本向 8 个方向偏移，
/// 形成沿图形轮廓的描边（贴纸效果）；outlineColor 为 null 时只画原图。
///
/// 用 CustomPaint 在同一图层画 9 遍(8 次描边 + 1 次原图,颜色滤镜设在
/// Paint 上),而不是叠 9 个 Image + ColorFiltered —— 后者是 9 个 widget
/// 的构建/布局成本外加 8 次 saveLayer 离屏合成,曾是楼层挂载耗时与
/// raster saveLayer 数量的大头。
class _OutlinedEmoji extends StatefulWidget {
  final ImageProvider image;
  final Color? outlineColor;
  final double size;

  const _OutlinedEmoji({
    required this.image,
    required this.outlineColor,
    required this.size,
  });

  @override
  State<_OutlinedEmoji> createState() => _OutlinedEmojiState();
}

class _OutlinedEmojiState extends State<_OutlinedEmoji> {
  ImageStream? _stream;
  ImageInfo? _imageInfo;
  bool _failed = false;

  late final ImageStreamListener _listener = ImageStreamListener(
    (ImageInfo info, bool _) {
      if (!mounted) {
        info.dispose();
        return;
      }
      setState(() {
        _imageInfo?.dispose();
        _imageInfo = info;
        _failed = false;
      });
    },
    onError: (Object error, StackTrace? stackTrace) {
      if (mounted) {
        setState(() => _failed = true);
      }
    },
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _OutlinedEmoji oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image || widget.size != oldWidget.size) {
      _resolveImage();
    }
  }

  void _resolveImage() {
    final newStream = widget.image.resolve(
      createLocalImageConfiguration(
        context,
        size: Size(widget.size, widget.size),
      ),
    );
    if (newStream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = newStream..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _imageInfo?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _imageInfo;
    if (info == null || _failed) {
      return SizedBox(width: widget.size, height: widget.size);
    }
    return CustomPaint(
      size: Size(widget.size, widget.size),
      painter: _OutlinedEmojiPainter(
        image: info.image,
        outlineColor: widget.outlineColor,
      ),
    );
  }
}

class _OutlinedEmojiPainter extends CustomPainter {
  _OutlinedEmojiPainter({required this.image, required this.outlineColor});

  final ui.Image image;
  final Color? outlineColor;

  static const List<Offset> _outlineOffsets = [
    Offset(-1.5, 0),
    Offset(1.5, 0),
    Offset(0, -1.5),
    Offset(0, 1.5),
    Offset(-1.1, -1.1),
    Offset(1.1, -1.1),
    Offset(-1.1, 1.1),
    Offset(1.1, 1.1),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final dst = Offset.zero & size;
    final color = outlineColor;
    if (color != null) {
      final outlinePaint = Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn);
      for (final offset in _outlineOffsets) {
        canvas.drawImageRect(image, src, dst.shift(offset), outlinePaint);
      }
    }
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_OutlinedEmojiPainter oldDelegate) {
    return image != oldDelegate.image ||
        outlineColor != oldDelegate.outlineColor;
  }
}
