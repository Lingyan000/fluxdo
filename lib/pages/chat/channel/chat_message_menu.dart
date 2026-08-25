import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../l10n/s.dart';
import '../../../models/chat/chat_channel.dart';
import '../../../models/chat/chat_message.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../services/discourse_cache_manager.dart';
import '../../../services/emoji_handler.dart';
import '../../../services/toast_service.dart';
import '../../../utils/time_utils.dart';
import '../../../widgets/common/smart_avatar.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../../../widgets/markdown_editor/emoji_picker.dart';
import 'package:common_ui/common_ui.dart';

/// 菜单动作(对齐网页版 chat-message-interactor 的 secondaryActions)
enum ChatMessageAction {
  reply,
  copyText,
  copyLink,
  select,
  edit,
  flag,
  delete,
  restore,
  bookmark,
  pin,
  unpin,
}

/// 菜单结果:reaction 与动作二选一
typedef ChatMessageMenuResult = (ChatMessageAction?, String?);

/// 消息能力位(网页版 canEdit/canDelete/canRestore 语义)
class ChatMessageCaps {
  final bool canReply;
  final bool canEdit;
  final bool canFlag;
  final bool canDelete;
  final bool canRestore;

  /// 当前收藏态(bookmark 菜单项文案/图标切换)
  final bool bookmarked;

  /// 置顶管理(频道 can_manage_pins;站点关 chat_pinned_messages 时
  /// 服务端不下发该能力位,自然为 false)
  final bool canManagePins;
  final bool pinned;

  const ChatMessageCaps({
    required this.canReply,
    required this.canEdit,
    required this.canFlag,
    required this.canDelete,
    required this.canRestore,
    this.bookmarked = false,
    this.canManagePins = false,
    this.pinned = false,
  });

  factory ChatMessageCaps.compute({
    required ChatMessage message,
    required bool isSelf,
    required ChatChannel? channel,
  }) {
    final deleted = message.isDeleted;
    return ChatMessageCaps(
      canReply: !deleted,
      canEdit: !deleted && isSelf,
      // 服务端 available_flags 已按 本人/DM/权限/已举报 过滤,空即不可举报
      canFlag: !deleted && !isSelf && message.availableFlags.isNotEmpty,
      canDelete:
          !deleted &&
          ((isSelf && (channel?.canDeleteSelf ?? true)) ||
              (!isSelf && (channel?.canDeleteOthers ?? false))),
      canRestore: deleted && (isSelf || (channel?.canModerate ?? false)),
      bookmarked: message.bookmark != null,
      canManagePins: !deleted && (channel?.canManagePins ?? false),
      pinned: message.pinned,
    );
  }
}

// ============================ 快速 reaction ============================

const String _kRecentReactionsKey = 'chat_recent_reactions';

/// 站点默认快速 reaction(default_emoji_reactions 的通用值)
const List<String> _kDefaultReactions = ['heart', '+1', 'laughing'];

/// 快速 reaction 序列:最近使用优先 + 默认兜底去重(对齐网页版
/// "自定义 > 常用 > 默认"的合成顺序,自定义档暂无用户配置入口)
Future<List<String>> loadQuickReactions({int limit = 7}) async {
  final prefs = await SharedPreferences.getInstance();
  final recent = prefs.getStringList(_kRecentReactionsKey) ?? const [];
  final merged = <String>[...recent, ..._kDefaultReactions];
  final seen = <String>{};
  return [
    for (final e in merged)
      if (seen.add(e)) e,
  ].take(limit).toList();
}

/// 记录一次 reaction 使用(供快速行排序)
Future<void> bumpRecentReaction(String emoji) async {
  final prefs = await SharedPreferences.getInstance();
  final recent = prefs.getStringList(_kRecentReactionsKey) ?? [];
  recent.remove(emoji);
  recent.insert(0, emoji);
  await prefs.setStringList(_kRecentReactionsKey, recent.take(12).toList());
}

// ============================ 共享动作执行 ============================

