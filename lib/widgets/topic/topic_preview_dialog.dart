import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/topic.dart';
import '../../services/topic_preview_preloader.dart';
import '../../models/category.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/selected_topic_provider.dart';
import '../../utils/color_utils.dart';
import '../../utils/share_utils.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';
import '../common/relative_time_text.dart';
import '../common/morphing_dialog_shell.dart';
import '../common/skeleton.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/number_utils.dart';
import '../common/emoji_text.dart';
import '../common/smart_avatar.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../pages/category_topics_page.dart';
import '../../pages/tag_topics_page.dart';
import '../../../../../l10n/s.dart';

/// 预览弹窗中的操作项
class PreviewAction {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const PreviewAction({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
  });
}

/// 取卡片(或任意锚点 widget)的屏幕 rect 作为一镜到底动画起点。
/// [cardContext] 必须是卡片自身的 context(Builder 紧贴卡片构造);
/// 卡片外壳含底部间距(Padding),[bottomGap] 裁掉后才是视觉卡身:
/// 普通/自绘卡 8、置顶紧凑卡 6。卡片未挂载/未布局时返回 null。
Rect? topicCardAnchorRect(BuildContext cardContext, {double bottomGap = 8}) {
  final box = cardContext.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  final origin = box.localToGlobal(Offset.zero);
  return Rect.fromLTRB(
    origin.dx,
    origin.dy,
    origin.dx + box.size.width,
    origin.dy + box.size.height - bottomGap,
  );
}

/// 话题预览弹窗 - 长按卡片时显示
class TopicPreviewDialog extends ConsumerStatefulWidget {
  final Topic topic;
  final VoidCallback? onOpen;
  final List<PreviewAction>? actions;
  final WidgetBuilder? customActionPanelBuilder;
  final Future<String?> Function()? firstPostLoader;

  /// 锚点上下文所在的平行视界栈(show 时捕获)。弹窗自身是独立路由,
  /// 体内 context 找不到 EmbeddedStackScope;预览内容里的内链点击要
  /// 压回锚点的栈(与正文内链同语义),没有则全屏 push。
  final SelectedTopicProvider? paneStack;

  /// 一镜到底模式:非空时弹窗壳从 [anchorRect](长按卡片的屏幕 rect)
  /// 连续变形到居中弹窗 —— 内容自始至终嵌在壳内随其变形(裁剪窗从
  /// 卡片大小展开),没有"空壳飞行"段;关闭沿同路径收回。由路由
  /// animation 驱动([show] 的 anchorRect 路径传入)。
  final Animation<double>? morphAnimation;

  /// 一镜到底起点:卡片的屏幕 rect(已裁掉卡片底部间距)
  final Rect? anchorRect;

  /// 一镜到底起点底色:卡片外壳底色(surfaceContainerLow 系),
  /// 与弹窗壳 surface 做插值,起步无缝
  final Color? anchorColor;

  /// 一镜到底起点圆角(卡片 10 → 弹窗 20)
  final double anchorRadius;

  const TopicPreviewDialog({
    super.key,
    required this.topic,
    this.onOpen,
    this.actions,
    this.customActionPanelBuilder,
    this.firstPostLoader,
    this.paneStack,
    this.morphAnimation,
    this.anchorRect,
    this.anchorColor,
    this.anchorRadius = 10,
  });

  @override
  ConsumerState<TopicPreviewDialog> createState() => _TopicPreviewDialogState();

  /// 显示预览弹窗
  ///
  /// [anchorRect] 为长按卡片的全局 rect(已裁掉卡片底部间距)。
  /// 传入时走一镜到底:弹窗壳从卡片位置/底色/圆角连续变形到居中
  /// 弹窗,关闭沿同路径收回;未传入回退为中心缩放(防御兜底)。
  static Future<void> show(
    BuildContext context, {
    required Topic topic,
    VoidCallback? onOpen,
    List<PreviewAction>? actions,
    WidgetBuilder? customActionPanelBuilder,
    Future<String?> Function()? firstPostLoader,
    Rect? anchorRect,
    Color? anchorColor,
    double anchorRadius = 10,
  }) {
    // 触觉反馈
    HapticFeedback.mediumImpact();

    // pop 弹窗后锚点 context 可能已失效,进弹窗前先捕获平行视界栈。
    final paneStack = EmbeddedStackScope.maybeOf(context);

    if (anchorRect != null) {
      // 一镜到底:变形由弹窗内部根据路由 animation 自驱(内容嵌在壳内
      // 随壳变形),这里 transitionBuilder 必须恒等 —— 默认的整页淡入
      // 会让壳从透明浮现,破坏"卡片浮起"的连续性
      return showAppGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: S.current.common_closePreview,
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 350),
        transitionBuilder: (context, animation, secondaryAnimation, child) =>
            child,
        pageBuilder: (context, animation, secondaryAnimation) {
          return TopicPreviewDialog(
            topic: topic,
            onOpen: onOpen,
            actions: actions,
            customActionPanelBuilder: customActionPanelBuilder,
            firstPostLoader: firstPostLoader,
            paneStack: paneStack,
            morphAnimation: animation,
            anchorRect: anchorRect,
            anchorColor: anchorColor,
            anchorRadius: anchorRadius,
          );
        },
      );
    }

    return showAppGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: S.current.common_closePreview,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) {
        return TopicPreviewDialog(
          topic: topic,
          onOpen: onOpen,
          actions: actions,
          customActionPanelBuilder: customActionPanelBuilder,
          firstPostLoader: firstPostLoader,
          paneStack: paneStack,
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
        );
        return ScaleTransition(
          scale: curvedAnimation,
          child: FadeTransition(opacity: animation, child: child),
        );
      },
    );
  }
}

