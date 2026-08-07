import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../models/category.dart';
import '../../models/search_result.dart';
import '../../models/topic.dart';
import '../../models/topic_card_style.dart';
import '../../utils/color_utils.dart';
import '../../utils/number_utils.dart';
import '../../utils/relative_time_clock.dart';
import '../../utils/time_utils.dart';

/// 话题自绘卡的排版产物:一张卡全部文本的 [ui.Paragraph] 成品 + 几何。
///
/// ## 为什么存在(与 widget 卡的本质区别)
///
/// widget 版话题卡挂载 = 新建百级组件树 + ~10 个文本块各自创建段落并
/// 排版,单卡 7~13ms;快滚双卡同帧必超 8.3ms 预算 —— 边角优化砍尽后,
/// 剩余成本就是"每次挂载重建对象机器"这个结构本身。
///
/// 本类把一张卡的**所有**排版与几何在首次进屏时一次算死,挂载帧只剩
/// "把成品画上去"(单卡 1~2ms)。这是 RecyclerView"cell 复用 + bind"
/// 的 Flutter 等价物:复用的不是视图,是排版结果。
///
/// ## 三种形态
///
/// - 普通话题卡([obtain]):标题(含状态图标/emoji)+ 摘要 + 头像行,
///   书签色带可选 —— 首页/书签/历史/个人页共用
/// - 私信卡([obtain] `messageStyle: true`):Gmail 式,发件人置顶,
///   主题次行
/// - 搜索卡([obtainSearch]):标题/摘要带高亮段,右上 AI 标记与楼层
///   徽章
///
/// ## 缓存与失效
///
/// 全局 LRU(上限 [cacheCap]):键 = 调用方身份串;版本戳含数据实例
/// 恒等/宽度/主题/统计可用宽等 —— 任一变化即重排。已知行为差异:
/// 相对时间是排版期快照,不随分钟自刷(widget 版每卡挂 Timer 自刷,
/// 正是要消灭的常驻成本;列表刷新/数据换代即更新)。
class TopicCardLayout {
  TopicCardLayout._(this.key);

  final String key;

  // ── 排版成品(挂载帧直接 canvas.drawParagraph)─────────────────
  ui.Paragraph? band; // 色带行(书签名/提醒),null = 无色带
  ui.Paragraph? title; // 标题(普通卡)/ 主题行(私信卡)
  ui.Paragraph? excerpt; // 摘要/blurb,null = 无
  ui.Paragraph? author; // 署名(普通)/ 发件人(私信)
  ui.Paragraph? time; // 相对时间(单行)
  ui.Paragraph? catTags; // 分类名+标签行,null = 无
  ui.Paragraph? stats; // 统计簇文本(图标另列)

  /// 标题内嵌 emoji:占位矩形(相对标题段落原点)+ 图片 URL
  final List<(Rect, String)> titleEmojis = [];

  /// 段落内嵌图标(placeholder 行中线对齐,与 WidgetSpan(Icon) 同构;
  /// 直排字形会坐在基线上偏高):占位矩形 + 单字形小段落
  final List<(Rect, ui.Paragraph)> titleIcons = [];
  final List<(Rect, ui.Paragraph)> bandIcons = [];
  final List<(Rect, ui.Paragraph)> statsIcons = [];

  /// 通用装饰通道:圆角填充(徽章底/楼层 chip 底)与绝对定位小段落
  /// (徽章数字/AI 图标),渲染层顺序遍历直画
  final List<(RRect, Color)> extraFills = [];
  final List<(Offset, ui.Paragraph)> extraTexts = [];

  // ── 几何 ────────────────────────────────────────────────────
  double bandHeight = 0;
  double cardHeight = 0; // 含底部 8px 卡间距
  Rect avatarRect = Rect.zero;
  Offset titleOffset = Offset.zero;
  Offset excerptOffset = Offset.zero;
  Offset authorOffset = Offset.zero;
  Offset timeOffset = Offset.zero;
  Offset catTagsOffset = Offset.zero;
  Offset statsOffset = Offset.zero;
  Offset bandTextOffset = Offset.zero;

  Color? categoryDotColor;
  Rect categoryDotRect = Rect.zero;

  Color bandColor = Colors.transparent;
  Color cardColor = Colors.transparent;
  String? avatarUrl;

  /// 动画头像原件 URL(gif 全文件),仅动态头像开关开启且用户有动图时
  /// 非空。画布不消费它 —— 由 PaintedTopicCard 挂播放 overlay;
  /// [avatarUrl] 恒为静态模板小图,保证首帧秒出
  String? animatedAvatarUrl;

  /// 无障碍标签(自绘卡不产生语义子树,整卡一条)
  String semanticsLabel = '';

  Object? _stamp;

  /// 当前排版宽;-1 = 未排。宽度不进 stamp:调用方 build 期只能拿到
  /// 视口估算宽(桌面双栏/分屏下与列表格子的真实宽不同,估错 = 右对
  /// 齐元素画出卡外、标题错误折行),真实宽由渲染对象在布局期经
  /// [ensureWidth] 提供,排版自我纠正并按宽缓存,后续帧零成本。
  double layoutWidth = -1;
  void Function(double width)? _doLayout;

  /// 原地重排代数:每次 [refreshTime] 原地重排 +1。渲染对象据此感知
  /// "同一 layout 实例内容变了"(identical 判不出),触发重布局。
  int revision = 0;