/// 复制消息链接(网页版 copyLink,路径口径 /chat/c/-/:channel/:message)
void copyChatMessageLink(ChatMessage message) {
  final url =
      '${DiscourseService.baseUrl}/chat/c/-/${message.channelId}/${message.id}';
  Clipboard.setData(ClipboardData(text: url));
  ToastService.showSuccess(S.current.common_copiedToClipboard);
}

/// 复制消息原文
void copyChatMessageText(ChatMessage message) {
  Clipboard.setData(ClipboardData(text: message.message));
  ToastService.showSuccess(S.current.common_copiedToClipboard);
}

/// 完整 emoji picker;移动走可拖拽弹层,桌面走居中紧凑弹窗
Future<String?> showChatEmojiPicker(
  BuildContext context, {
  required bool desktop,
}) {
  if (!desktop) {
    return AppBottomSheet.showDraggable<String>(
      context: context,
      initialSize: 0.55,
      minSize: 0.4,
      bodyBuilder: (pickerContext, scrollController) => EmojiPicker(
        onEmojiSelected: (emoji) => Navigator.pop(pickerContext, emoji.name),
      ),
    );
  }
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 380,
        height: 460,
        child: EmojiPicker(
          compact: true,
          inlineSearch: true,
          onEmojiSelected: (emoji) => Navigator.pop(dialogContext, emoji.name),
        ),
      ),
    ),
  );
}

// ======================= 移动端:长按 overlay =======================

/// 长按菜单:背景模糊压暗,反应条/消息卡/菜单跟随长按位置就地
/// 展开(消息原地长出头部与卡壳,仅屏缘时最小位移让条/菜单放得下),
/// 关闭时收回原位与列表衔接。
Future<ChatMessageMenuResult?> showChatMessageActionsOverlay({
  required BuildContext context,
  required Rect bubbleRect,
  required WidgetBuilder bubbleBuilder,
  required ChatMessage message,
  required ChatMessageCaps caps,
  required List<String> quickReactions,
}) {
  HapticFeedback.mediumImpact();
  return Navigator.of(context, rootNavigator: true).push<ChatMessageMenuResult>(
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 190),
      pageBuilder: (routeContext, animation, _) => _MessageActionsOverlay(
        animation: animation,
        bubbleRect: bubbleRect,
        bubbleBuilder: bubbleBuilder,
        message: message,
        caps: caps,
        quickReactions: quickReactions,
      ),
    ),
  );
}

class _MessageActionsOverlay extends StatelessWidget {
  final Animation<double> animation;
  final Rect bubbleRect;
  final WidgetBuilder bubbleBuilder;
  final ChatMessage message;
  final ChatMessageCaps caps;
  final List<String> quickReactions;

  const _MessageActionsOverlay({
    required this.animation,
    required this.bubbleRect,
    required this.bubbleBuilder,
    required this.message,
    required this.caps,
    required this.quickReactions,
  });

  List<ChatMenuItemSpec> _menuItems(BuildContext context) =>
      buildChatMenuItems(context, caps: caps, includeCopyText: true);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final screen = media.size;
    final topSafe = media.padding.top;
    final bottomSafe = media.padding.bottom;

    final items = _menuItems(context);
    final mainItems = items.where((i) => !i.destructive).toList();
    final destItems = items.where((i) => i.destructive).toList();

    const edge = 12.0;
    const gap = 10.0;
    const barHeight = 48.0;
    const menuWidth = 252.0;
    const rowHeight = 46.0;
    const hairline = 0.5;

    // 菜单:主动作卡 + 危险动作独立卡(双卡分组,红字自成一岛),
    // 行内 label 左/icon 右,行间发丝线
    double cardHeightOf(int n) =>
        n == 0 ? 0.0 : n * rowHeight + 12 + (n - 1) * hairline;
    final mainMenuHeight = cardHeightOf(mainItems.length);
    final destMenuHeight = cardHeightOf(destItems.length);
    var menuHeight =
        mainMenuHeight +
        (destItems.isEmpty || mainItems.isEmpty ? 0 : gap) +
        destMenuHeight;
    final menuMaxHeight = screen.height * 0.5;
    final menuScrollable = menuHeight > menuMaxHeight;
    if (menuScrollable) menuHeight = menuMaxHeight;