class _TopicPreviewDialogState extends ConsumerState<TopicPreviewDialog> {
  String? _firstPostCooked;
  bool _isLoading = true;
  bool _loadFailed = false;

  Topic get topic => widget.topic;

  @override
  void initState() {
    super.initState();
    _loadFirstPost();
  }

  Future<void> _loadFirstPost() async {
    try {
      // 优先消费长按意图期的预加载 Future(弹窗打开时数据多已在路上);
      // 未命中(直接构造/意图未触发/过期)才现场请求
      final cooked = widget.firstPostLoader != null
          ? await widget.firstPostLoader!()
          : await (TopicPreviewPreloader.take(topic.id) ??
                ref
                    .read(discourseServiceProvider)
                    .getTopicFirstPostCooked(topic.id));
      if (!mounted) return;
      setState(() {
        _firstPostCooked = cooked;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.of(context).size;
    final maxWidth = screenSize.width * 0.9;
    final maxHeight = screenSize.height * 0.7;

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final categoryId = int.tryParse(topic.categoryId);
    final category = categoryMap?[categoryId];

    final hasActions = widget.actions != null && widget.actions!.isNotEmpty;
    final hasCustomActionPanel = widget.customActionPanelBuilder != null;

    final morphing = widget.morphAnimation != null;

    // 壳体内容(两种模式共用):自定义面板(书签快捷重命名,固定) + 整体
    // 滚动区(标题/元信息/标签/正文一起滚,内容可视区最大化) + 固定底栏。
    // 无渐变条/大边框 chip/2x2 统计网格 —— 对齐 X/Telegram 预览卡
    final sheetBody = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasCustomActionPanel)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: widget.customActionPanelBuilder!(context),
          ),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              hasCustomActionPanel ? 12 : 16,
              20,
              16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTitle(context, theme),
                const SizedBox(height: 8),
                _buildMetaRow(context, theme, category),
                if (topic.tags.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _buildTagsLine(context, theme),
                ],
                const SizedBox(height: 12),
                _buildPostContent(context, theme),
              ],
            ),
          ),
        ),
        _buildBottomBar(context, theme),
      ],
    );

    final contentColumn = Column(
      key: const ValueKey('topic-preview-root'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          // 一镜到底模式的底色/圆角/阴影/裁剪全由飞行壳提供,这里只留
          // transparency Material 作 InkWell 载体,避免双层壳叠加
          child: morphing
              ? Material(type: MaterialType.transparency, child: sheetBody)
              : Material(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  elevation: 8,
                  child: sheetBody,
                ),
        ),
        if (hasActions) ...[
          const SizedBox(height: 8),
          _buildCustomActions(context, theme),
        ],
      ],
    );

    if (morphing) {
      return MorphingDialogShell(
        animation: widget.morphAnimation!,
        anchorRect: widget.anchorRect!,
        anchorColor: widget.anchorColor,
        anchorRadius: widget.anchorRadius,
        child: contentColumn,
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth.clamp(300, 500),
          maxHeight: maxHeight,
        ),
        child: contentColumn,
      ),
    );
  }

  Widget _buildPostContent(BuildContext context, ThemeData theme) {
    if (_isLoading) return _buildBodySkeleton();

    if (_firstPostCooked != null &&
        _firstPostCooked!.isNotEmpty &&
        !_loadFailed) {
      // 加载成功：渲染主贴 HTML
      final contentFontScale = ref.watch(preferencesProvider).contentFontScale;
      return FluxdoRenderCallbacks.generic(
        heroTagNamespace: 'topic_preview_${topic.id}',
        topicId: topic.id,
        onInternalLinkTap: (topicId, topicSlug, postNumber) {
          // 锚点在平行视界面板里=压回其栈(show 时捕获,pop 后锚点
          // context 已不可用);否则全屏 push。container/navigator 都要
          // 在 pop 前取——pop 后本 context deactivate,祖先查找会抛。
          final stack = widget.paneStack;
          final container = stack != null
              ? ProviderScope.containerOf(context, listen: false)
              : null;
          final navigator = Navigator.of(context);
          navigator.pop();
          if (stack != null) {
            container!
                .read(stack.notifier)
                .push(
                  topicId: topicId,
                  initialTitle: topicSlug,
                  scrollToPostNumber: postNumber,
                );
            return;
          }
          navigator.push(
            MaterialPageRoute(
              builder: (_) => TopicDetailPage(
                topicId: topicId,
                initialTitle: topicSlug,
                scrollToPostNumber: postNumber,
              ),
            ),
          );
        },
      ).render(
        cookedHtml: _firstPostCooked!,
        baseTextStyle: theme.textTheme.bodyMedium?.copyWith(
          height: 1.5,
          fontSize:
              (theme.textTheme.bodyMedium?.fontSize ?? 14) * contentFontScale,
        ),
        compact: true,
        selectionEnabled: false,
      );
    }

    // 加载失败：降级展示 excerpt
    if (topic.excerpt != null && topic.excerpt!.isNotEmpty) {
      return _buildExcerptFallback(theme);
    }

    return const SizedBox.shrink();
  }

  /// 正文加载骨架:三段段落条(shimmer 呼吸),高度与真实正文首屏
  /// 同量级 —— 加载完成前后壳高度变化更平缓,一镜到底更顺
  Widget _buildBodySkeleton() {
    return const Skeleton(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(height: 12, width: double.infinity),
          SizedBox(height: 10),
          SkeletonBox(height: 12, width: double.infinity),
          SizedBox(height: 10),
          FractionallySizedBox(
            widthFactor: 0.72,
            child: SkeletonBox(height: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildExcerptFallback(ThemeData theme) {
    final cleanExcerpt = topic.excerpt!
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&hellip;', '...')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();

    if (cleanExcerpt.isEmpty) return const SizedBox.shrink();

    final contentFontScale = ref.watch(preferencesProvider).contentFontScale;
    // 纯文本无色块:预览是轻量一瞥,excerpt 不需要卡片式衬底
    return Text(
      cleanExcerpt,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: 1.6,
        fontSize:
            (theme.textTheme.bodyMedium?.fontSize ?? 14) * contentFontScale,
      ),
      maxLines: 8,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildTitle(BuildContext context, ThemeData theme) {
    // 17pt w600:卡片标题 15pt → 预览 17pt,一镜到底换皮更顺滑;
    // 最多 3 行防爆版。状态图标(lock/pin/answered)随文字同档缩小
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      height: 1.35,
    );
    // 无关闭按钮:点遮罩/返回手势/预测返回即关闭 —— 与 X/Telegram/
    // iOS peek 等现代预览一致,关闭入口不占卡片视觉重心
    return Text.rich(
      TextSpan(
        style: titleStyle,
        children: [
          if (topic.closed)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Icon(
                  Symbols.lock_rounded,
                  size: 17,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (topic.pinned)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Icon(
                  Symbols.push_pin_rounded,
                  size: 17,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          if (topic.hasAcceptedAnswer)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Icon(
                  Symbols.check_box_rounded,
                  size: 17,
                  color: Colors.green,
                ),
              ),
            ),
          ...EmojiText.buildEmojiSpans(context, topic.title, titleStyle),
        ],
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 头部元信息行:头像 + 昵称 · 分类(可点) · 最后活跃;右端参与者
  /// 叠头像(>1 人时)。与话题卡第 2/3 行同构,一镜到底换皮更顺
  Widget _buildMetaRow(
    BuildContext context,
    ThemeData theme,
    Category? category,
  ) {
    String? avatarUrl;
    String username;
    if (topic.posters.isNotEmpty && topic.posters.first.user != null) {
      final op = topic.posters.first.user!;
      avatarUrl = op.getAvatarUrl(size: 40);
      username = op.displayName;
    } else {
      username = topic.lastPosterUsername ?? '';
    }
    final metaColor = theme.colorScheme.onSurfaceVariant;
    final separator = Text(
      '·',
      style: theme.textTheme.labelSmall?.copyWith(color: metaColor),
    );

    return Row(
      children: [
        SmartAvatar(imageUrl: avatarUrl, radius: 10, fallbackText: username),
        const SizedBox(width: 8),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  username,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (category != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: separator,
                ),
                Flexible(
                  child: GestureDetector(
                    onTap: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              CategoryTopicsPage(category: category),
                        ),
                      );
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildCategoryDot(context, category),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            category.name,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: metaColor,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: separator,
              ),
              RelativeTimeText(
                dateTime: topic.lastPostedAt,
                style: theme.textTheme.labelSmall?.copyWith(color: metaColor),
              ),
            ],
          ),
        ),
        if (topic.posters.length > 1) ...[
          const SizedBox(width: 8),
          _buildParticipantsStack(theme),
        ],
      ],
    );
  }

  /// 参与者叠头像(紧凑版):18px,最多 4 个,行尾右对齐
  Widget _buildParticipantsStack(ThemeData theme) {
    final participants = topic.posters.take(4).toList();
    return SizedBox(
      height: 18,
      width: 18 + (participants.length - 1) * 12,
      child: Stack(
        children: List.generate(participants.length, (index) {
          final poster = participants[index];
          String? avatarUrl;
          String fallback = '';
          if (poster.user != null) {
            avatarUrl = poster.user!.getAvatarUrl(size: 36);
            fallback = poster.user!.username;
          }
          return Positioned(
            left: index * 12.0,
            child: SmartAvatar(
              imageUrl: avatarUrl,
              radius: 9,
              fallbackText: fallback,
              border: Border.all(color: theme.colorScheme.surface, width: 1.5),
            ),
          );
        }),
      ),
    );
  }

  /// 标签轻文本行:与话题卡片(CategoryTagsLine)同款 —— "#" 前缀
  /// 60% 透明度 + 中性色名,可点跳标签页
  Widget _buildTagsLine(BuildContext context, ThemeData theme) {
    final metaColor = theme.colorScheme.onSurfaceVariant;
    final style = theme.textTheme.labelSmall?.copyWith(color: metaColor);
    final hashStyle = theme.textTheme.labelSmall?.copyWith(
      color: metaColor.withValues(alpha: 0.6),
    );
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      children: [
        for (final tag in topic.tags)
          GestureDetector(
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TagTopicsPage(tagName: tag.name),
                ),
              );
            },
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '#', style: hashStyle),
                  TextSpan(text: tag.name),
                ],
              ),
              style: style,
            ),
          ),
      ],
    );
  }

  /// 底栏:统计(💬回复 ❤点赞 👁浏览,内联小字)与操作(分享/查看详情)
  /// 合一。无关闭按钮 —— 点遮罩/返回手势即关,与现代预览一致
  Widget _buildBottomBar(BuildContext context, ThemeData theme) {
    final metaColor = theme.colorScheme.onSurfaceVariant;
    final statStyle = theme.textTheme.labelSmall?.copyWith(
      color: metaColor,
      fontWeight: FontWeight.w500,
    );
    final replies = (topic.postsCount - 1).clamp(0, 999999);

    Widget stat(IconData icon, int count) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: metaColor),
        const SizedBox(width: 3),
        Text(NumberUtils.formatCount(count), style: statStyle),
      ],
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          // 统计簇(左):三项恒显,窄屏自然压缩(字号小、间距紧)
          stat(Symbols.chat_bubble_rounded, replies),
          const SizedBox(width: 14),
          stat(Symbols.favorite_border_rounded, topic.likeCount),
          const SizedBox(width: 14),
          stat(Symbols.visibility_rounded, topic.views),
          const Spacer(),
          // 分享
          IconButton(
            onPressed: () {
              final user = ref.read(currentUserProvider).value;
              final prefs = ref.read(preferencesProvider);
              final url = ShareUtils.buildShareUrl(
                path: '/t/topic/${topic.id}',
                username: user?.username,
                anonymousShare: prefs.anonymousShare,
              );
              SharePlus.instance.share(ShareParams(text: url));
            },
            icon: const Icon(Symbols.share_rounded, size: 20),
            tooltip: S.current.common_share,
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          // 查看详情(主操作)
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onOpen?.call();
            },
            icon: const Icon(Symbols.open_in_new_rounded, size: 18),
            label: Text(S.current.common_viewDetails),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomActions(BuildContext context, ThemeData theme) {
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      elevation: 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: widget.actions!.asMap().entries.map((entry) {
          final index = entry.key;
          final action = entry.value;
          final color = action.color ?? theme.colorScheme.onSurface;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (index > 0)
                Divider(
                  height: 0.5,
                  thickness: 0.5,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.4,
                  ),
                ),
              InkWell(
                onTap: () {
                  Navigator.of(context).pop();
                  action.onTap();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(action.icon, size: 20, color: color),
                      const SizedBox(width: 12),
                      Text(
                        action.label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  /// 分类色标:与话题卡片(CategoryTagsLine)同款 8px 圆角方形色块,
  /// 颜色经 ColorUtils.readableOn 按主题亮度适配
  Widget _buildCategoryDot(BuildContext context, Category category) {
    final theme = Theme.of(context);
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: ColorUtils.readableOn(
          _parseColor(category.color),
          theme.brightness,
        ),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Color _parseColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) {
      return Color(int.parse('0xFF$hex'));
    }
    return Colors.grey;
  }
}