  /// 布局期宽度纠正:与当前排版宽差 >0.5px 才重排(重排 ≈1.5~2.5ms,
  /// 只发生在首次拿到真实宽/窗口改宽的那一帧)。
  void ensureWidth(double width) {
    final relayout = _doLayout;
    if (relayout == null) return;
    if ((width - layoutWidth).abs() <= 0.5) return;
    relayout(width);
  }

  /// 分钟心跳的在屏原地刷新:重跑排版闭包(闭包体内重新求值
  /// formatRelativeTime,时间串随之更新)。仅由在屏卡的心跳订阅调用
  /// —— 离屏缓存不动,靠 stamp 里的分钟代在下次 obtain 时惰性换新。
  void refreshTime() {
    final relayout = _doLayout;
    if (relayout == null || layoutWidth <= 0) return;
    relayout(layoutWidth);
    revision++;
  }

  static final Map<String, TopicCardLayout> _cache = {};
  static const int cacheCap = 500;

  /// 全量排版累计次数(含宽度纠偏重排):预热层用前后差值区分
  /// 命中(O(1) 免费)与 miss(真付了排版成本),按 miss 计预算;
  /// 也可作性能诊断口径(挂载帧该值增长 = 预热漏了)。
  static int layoutBuildCount = 0;

  /// 相对时间的分钟代:全局心跳每跳一次 +1,进 stamp —— 含时间的
  /// 排版跨分钟自动失效,下次 build 惰性重排(消灭"自绘卡时间是
  /// 排版快照不自刷"与 widget 路径的行为差异)。渲染对象侧由
  /// PaintedTopicCard 订阅心跳触发 rebuild,失效与重建同源同帧。
  static int _minuteEpoch = 0;
  static bool _clockHooked = false;

  static int _currentMinuteEpoch() {
    if (!_clockHooked) {
      _clockHooked = true;
      RelativeTimeClock.instance.addListener(() => _minuteEpoch++);
    }
    return _minuteEpoch;
  }

  /// 存入缓存(替换旧实例)并按需 LRU。**内容变化必产出新实例**:
  /// PaintedTopicCard 的渲染对象用 identical 判断是否重绘,若复用同一
  /// 实例做原地重排,identical 恒 true → 已读等状态更新画不出来
  /// (需滑出销毁再滑回新建才生效)。让实例 identity == 内容 identity,
  /// 命中缓存=真没变(同实例,不重绘),stamp 变=新实例(重绘)。
  static void _put(String identity, TopicCardLayout layout) {
    if (!_cache.containsKey(identity) && _cache.length >= cacheCap) {
      // 简易 LRU:满了清一半(重排成本低,不值得维护链表)
      final keys = _cache.keys.take(_cache.length ~/ 2).toList();
      for (final k in keys) {
        _cache.remove(k);
      }
    }
    _cache[identity] = layout;
  }

  /// 环境级失效(主题/字号变化时可由页面调用;逐卡 stamp 也会兜住)
  static void evictAll() => _cache.clear();

  /// 话题卡(普通 / 私信):取/建排版。命中 O(1);miss 全量排版
  /// ≈1.5~2.5ms,只发生在数据首达或环境变化后首次进屏。
  static TopicCardLayout obtain({
    required String identity,
    required Topic topic,
    required double width, // 卡总宽(含 12px 内边距,不含页边距)
    required ThemeData theme,
    required Category? category,
    required String Function(String name) emojiUrlOf,
    double statsAvailableWidth = 460,
    bool messageStyle = false,
    String? excerptText,
    String? bandName,
    String? bandReminder,
    bool bandExpired = false,
    TopicCardStyle? style,
  }) {
    // 私信卡不受话题卡自定义样式影响:强制回默认。列表调用方不传
    // style 时直读全局快照(预览页显式传草稿值)
    final effStyle = messageStyle
        ? TopicCardStyle.defaults
        : (style ?? TopicCardStyleScope.current);
    final stamp = (
      identityHashCode(topic),
      identityHashCode(theme),
      statsAvailableWidth,
      messageStyle,
      bandExpired,
      identityHashCode(category),
      _currentMinuteEpoch(),
      effStyle, // 值语义 ==:改样式设置即重排
    );
    final cached = _cache[identity];
    if (cached != null && cached._stamp == stamp) return cached;
    final layout = TopicCardLayout._(identity).._stamp = stamp;
    _put(identity, layout);

    final scheme = theme.colorScheme;
    final isUnread = topic.unseen || topic.unread > 0;
    final isFullyRead =
        !topic.unseen && topic.unread == 0 && topic.lastReadPostNumber != null;
    final authorName = topic.posters.isNotEmpty
        ? (topic.posters.first.user?.displayName ?? '')
        : (topic.lastPosterUsername ?? '');

    final titleSegments = [( topic.title, false)];
    final titleIconSpecs = <(IconData, Color)>[
      if (topic.closed)
        (
          Symbols.lock_rounded,
          isFullyRead
              ? scheme.onSurfaceVariant.withValues(alpha: 0.75)
              : scheme.onSurface,
        ),
      if (topic.hasAcceptedAnswer)
        (
          Symbols.check_box_rounded,
          isFullyRead ? Colors.green.withValues(alpha: 0.5) : Colors.green,
        )
      else if (topic.canHaveAnswer)
        (Symbols.check_box_outline_blank_rounded, scheme.outline),
    ];

    layout._doLayout = (w) => layout._layoutCore(
      width: w,
      theme: theme,
      messageStyle: messageStyle,
      titleSegments: titleSegments,
      titleIconSpecs: titleIconSpecs,
      parseTitleEmoji: true,
      emojiUrlOf: emojiUrlOf,
      isUnread: isUnread,
      isFullyRead: isFullyRead,
      unreadCount: topic.unread,
      unseen: topic.unseen,
      authorName: authorName,
      authorBold: !isFullyRead,
      timeStr: TimeUtils.formatRelativeTime(topic.lastPostedAt),
      timeHighlight: isUnread,
      excerptText: excerptText,
      category: category,
      tags: topic.tags,
      statsAvailableWidth: statsAvailableWidth,
      views: topic.views,
      likeCount: topic.likeCount,
      replies: (topic.postsCount - 1).clamp(0, 999999),
      heatColor: _replyHeatColor(topic),
      bandName: bandName,
      bandReminder: bandReminder,
      bandExpired: bandExpired,
      // 画布首帧恒用静态模板小图(几 KB 秒出);gif 原件(几百 KB~MB)
      // 只在开关开启时单独带出,供播放 overlay 消费 —— 把原件喂进
      // 静态首帧管线会整卡等一次大文件下载("动图用户头像加载慢")
      avatarUrlValue: topic.posters.isNotEmpty
          ? topic.posters.first.user?.getAvatarUrl(size: 128)
          : null,
      animatedAvatarUrlValue:
          effStyle.animatedAvatar && topic.posters.isNotEmpty
          ? topic.posters.first.user?.animatedAvatarUrl
          : null,
      titleRightChips: const [],
      style: effStyle,
    );
    layout._doLayout!(width);
    return layout;
  }