    // 消息卡:头部(头像+昵称+时间)在飞行中显形。
    // 目标宽:量测宽装不下头部行(纯 emoji/短消息几十 px)时按头部
    // 最小需求扩,封顶屏宽;宽度随飞行插值,第 0 帧仍与列表对齐
    const headerHeight = 40.0;
    const headerMinWidth = 232.0;
    final targetWidth = math.min(
      screen.width - edge * 2,
      math.max(bubbleRect.width, headerMinWidth),
    );
    final cardHeight = headerHeight + bubbleRect.height;

    // 纵向:跟随长按位置(屏底固定簇被否——长按上半屏消息、菜单却
    // 在屏底出现,手眼脱节)。理想位 = 消息原地不动(头部向上长出),
    // 仅在条放不下(太靠顶)或菜单放不下(太靠底)时最小位移 clamp;
    // 整簇高过屏(超长消息)时卡顶钉在条下方,菜单钉屏底盖住卡下半部
    // (菜单不透明,天然分层)
    final bottomLimit = screen.height - bottomSafe - 16;
    final desiredCardTop = bubbleRect.top - headerHeight;
    final minCardTop = topSafe + 12 + barHeight + gap;
    final maxCardTop = bottomLimit - menuHeight - gap - cardHeight;
    final double cardTop;
    final double menuTop;
    if (maxCardTop < minCardTop) {
      cardTop = minCardTop;
      menuTop = bottomLimit - menuHeight;
    } else {
      cardTop = desiredCardTop.clamp(minCardTop, maxCardTop);
      menuTop = cardTop + cardHeight + gap;
    }
    final barTop = cardTop - gap - barHeight;

    // 横向:也跟随消息左缘(clamp 进屏),条/卡/菜单共享这条构图线
    final targetLeft = bubbleRect.left
        .clamp(edge, math.max(edge, screen.width - edge - targetWidth))
        .toDouble();
    final menuLeft = math.max(
      edge,
      math.min(targetLeft, screen.width - edge - menuWidth),
    );
    final barMaxWidth = screen.width - targetLeft - edge;

    // 第 0 帧正文对齐列表原文:卡顶 = 原文顶 - 头部高(头部透明不可见)。
    // 未被 clamp 时 startTop == cardTop,消息原地不动,只有头部长出
    final startTop = bubbleRect.top - headerHeight;