  /// 搜索结果卡:标题/摘要带高亮段,右上 AI 标记与 #楼层 徽章。
  static TopicCardLayout obtainSearch({
    required String identity,
    required SearchPost post,
    required double width,
    required ThemeData theme,
    required Category? category,
    double statsAvailableWidth = 460,
  }) {
    final stamp = (
      identityHashCode(post),
      identityHashCode(theme),
      statsAvailableWidth,
      identityHashCode(category),
      _currentMinuteEpoch(),
    );
    final cached = _cache[identity];
    if (cached != null && cached._stamp == stamp) return cached;
    final layout = TopicCardLayout._(identity).._stamp = stamp;
    _put(identity, layout);

    final scheme = theme.colorScheme;
    final topic = post.topic;

    // 标题分段:有 headline 用高亮解析,否则原题
    final titleSegments = topic == null
        ? [('', false)]
        : (post.topicTitleHeadline != null &&
                post.topicTitleHeadline!.isNotEmpty
            ? _parseHighlight(post.topicTitleHeadline!)
            : [(topic.title, false)]);

    layout._doLayout = (w) => layout._layoutCore(
      width: w,
      theme: theme,
      messageStyle: false,
      titleSegments: titleSegments,
      titleIconSpecs: [
        if (topic?.closed == true)
          (Symbols.lock_rounded, scheme.onSurfaceVariant),
        if (topic?.archived == true)
          (Symbols.archive_rounded, scheme.onSurfaceVariant),
      ],
      parseTitleEmoji: false, // widget 版搜索卡不解析标题 emoji,对齐
      emojiUrlOf: (_) => '',
      isUnread: false,
      isFullyRead: false,
      unreadCount: 0,
      unseen: false,
      authorName: post.username,
      authorBold: true,
      timeStr: TimeUtils.formatRelativeTime(post.createdAt),
      timeHighlight: false,
      excerptText: null,
      excerptSegments:
          post.blurb.isNotEmpty ? _parseHighlight(post.blurb) : null,
      category: category,
      tags: topic?.tags ?? const [],
      statsAvailableWidth: statsAvailableWidth,
      views: topic?.views ?? 0,
      likeCount: post.likeCount,
      replies:
          topic != null ? (topic.postsCount - 1).clamp(0, 999999) : 0,
      heatColor: null,
      bandName: null,
      bandReminder: null,
      bandExpired: false,
      avatarUrlValue:
          post.getAvatarUrl().isNotEmpty ? post.getAvatarUrl(size: 64) : null,
      titleRightChips: [
        if (post.isAiGenerated) (_ChipKind.aiIcon, ''),
        if (post.postNumber > 1) (_ChipKind.badge, '#${post.postNumber}'),
      ],
      style: TopicCardStyle.defaults, // 搜索卡不受话题卡样式影响
    );
    layout._doLayout!(width);
    return layout;
  }

  // ─────────────────────────────────────────────────────────────

  static ui.ParagraphStyle _pStyle({
    required double fontSize,
    FontWeight? weight,
    double? height,
    int maxLines = 1,
  }) {
    return ui.ParagraphStyle(
      maxLines: maxLines,
      ellipsis: '…',
      fontSize: fontSize,
      fontWeight: weight,
      height: height,
    );
  }

  static ui.TextStyle _tStyle(
    TextStyle base, {
    Color? color,
    double? fontSize,
    FontWeight? weight,
    double? height,
    Color? background,
  }) {
    return ui.TextStyle(
      color: color ?? base.color,
      fontSize: fontSize ?? base.fontSize,
      fontWeight: weight ?? base.fontWeight,
      fontFamily: base.fontFamily,
      fontFamilyFallback: base.fontFamilyFallback,
      height: height,
      background: background == null ? null : (Paint()..color = background),
    );
  }

  /// 图标字体的真实注册名:widget 层 TextStyle(package:) 会把字体名
  /// 拼成 `packages/<pkg>/<family>`,dart:ui 的 TextStyle 没有 package
  /// 参数,必须手动拼 —— 裸 family 引擎查不到,画出来是豆腐块
  static String _iconFontFamily(IconData icon) {
    final pkg = icon.fontPackage;
    return pkg == null ? icon.fontFamily! : 'packages/$pkg/${icon.fontFamily}';
  }

  /// 单字形图标小段落(排版期构建一次,绘制期直接画)
  static ui.Paragraph _iconParagraph(IconData icon, double size, Color color) {
    final b = ui.ParagraphBuilder(_pStyle(fontSize: size, maxLines: 1))
      ..pushStyle(ui.TextStyle(
        color: color,
        fontFamily: _iconFontFamily(icon),
        fontVariations: const [
          ui.FontVariation('opsz', 24),
          ui.FontVariation('wght', 400),
        ],
        fontSize: size,
        height: 1.0,
      ))
      ..addText(String.fromCharCode(icon.codePoint));
    return b.build()..layout(ui.ParagraphConstraints(width: size + 2));
  }

  /// `<span class="search-highlight">` 高亮解析 → (文本, 是否高亮) 段
  static List<(String, bool)> _parseHighlight(String html) {
    final regex = RegExp(r'<span class="search-highlight">(.*?)</span>');
    final matches = regex.allMatches(html).toList();
    String clean(String s) => s.replaceAll(RegExp(r'<[^>]*>'), '');
    if (matches.isEmpty) return [(clean(html), false)];
    final out = <(String, bool)>[];
    var last = 0;
    for (final m in matches) {
      if (m.start > last) out.add((clean(html.substring(last, m.start)), false));
      out.add((m.group(1) ?? '', true));
      last = m.end;
    }
    if (last < html.length) out.add((clean(html.substring(last)), false));
    return out;
  }

  // ── 核心排版(三形态共用)──────────────────────────────────────