    // 编排:只有消息在飞(被拎到聚光灯下),条/菜单在簇位原地长出
    // ——条 15% 起弹(easeOutBack 回弹),菜单 22% 跟进;退场全员
    // easeIn 快收,消息飞回原位与列表衔接
    final moveT = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final barScaleT = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.15, 0.85, curve: Curves.easeOutBack),
      reverseCurve: Curves.easeInCubic,
    );
    final barFadeT = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.15, 0.50, curve: Curves.easeOut),
      reverseCurve: Curves.easeInCubic,
    );
    final menuScaleT = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.22, 1.0, curve: Curves.easeOutBack),
      reverseCurve: Curves.easeInCubic,
    );
    final menuFadeT = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.22, 0.60, curve: Curves.easeOut),
      reverseCurve: Curves.easeInCubic,
    );

    return AnimatedBuilder(
      animation: animation,
      // 副本内容只构建一次:builder 每帧重建 _buildBubbleCore(markdown/
      // emoji 渲染)会让副本闪烁。child 跨帧复用,每帧只更新外围装饰。
      child: bubbleBuilder(context),
      builder: (context, child) {
        final t = moveT.value;
        final left = bubbleRect.left + (targetLeft - bubbleRect.left) * t;
        final top = startTop + (cardTop - startTop) * t;
        final width = bubbleRect.width + (targetWidth - bubbleRect.width) * t;
        return Stack(
          children: [
            // 背景:重模糊 + 压暗聚焦,点击关闭
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16 * t, sigmaY: 16 * t),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.32 * t),
                  ),
                ),
              ),
            ),
            // 消息卡:第 0 帧与列表原文逐像素一致(正文全程不透明、
            // 壳全透明),飞行途中底色/投影/头部渐次显形
            Positioned(
              left: left,
              top: top,
              width: width,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      if (t > 0)
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25 * t),
                          blurRadius: 24 * t,
                          offset: Offset(0, 8 * t),
                        ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh
                            .withValues(alpha: t),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: headerHeight,
                            child: Opacity(
                              opacity: t,
                              // 头部恒按目标宽布局(OverflowBox 解除窄卡
                              // 约束),ClipRect 裁到当前动画宽——展开即
                              // 逐渐揭示;此前 Row 在窄约束下布局,debug
                              // 溢出条纹照画(ClipRect 只裁不了布局溢出)
                              child: ClipRect(
                                child: OverflowBox(
                                  alignment: Alignment.centerLeft,
                                  minWidth: targetWidth,
                                  maxWidth: targetWidth,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      10,
                                      10,
                                      12,
                                      0,
                                    ),
                                    child: Row(
                                      children: [
                                        SmartAvatar(
                                          imageUrl: message.user?.getAvatarUrl(
                                            size: 64,
                                          ),
                                          radius: 11,
                                          fallbackText: message.user?.username,
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            message.user?.name?.isNotEmpty ==
                                                    true
                                                ? message.user!.name!
                                                : (message.user?.username ??
                                                      ''),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.labelMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          TimeUtils.formatDetailTime(
                                            message.createdAt,
                                          ),
                                          maxLines: 1,
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                color:
                                                    theme.colorScheme.outline,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          child!,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 反应条:簇顶原地弹出,emoji 逐个瀑布跟进
            Positioned(
              left: targetLeft,
              top: barTop,
              child: Transform.scale(
                scale: 0.92 + 0.08 * barScaleT.value,
                alignment: Alignment.bottomLeft,
                child: Opacity(
                  opacity: barFadeT.value.clamp(0.0, 1.0),
                  child: _ReactionBar(
                    message: message,
                    quickReactions: quickReactions,
                    maxWidth: barMaxWidth,
                    progress: animation.value,
                    onSelect: (emoji) => Navigator.pop(context, (null, emoji)),
                    onMore: () async {
                      final selected = await showChatEmojiPicker(
                        context,
                        desktop: false,
                      );
                      if (selected != null && context.mounted) {
                        Navigator.pop(context, (null, selected));
                      }
                    },
                  ),
                ),
              ),
            ),
            // 菜单双卡:簇底原地长出(scale 从顶缘展开)
            Positioned(
              left: menuLeft,
              top: menuTop,
              child: Transform.scale(
                scale: 0.94 + 0.06 * menuScaleT.value,
                alignment: Alignment.topLeft,
                child: Opacity(
                  opacity: menuFadeT.value.clamp(0.0, 1.0),
                  child: _buildMenuCards(
                    context,
                    theme,
                    mainItems,
                    destItems,
                    width: menuWidth,
                    gap: gap,
                    maxHeight: menuHeight,
                    scrollable: menuScrollable,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 菜单双卡:主动作一卡,危险动作(删除等)独立红卡;
  /// 行 = label 左 + icon 右,行间发丝线
  Widget _buildMenuCards(
    BuildContext context,
    ThemeData theme,
    List<ChatMenuItemSpec> mainItems,
    List<ChatMenuItemSpec> destItems, {
    required double width,
    required double gap,
    required double maxHeight,
    required bool scrollable,
  }) {
    Widget row(ChatMenuItemSpec item) {
      final color = item.destructive
          ? theme.colorScheme.error
          : theme.colorScheme.onSurface;
      return InkWell(
        onTap: () => Navigator.pop(context, (item.action, null)),
        child: SizedBox(
          height: 46,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    item.label,
                    style: theme.textTheme.bodyMedium?.copyWith(color: color),
                  ),
                ),
                Icon(
                  item.icon,
                  size: 20,
                  color: item.destructive
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget card(List<ChatMenuItemSpec> list) => Material(
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < list.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 0.5,
                  thickness: 0.5,
                  indent: 16,
                  endIndent: 16,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.2,
                  ),
                ),
              row(list[i]),
            ],
          ],
        ),
      ),
    );

    Widget column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (mainItems.isNotEmpty) card(mainItems),
        if (mainItems.isNotEmpty && destItems.isNotEmpty) SizedBox(height: gap),
        if (destItems.isNotEmpty) card(destItems),
      ],
    );
    if (scrollable) {
      column = SizedBox(
        height: maxHeight,
        child: SingleChildScrollView(child: column),
      );
    }
    return SizedBox(width: width, child: column);
  }
}

/// 悬浮反应条:横排 emoji(可滚) + "+";入场时 emoji 逐个瀑布弹入
class _ReactionBar extends StatelessWidget {
  final ChatMessage message;
  final List<String> quickReactions;

  /// 可用宽度上限(由簇左缘右侧余量算出;超出的 emoji 走横滚)
  final double maxWidth;

  /// 路由动画原始进度:驱动 emoji 逐个弹入的瀑布(每个错 5%,
  /// easeOutBack 带回弹;退场反向瀑布收拢)
  final double progress;
  final void Function(String emoji) onSelect;
  final VoidCallback onMore;

  const _ReactionBar({
    required this.message,
    required this.quickReactions,
    required this.maxWidth,
    required this.progress,
    required this.onSelect,
    required this.onMore,
  });

  Widget _staggered(int index, Widget child) {
    final start = math.min(0.20 + index * 0.05, 0.62);
    final end = math.min(start + 0.34, 1.0);
    final t = Interval(
      start,
      end,
      curve: Curves.easeOutBack,
    ).transform(progress.clamp(0.0, 1.0));
    return Transform.scale(
      scale: 0.4 + 0.6 * t,
      child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      shape: StadiumBorder(
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < quickReactions.length; i++)
                _staggered(
                  i,
                  _ReactionBarButton(
                    emoji: quickReactions[i],
                    reacted: message.reactions.any(
                      (r) => r.emoji == quickReactions[i] && r.reacted,
                    ),
                    onTap: () => onSelect(quickReactions[i]),
                  ),
                ),
              _staggered(
                quickReactions.length,
                InkWell(
                  onTap: onMore,
                  customBorder: const CircleBorder(),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Symbols.add_rounded,
                      size: 24,
                      color: theme.colorScheme.onSurfaceVariant,
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
}

class _ReactionBarButton extends StatelessWidget {
  final String emoji;
  final bool reacted;
  final VoidCallback onTap;

  const _ReactionBarButton({
    required this.emoji,
    required this.reacted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = EmojiHandler().getEmojiUrl(emoji);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        padding: const EdgeInsets.all(7),
        decoration: reacted
            ? BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                shape: BoxShape.circle,
              )
            : null,
        child: url.isEmpty
            ? Text(emoji, style: const TextStyle(fontSize: 22))
            : Image(image: emojiImageProvider(url), width: 26, height: 26),
      ),
    );
  }
}

// ======================= 桌面端:右键/更多 锚点菜单 =======================

/// 桌面锚点菜单(右键、hover 工具条"更多"共用):
/// 首行 reaction 条 + 动作项,showSwipeDismissibleMenu 外壳。
Future<ChatMessageMenuResult?> showChatMessageContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required ChatMessage message,
  required bool isSelf,
  required ChatMessageCaps caps,
  required List<String> quickReactions,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final position = RelativeRect.fromLTRB(
    globalPosition.dx,
    globalPosition.dy,
    overlay.size.width - globalPosition.dx,
    overlay.size.height - globalPosition.dy,
  );
  final items = buildChatMenuItems(context, caps: caps, includeCopyText: true);
  return showSwipeDismissibleMenu<ChatMessageMenuResult>(
    context: context,
    position: position,
    items: [
      if (!message.isDeleted)
        _ReactionRowEntry(message: message, quickReactions: quickReactions),
      for (final item in items)
        PopupMenuItem<ChatMessageMenuResult>(
          value: (item.action, null),
          height: 42,
          child: Row(
            children: [
              Icon(
                item.icon,
                size: 20,
                color: item.destructive
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Text(
                item.label,
                style: item.destructive
                    ? TextStyle(color: Theme.of(context).colorScheme.error)
                    : null,
              ),
            ],
          ),
        ),
    ],
  );
}

/// 弹出菜单首行:快速 reaction 行(自绘 entry,点击带值收起菜单)
class _ReactionRowEntry extends PopupMenuEntry<ChatMessageMenuResult> {
  final ChatMessage message;
  final List<String> quickReactions;

  const _ReactionRowEntry({
    required this.message,
    required this.quickReactions,
  });

  @override
  double get height => 48;

  @override
  bool represents(ChatMessageMenuResult? value) => false;

  @override
  State<_ReactionRowEntry> createState() => _ReactionRowEntryState();
}

class _ReactionRowEntryState extends State<_ReactionRowEntry> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final emoji in widget.quickReactions.take(5))
            _ReactionBarButton(
              emoji: emoji,
              reacted: widget.message.reactions.any(
                (r) => r.emoji == emoji && r.reacted,
              ),
              onTap: () => Navigator.pop(context, (null, emoji)),
            ),
          InkWell(
            onTap: () async {
              final selected = await showChatEmojiPicker(
                context,
                desktop: true,
              );
              if (selected != null && context.mounted) {
                Navigator.pop(context, (null, selected));
              }
            },
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: Icon(
                Symbols.add_rounded,
                size: 22,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================ 菜单项定义 ============================

/// 菜单项条目(内部与聊天页共用,故公开)
class ChatMenuItemSpec {
  final ChatMessageAction action;
  final IconData icon;
  final String label;
  final bool destructive;

  const ChatMenuItemSpec(
    this.action,
    this.icon,
    this.label, {
    this.destructive = false,
  });
}

/// 菜单项(顺序与网页版 secondaryActions 一致:链接/文本/回复/编辑/删除/恢复)
List<ChatMenuItemSpec> buildChatMenuItems(
  BuildContext context, {
  required ChatMessageCaps caps,
  required bool includeCopyText,
}) {
  final l10n = context.l10n;
  return [
    if (caps.canReply)
      ChatMenuItemSpec(
        ChatMessageAction.reply,
        Symbols.reply_rounded,
        l10n.chat_menuReply,
      ),
    ChatMenuItemSpec(
      ChatMessageAction.copyLink,
      Symbols.link_rounded,
      l10n.chat_menuCopyLink,
    ),
    ChatMenuItemSpec(
      ChatMessageAction.bookmark,
      caps.bookmarked
          ? Symbols.bookmark_remove_rounded
          : Symbols.bookmark_add_rounded,
      caps.bookmarked ? l10n.chat_menuRemoveBookmark : l10n.chat_menuBookmark,
    ),
    if (includeCopyText && !caps.canRestore)
      ChatMenuItemSpec(
        ChatMessageAction.copyText,
        Symbols.content_copy_rounded,
        l10n.chat_menuCopy,
      ),
    if (!caps.canRestore)
      ChatMenuItemSpec(
        ChatMessageAction.select,
        Symbols.checklist_rounded,
        l10n.chat_menuSelect,
      ),
    if (caps.canEdit)
      ChatMenuItemSpec(
        ChatMessageAction.edit,
        Symbols.edit_rounded,
        l10n.chat_menuEdit,
      ),
    if (caps.canManagePins)
      caps.pinned
          ? ChatMenuItemSpec(
              ChatMessageAction.unpin,
              Symbols.keep_off_rounded,
              l10n.chat_menuUnpin,
            )
          : ChatMenuItemSpec(
              ChatMessageAction.pin,
              Symbols.keep_rounded,
              l10n.chat_menuPin,
            ),
    if (caps.canFlag)
      ChatMenuItemSpec(
        ChatMessageAction.flag,
        Symbols.flag_rounded,
        l10n.chat_menuFlag,
      ),
    if (caps.canDelete)
      ChatMenuItemSpec(
        ChatMessageAction.delete,
        Symbols.delete_rounded,
        l10n.chat_menuDelete,
        destructive: true,
      ),
    if (caps.canRestore)
      ChatMenuItemSpec(
        ChatMessageAction.restore,
        Symbols.restore_from_trash_rounded,
        l10n.chat_menuRestore,
      ),
  ];
}