  void _layoutCore({
    required double width,
    required ThemeData theme,
    required bool messageStyle,
    required List<(String, bool)> titleSegments,
    required List<(IconData, Color)> titleIconSpecs,
    required bool parseTitleEmoji,
    required String Function(String name) emojiUrlOf,
    required bool isUnread,
    required bool isFullyRead,
    required int unreadCount,
    required bool unseen,
    required String authorName,
    required bool authorBold,
    required String timeStr,
    required bool timeHighlight,
    required String? excerptText,
    List<(String, bool)>? excerptSegments,
    required Category? category,
    required List<Tag> tags,
    required double statsAvailableWidth,
    required int views,
    required int likeCount,
    required int replies,
    required Color? heatColor,
    required String? bandName,
    required String? bandReminder,
    required bool bandExpired,
    required String? avatarUrlValue,
    String? animatedAvatarUrlValue,
    required List<(_ChipKind, String)> titleRightChips,
    required TopicCardStyle style,
  }) {
    layoutBuildCount++;
    final scheme = theme.colorScheme;
    final baseText = theme.textTheme.bodyMedium ?? const TextStyle();
    final labelSmall = theme.textTheme.labelSmall ?? const TextStyle();
    const hPad = 12.0;
    final innerWidth = width - hPad * 2;
    layoutWidth = width;

    // 头像布局:inline = 头像在元信息行内(32);column = 头像独占
    // 左列(40,与私信卡一致),标题/摘要/元信息统一从 contentX 起排
    final avatarCol =
        !messageStyle && style.avatarLayout == TopicCardAvatarLayout.column;
    const colAvatarD = 40.0;
    final contentX = avatarCol ? hPad + colAvatarD + 10 : hPad;
    final contentW = avatarCol ? innerWidth - colAvatarD - 10 : innerWidth;

    cardColor = theme.cardTheme.color ?? scheme.surface;
    extraFills.clear();
    extraTexts.clear();
    titleIcons.clear();
    titleEmojis.clear();
    bandIcons.clear();
    statsIcons.clear();

    final metaColor =
        scheme.onSurfaceVariant.withValues(alpha: isFullyRead ? 0.6 : 0.8);

    // ── 色带 ────────────────────────────────────────────────
    band = null;
    bandHeight = 0;
    if (bandName != null || bandReminder != null) {
      bandColor = bandExpired
          ? scheme.errorContainer.withValues(alpha: 0.5)
          : scheme.secondaryContainer.withValues(alpha: 0.6);
      final fg = bandExpired ? scheme.error : scheme.onSecondaryContainer;
      final b = ui.ParagraphBuilder(
        _pStyle(fontSize: 12, height: 1.3, maxLines: 1),
      )..pushStyle(_tStyle(baseText, color: fg, fontSize: 12, height: 1.3));
      final pendingIcons = <ui.Paragraph>[];
      void bandIcon(IconData icon) {
        b.addPlaceholder(13, 13, ui.PlaceholderAlignment.middle);
        pendingIcons.add(_iconParagraph(icon, 13, fg));
      }

      if (bandName != null) {
        bandIcon(Symbols.bookmark_rounded);
        b.addText(' $bandName');
      }
      if (bandReminder != null) {
        if (bandName != null) {
          b.pushStyle(ui.TextStyle(color: fg.withValues(alpha: 0.4)));
          b.addText('  ·  ');
          b.pop();
        }
        bandIcon(Symbols.alarm_rounded);
        b.addText(bandReminder);
      }
      band = b.build()..layout(ui.ParagraphConstraints(width: innerWidth));
      final iconBoxes = band!.getBoxesForPlaceholders();
      for (var i = 0; i < iconBoxes.length && i < pendingIcons.length; i++) {
        bandIcons.add((iconBoxes[i].toRect(), pendingIcons[i]));
      }
      bandHeight = band!.height + 10; // vertical 5×2
      bandTextOffset = Offset(hPad, 5);
    }

    // ── 未读槽位(徽章/蓝点)先测量,标题/发件人行给它留宽 ────────
    ui.Paragraph? unreadBadgeP;
    var unreadW = 0.0;
    if (unreadCount > 0) {
      final b = ui.ParagraphBuilder(
        _pStyle(fontSize: labelSmall.fontSize ?? 11, maxLines: 1),
      )
        ..pushStyle(_tStyle(
          labelSmall,
          color: scheme.onPrimary,
          weight: FontWeight.w500,
        ))
        ..addText('$unreadCount');
      unreadBadgeP = b.build()
        ..layout(const ui.ParagraphConstraints(width: 100));
      unreadW = unreadBadgeP.longestLine + 12 + 6; // 徽章体 + 间距 6
    } else if (unseen) {
      unreadW = 8 + 6;
    }

    // ── 统计簇(catTags 行右侧;先排才知道 catTags 可用宽)────────
    // 私信卡无统计簇:必须显式置空 —— statsOffset 只在普通卡分支
    // 赋值,私信分支不碰它;若 stats 非 null 会以默认 Offset.zero
    // 画在卡片左上角(自绘化时漏守卫的潜伏 bug)
    if (messageStyle) {
      stats = null;
    } else {
      _layoutStats(
        theme,
        statsAvailableWidth,
        isFullyRead,
        views: views,
        likeCount: likeCount,
        replies: replies,
        heatColor: heatColor,
        style: style,
      );
    }

    // ── 标题右侧 chips(搜索卡:AI 图标 / #楼层)────────────────
    var titleRightW = 0.0;
    final chipItems = <(_ChipKind, ui.Paragraph?)>[];
    for (final (kind, text) in titleRightChips) {
      if (kind == _ChipKind.aiIcon) {
        chipItems.add((kind, null));
        titleRightW += 14 + 6;
      } else {
        final b = ui.ParagraphBuilder(_pStyle(fontSize: 10, maxLines: 1))
          ..pushStyle(_tStyle(
            labelSmall,
            color: scheme.onSurfaceVariant,
            fontSize: 10,
            weight: FontWeight.w500,
          ))
          ..addText(text);
        final p = b.build()..layout(const ui.ParagraphConstraints(width: 120));
        chipItems.add((kind, p));
        titleRightW += p.longestLine + 12 + 4;
      }
    }

    // ── 标题 / 私信主题行 ─────────────────────────────────────
    final titleColor = isFullyRead
        ? scheme.onSurfaceVariant.withValues(alpha: 0.75)
        : scheme.onSurface;
    final normalTitleWeight = isFullyRead ? FontWeight.w500 : FontWeight.w600;
    // 私信主题行:小一档、w400/500、0.9 透明
    final subjectColor = isFullyRead
        ? scheme.onSurfaceVariant.withValues(alpha: 0.75)
        : scheme.onSurface.withValues(alpha: 0.9);
    final titleFontSize =
        messageStyle ? (baseText.fontSize ?? 14) : style.titleFontSize;
    final titleWeight = messageStyle
        ? (isFullyRead ? FontWeight.w400 : FontWeight.w500)
        : normalTitleWeight;
    final effTitleColor = messageStyle ? subjectColor : titleColor;

    final tb = ui.ParagraphBuilder(
      _pStyle(
        fontSize: titleFontSize,
        weight: titleWeight,
        height: 1.3,
        maxLines: 2,
      ),
    )..pushStyle(_tStyle(
        baseText,
        color: effTitleColor,
        fontSize: titleFontSize,
        weight: titleWeight,
        height: 1.3,
      ));
    final pendingTitleIcons = <ui.Paragraph>[];
    for (final (icon, color) in titleIconSpecs) {
      // 15px 图标 + 4px 右距(placeholder 宽 19 复刻 Padding(right:4))
      tb.addPlaceholder(19, 15, ui.PlaceholderAlignment.middle);
      pendingTitleIcons.add(_iconParagraph(icon, 15, color));
    }
    final emojiNames = <String>[];
    for (final (text, highlighted) in titleSegments) {
      if (highlighted) {
        tb.pushStyle(_tStyle(
          baseText,
          color: scheme.onPrimaryContainer,
          fontSize: titleFontSize,
          weight: FontWeight.w500,
          height: 1.3,
          background: scheme.primaryContainer,
        ));
        tb.addText(text);
        tb.pop();
      } else if (parseTitleEmoji && text.contains(':')) {
        emojiNames.addAll(_addTextWithEmoji(tb, text, titleFontSize));
      } else {
        tb.addText(text);
      }
    }
    // 普通卡标题右侧要让出未读槽位宽;私信卡主题行满宽
    final titleAvailW = messageStyle
        ? innerWidth - 50 // 头像 40 + 间距 10
        : contentW - (unreadW > 0 ? unreadW : 0) - titleRightW;
    title = tb.build()
      ..layout(ui.ParagraphConstraints(width: titleAvailW.clamp(40, width)));
    final phBoxes = title!.getBoxesForPlaceholders();
    for (var i = 0; i < phBoxes.length; i++) {
      final rect = phBoxes[i].toRect();
      if (i < pendingTitleIcons.length) {
        titleIcons.add((rect, pendingTitleIcons[i]));
      } else {
        final emojiIdx = i - pendingTitleIcons.length;
        if (emojiIdx < emojiNames.length) {
          titleEmojis.add((rect, emojiUrlOf(emojiNames[emojiIdx])));
        }
      }
    }

    // ── 摘要 / blurb ─────────────────────────────────────────
    excerpt = null;
    final exSegments = excerptSegments ??
        (excerptText != null && excerptText.isNotEmpty
            ? [(excerptText, false)]
            : null);
    if (exSegments != null) {
      final ex = ui.ParagraphBuilder(
        _pStyle(fontSize: 12, height: 1.4, maxLines: 2),
      )..pushStyle(_tStyle(
          baseText,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          fontSize: 12,
          height: 1.4,
        ));
      for (final (text, highlighted) in exSegments) {
        if (highlighted) {
          ex.pushStyle(_tStyle(
            baseText,
            color: scheme.onPrimaryContainer,
            fontSize: 12,
            weight: FontWeight.w500,
            height: 1.4,
            background: scheme.primaryContainer,
          ));
          ex.addText(text);
          ex.pop();
        } else {
          ex.addText(text);
        }
      }
      final exW = messageStyle ? innerWidth - 50 : contentW;
      excerpt = ex.build()..layout(ui.ParagraphConstraints(width: exW));
    }

    // ── 署名(普通)/ 发件人(私信)与时间 ─────────────────────
    final authorFontSize =
        messageStyle ? 15.0 : (labelSmall.fontSize ?? 11);
    final authorWeight = messageStyle
        ? (isFullyRead ? FontWeight.w400 : FontWeight.w600)
        : (authorBold ? FontWeight.w600 : null);
    final authorColor = messageStyle
        ? (isFullyRead
            ? scheme.onSurfaceVariant.withValues(alpha: 0.75)
            : scheme.onSurface)
        : (isFullyRead
            ? metaColor
            : scheme.onSurface.withValues(alpha: 0.85));
    final tmb = ui.ParagraphBuilder(
      _pStyle(fontSize: labelSmall.fontSize ?? 11, maxLines: 1),
    )
      ..pushStyle(_tStyle(
        labelSmall,
        color: timeHighlight ? scheme.primary : metaColor,
      ))
      ..addText(timeStr);
    // 时间是卡片骨架字段,恒定显示
    time = tmb.build()..layout(const ui.ParagraphConstraints(width: 200));

    final ab = ui.ParagraphBuilder(
      _pStyle(
        fontSize: authorFontSize,
        weight: authorWeight,
        maxLines: 1,
      ),
    )
      ..pushStyle(_tStyle(
        messageStyle ? baseText : labelSmall,
        color: authorColor,
        fontSize: authorFontSize,
        weight: authorWeight,
      ))
      ..addText(authorName);

    // ── 分类 + 标签行(私信卡无此行;字段开关各自过滤)──────────
    catTags = null;
    categoryDotColor = null;
    final effCategory = category; // 分类是骨架字段,恒定显示
    final effTags = style.showTags ? tags : const <Tag>[];
    if (!messageStyle && (effCategory != null || effTags.isNotEmpty)) {
      final dimF = isFullyRead ? 0.55 : 1.0;
      final lineColor = metaColor.withValues(alpha: metaColor.a * dimF);
      final b = ui.ParagraphBuilder(
        _pStyle(fontSize: labelSmall.fontSize ?? 11, maxLines: 1),
      )..pushStyle(_tStyle(labelSmall, color: lineColor));
      var first = true;
      if (effCategory != null) {
        b.pushStyle(ui.TextStyle(fontWeight: FontWeight.w500));
        b.addText(effCategory.name);
        b.pop();
        first = false;
        var dot = ColorUtils.readableOn(
          _parseCategoryColor(effCategory.color),
          theme.brightness,
        );
        categoryDotColor = dot.withValues(alpha: dot.a * dimF);
      }
      for (final tag in effTags) {
        if (!first) b.addText('   ');
        first = false;
        b.pushStyle(
          ui.TextStyle(color: metaColor.withValues(alpha: 0.6 * dimF)),
        );
        b.addText('#');
        b.pop();
        b.addText(tag.name);
      }
      catTags = b.build();
    }

    // ── 纵向装配 ─────────────────────────────────────────────
    const vPad = 10.0;
    var y = bandHeight + vPad;

    if (messageStyle) {
      // Gmail 式:头像 40 跨两行,右侧 发件人行 + 主题行
      const avatarD = 40.0;
      final rightX = hPad + avatarD + 10;
      final rightW = innerWidth - avatarD - 10;
      // 发件人行:发件人 … 时间 + 未读
      author = ab.build()
        ..layout(ui.ParagraphConstraints(
          width: (rightW - time!.longestLine - 8 - unreadW).clamp(20, rightW),
        ));
      final row1H = author!.height;
      authorOffset = Offset(rightX, y);
      var rx = width - hPad;
      if (unreadW > 0) {
        rx = _placeUnread(
          unreadBadgeP,
          unseen,
          scheme,
          rx,
          y + (row1H - (unreadBadgeP != null ? unreadBadgeP.height + 4 : 8)) / 2,
        );
        rx -= 6;
      }
      timeOffset = Offset(
        rx - time!.longestLine,
        y + (row1H - time!.height) / 2,
      );
      y += row1H + 2;
      titleOffset = Offset(rightX, y);
      y += title!.height;
      if (excerpt != null) {
        y += 2;
        excerptOffset = Offset(rightX, y);
        y += excerpt!.height;
      }
      final contentH = y - (bandHeight + vPad);
      final rowH = contentH > avatarD ? contentH : avatarD;
      avatarRect = Rect.fromLTWH(
        hPad,
        bandHeight + vPad + (rowH - avatarD) / 2,
        avatarD,
        avatarD,
      );
      cardHeight = bandHeight + vPad + rowH + vPad + 8;
    } else {
      // 普通卡:标题(+右侧未读/chips)→ 摘要 → 元信息行
      titleOffset = Offset(contentX, y);
      // 未读槽位钉标题行右上
      final rx = width - hPad;
      if (unreadW > 0) {
        _placeUnread(
          unreadBadgeP,
          unseen,
          scheme,
          rx,
          unreadCount > 0 ? y : y + 5,
        );
      }
      // 搜索卡右上 chips(AI 图标 / #楼层)
      var chipX = width - hPad;
      for (var i = chipItems.length - 1; i >= 0; i--) {
        final (kind, p) = chipItems[i];
        if (kind == _ChipKind.aiIcon) {
          chipX -= 14;
          extraTexts.add((
            Offset(chipX, y + 2),
            _iconParagraph(Symbols.auto_awesome_rounded, 14, scheme.tertiary),
          ));
          chipX -= 6;
        } else if (p != null) {
          final w = p.longestLine + 12;
          final h = p.height + 4;
          chipX -= w;
          extraFills.add((
            RRect.fromRectAndRadius(
              Rect.fromLTWH(chipX, y + 1, w, h),
              const Radius.circular(10),
            ),
            scheme.surfaceContainerHighest,
          ));
          extraTexts.add((Offset(chipX + 6, y + 3), p));
          chipX -= 4;
        }
      }
      y += title!.height;
      if (excerpt != null) {
        y += 4;
        excerptOffset = Offset(contentX, y);
        y += excerpt!.height;
      }
      // 元信息行:inline = 头像 32 在行内;column = 头像已独占左列,
      // 元信息不再让头像占位。
      // 动态布局:author 与 catTags 同为左侧信息块,双双在场才分两行
      // (署名+时间 / 分类标签+统计);任一缺席(字段开关或数据缺失)
      // 则剩余字段合并单行 [左块 … 统计 时间],行随内容收缩
      const avatarD = 32.0;
      final rightX = avatarCol ? contentX : hPad + avatarD + 8;
      final metaWidth = avatarCol ? contentW : innerWidth - avatarD - 8;
      author = (style.showAuthor && authorName.isNotEmpty) ? ab.build() : null;
      final twoRows = author != null && catTags != null;
      final timeW = time == null ? 0.0 : time!.longestLine + 8;
      final statsW = stats == null ? 0.0 : stats!.longestLine + 8;
      final dotSpace = categoryDotColor != null ? 12.0 : 0.0;
      final double firstH;
      final double secondH;
      if (twoRows) {
        author!.layout(ui.ParagraphConstraints(
          width: (metaWidth - timeW).clamp(20, metaWidth),
        ));
        catTags!.layout(ui.ParagraphConstraints(
          width: (metaWidth - dotSpace - statsW).clamp(20, metaWidth),
        ));
        firstH = author!.height;
        secondH = catTags!.height;
      } else {
        // 单行:右侧簇 [统计 10 时间],整簇与左块间留 8
        var rightReserve =
            (stats?.longestLine ?? 0.0) + (time?.longestLine ?? 0.0);
        if (stats != null && time != null) rightReserve += 10;
        if (rightReserve > 0) rightReserve += 8;
        final leftPara = author ?? catTags;
        leftPara?.layout(ui.ParagraphConstraints(
          width: (metaWidth - dotSpace - rightReserve).clamp(20, metaWidth),
        ));
        firstH = leftPara?.height ?? time?.height ?? stats?.height ?? 0.0;
        secondH = 0.0;
      }
      final rightBlockH =
          firstH + (firstH > 0 && secondH > 0 ? 2 : 0.0) + secondH;
      final hasMetaRow = avatarCol ? rightBlockH > 0 : true;
      if (hasMetaRow) y += 8;
      final double rowTop;
      if (avatarCol) {
        // 头像独占左列:顶对齐标题首行(复刻私信卡观感)
        avatarRect =
            Rect.fromLTWH(hPad, bandHeight + vPad, colAvatarD, colAvatarD);
        rowTop = y;
        y += rightBlockH;
      } else {
        final rowH = rightBlockH > avatarD ? rightBlockH : avatarD;
        avatarRect =
            Rect.fromLTWH(hPad, y + (rowH - avatarD) / 2, avatarD, avatarD);
        rowTop = y + (rowH - rightBlockH) / 2;
        y += rowH;
      }
      if (author != null) authorOffset = Offset(rightX, rowTop);
      if (time != null) {
        timeOffset = Offset(
          width - hPad - time!.longestLine,
          rowTop + (firstH - time!.height) / 2,
        );
      }
      if (twoRows) {
        final secondLineY = rowTop + firstH + 2;
        if (categoryDotColor != null) {
          categoryDotRect = Rect.fromLTWH(
            rightX,
            secondLineY + (catTags!.height - 8) / 2,
            8,
            8,
          );
          catTagsOffset = Offset(rightX + 12, secondLineY);
        } else {
          catTagsOffset = Offset(rightX, secondLineY);
        }
        if (stats != null) {
          statsOffset = Offset(
            width - hPad - stats!.longestLine,
            secondLineY + (catTags!.height - stats!.height) / 2,
          );
        }
      } else {
        // 单行:catTags(若为左块)与统计/时间同行
        if (catTags != null) {
          if (categoryDotColor != null) {
            categoryDotRect = Rect.fromLTWH(
              rightX,
              rowTop + (catTags!.height - 8) / 2,
              8,
              8,
            );
            catTagsOffset = Offset(rightX + 12, rowTop);
          } else {
            catTagsOffset = Offset(rightX, rowTop);
          }
        }
        if (stats != null) {
          statsOffset = Offset(
            width -
                hPad -
                (time != null ? time!.longestLine + 10 : 0.0) -
                stats!.longestLine,
            rowTop + (firstH - stats!.height) / 2,
          );
        }
      }
      // column 下卡底以头像底兜底(极端:标题单行 + 字段全关)
      final contentBottom =
          avatarCol && avatarRect.bottom > y ? avatarRect.bottom : y;
      cardHeight = contentBottom + vPad + 8;
    }

    avatarUrl = avatarUrlValue;
    animatedAvatarUrl = animatedAvatarUrlValue;
    semanticsLabel = [
      for (final (t, _) in titleSegments) t,
      if (author != null && authorName.isNotEmpty) authorName,
      if (time != null) timeStr,
    ].join(', ');
  }

  /// 未读徽章/蓝点入通用装饰通道;返回其左缘 x(供同行右侧排布)
  double _placeUnread(
    ui.Paragraph? badge,
    bool unseen,
    ColorScheme scheme,
    double rightX,
    double top,
  ) {
    if (badge != null) {
      final w = badge.longestLine + 12;
      final h = badge.height + 4;
      final r = Rect.fromLTWH(rightX - w, top, w, h);
      extraFills.add((
        RRect.fromRectAndRadius(r, const Radius.circular(10)),
        scheme.primary,
      ));
      extraTexts.add((
        Offset(r.left + 6, r.top + (h - badge.height) / 2),
        badge,
      ));
      return r.left;
    }
    if (unseen) {
      final r = Rect.fromLTWH(rightX - 8, top, 8, 8);
      extraFills.add((
        RRect.fromRectAndRadius(r, const Radius.circular(4)),
        scheme.primary,
      ));
      return r.left;
    }
    return rightX;
  }

  /// 文本写入 builder:`:name:` 段转 emoji 占位;返回按序 emoji 名
  List<String> _addTextWithEmoji(
    ui.ParagraphBuilder b,
    String text,
    double fontSize,
  ) {
    final names = <String>[];
    final re = RegExp(r':([a-z0-9_+\-]+):');
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) b.addText(text.substring(last, m.start));
      names.add(m.group(1)!);
      b.addPlaceholder(
        fontSize + 4,
        fontSize + 4,
        ui.PlaceholderAlignment.middle,
      );
      last = m.end;
    }
    if (last < text.length) b.addText(text.substring(last));
    return names;
  }

  void _layoutStats(
    ThemeData theme,
    double availableWidth,
    bool isFullyRead, {
    required int views,
    required int likeCount,
    required int replies,
    required Color? heatColor,
    required TopicCardStyle style,
  }) {
    stats = null;
    final scheme = theme.colorScheme;
    final labelSmall = theme.textTheme.labelSmall ?? const TextStyle();
    // 字段开关与响应式宽度条件取 AND
    final showLikes =
        style.showLikes && availableWidth >= 300 && likeCount > 0;
    final showViews = style.showViews && availableWidth >= 460 && views > 0;
    final showReplies = style.showReplies && replies > 0;
    if (!showLikes && !showViews && !showReplies) return;

    var base = scheme.onSurfaceVariant.withValues(alpha: 0.75);
    if (isFullyRead) base = base.withValues(alpha: base.a * 0.55);
    var heat = heatColor ?? base;
    if (heatColor != null && isFullyRead) {
      heat = heatColor.withValues(alpha: heatColor.a * 0.55);
    }

    final b = ui.ParagraphBuilder(
      _pStyle(fontSize: labelSmall.fontSize ?? 11, maxLines: 1),
    )..pushStyle(_tStyle(labelSmall, color: base));
    final pendingIcons = <ui.Paragraph>[];
    var first = true;
    void item(IconData icon, int count, Color color, {bool bold = false}) {
      if (!first) b.addText('  '); // ≈10px 组间距
      first = false;
      // 图标经 placeholder 行中线对齐;13 宽 + 3 右距复刻
      // widget 版 Icon(13)+letterSpacing:3
      b.addPlaceholder(16, 13, ui.PlaceholderAlignment.middle);
      pendingIcons.add(_iconParagraph(icon, 13, color));
      b.pushStyle(ui.TextStyle(
        color: color,
        fontWeight: bold ? FontWeight.w600 : null,
      ));
      b.addText(NumberUtils.formatCount(count));
      b.pop();
    }

    if (showViews) item(Symbols.visibility_rounded, views, base);
    if (showLikes) item(Symbols.favorite_border_rounded, likeCount, base);
    if (showReplies) {
      item(Symbols.chat_bubble_rounded, replies, heat,
          bold: heatColor != null);
    }
    stats = b.build()..layout(const ui.ParagraphConstraints(width: 400));
    final iconBoxes = stats!.getBoxesForPlaceholders();
    for (var i = 0; i < iconBoxes.length && i < pendingIcons.length; i++) {
      statsIcons.add((iconBoxes[i].toRect(), pendingIcons[i]));
    }
  }

  static Color? _replyHeatColor(Topic topic) {
    if (topic.postsCount < 10) return null;
    final ratio = topic.likeCount / topic.postsCount;
    if (ratio > 2.0) return const Color(0xFFFE7A15);
    if (ratio > 1.0) return const Color(0xFFCF7721);
    if (ratio > 0.5) return const Color(0xFF9B764F);
    return null;
  }

  static Color _parseCategoryColor(String hex) {
    final clean = hex.replaceAll('#', '');
    if (clean.length == 6) return Color(int.parse('0xFF$clean'));
    return Colors.grey;
  }
}

enum _ChipKind { aiIcon, badge }
