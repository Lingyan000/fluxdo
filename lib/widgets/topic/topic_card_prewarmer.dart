import 'dart:ui' as ui;

import 'package:fluxdo_render/fluxdo_render.dart' show GlyphPrebaker;
import 'package:material_ui/material_ui.dart';

import '../../models/category.dart';
import '../../models/topic.dart';
import '../../models/topic_card_style.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/idle_task.dart';
import '../../utils/scroll_busy_signal.dart';
import 'painted_topic_card.dart';
import 'topic_card_layout.dart';
import 'topic_item_builder.dart';

/// 卡片排版空闲预热(通用内核):RecyclerView GapWorker / Telegram
/// 后台预建 StaticLayout 的 Flutter 对等物。
///
/// 自绘卡把挂载帧成本压到了 1~2ms,但排版 miss(1.5~2.5ms,含摘要的
/// 书签/搜索卡更贵)仍落在首见卡片滚入视口的那一帧 —— 与挂载叠加即
/// 是快滚时的单帧尖峰;头像/emoji 未解码则再叠一层"灰底→补画"闪变
/// (满屏新卡各自迟到补画 = 拖影观感)。本层在数据落地后用空闲时间把
/// 列表排版提前灌进 [TopicCardLayout] 全局缓存,并预解码排版引用的
/// 头像/标题 emoji —— 滚到时 obtain O(1) 命中,首见帧连图同步画。
///
/// 关键约束:**预热取用与挂载取用必须同源**([warmItem] 直接复用
/// itemBuilder 的取排版函数,identity/宽度/theme/statsAvailableWidth
/// 全同口径),任一参数不一致 stamp 对不上就是白热。已热项重扫只付
/// 一次 stamp 比较(O(1)),故 [signature] 换代时直接从头重扫,不维护
/// 游标。
///
/// 空闲礼让语义由 [scheduleIdleTask] 提供(动画/滚动进行中让路,
/// 单步预算 [_budgetMicros]),与详情页段落预热同一套基建。
class CardPrewarmScope<T> extends StatefulWidget {
  const CardPrewarmScope({
    super.key,
    required this.items,
    required this.signature,
    required this.warmItem,
    required this.child,
  });

  /// 待预热的数据列表(与列表页喂给 itemBuilder 的同一份)
  final List<T> items;

  /// 环境签名:任一分量变化(数据换代/深浅色/改宽/改样式)即重扫。
  /// 由调用方在 build 期算好传入 —— 分量应在 build 里读取
  /// (MediaQuery/Theme),使环境变化必然触发调用方 rebuild、签名
  /// 才有机会比对。值语义 ==(record 即可)。
  final Object signature;

  /// 逐项取排版:**必须与 itemBuilder 的取用完全同源**。返回 null =
  /// 本项无排版可热(如置顶卡走 widget 版)。
  final TopicCardLayout? Function(BuildContext context, T item) warmItem;

  final Widget child;

  @override
  State<CardPrewarmScope<T>> createState() => _CardPrewarmScopeState<T>();
}

class _CardPrewarmScopeState<T> extends State<CardPrewarmScope<T>> {
  /// 换代即弃:数据/环境变化重启扫描,老 idle 链自灭
  int _generation = 0;
  IdleTaskHandle? _pendingWarmUp;
  int _warmIndex = 0;
  final Set<BuildContext> _activeScrolls = {};
  final GlyphPrebaker _glyphBaker = GlyphPrebaker(
    shouldDefer: () => isIdleTaskUserInteracting,
  );

  Object? _lastSignature;

  static const int _budgetMicros = 4000;

  /// 预热规模上限:TopicCardLayout 全局 LRU 上限 500(满了清一半),
  /// 多页 load more 后列表可达数百条,不设限的全列表预热会把在屏项
  /// 从缓存里冲掉(不破坏正确性 —— 下次 obtain 重建,但白费预热)。
  /// 300 = 覆盖十几屏的余量,同时给其他列表页留出共享空间。
  static const int _maxWarmCount = 300;

  bool get _isScrolling {
    if (_activeScrolls.isEmpty) return false;
    _activeScrolls.removeWhere((ctx) => !ctx.mounted);
    return _activeScrolls.isNotEmpty;
  }

  int get _warmLimit =>
      widget.items.length < _maxWarmCount ? widget.items.length : _maxWarmCount;

  bool _handleScrollNotification(ScrollNotification notification) {
    ScrollBusySignal.onScrollNotification(notification);
    final ctx = notification.context;
    if (notification is ScrollStartNotification) {
      if (ctx != null) _activeScrolls.add(ctx);
      _pendingWarmUp?.cancel();
      _pendingWarmUp = null;
      _glyphBaker.clear();
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      if (ctx != null) _activeScrolls.add(ctx);
      _pendingWarmUp?.cancel();
      _pendingWarmUp = null;
      _glyphBaker.clear();
    } else if (notification is ScrollEndNotification) {
      if (ctx != null) _activeScrolls.remove(ctx);
      if (!_isScrolling &&
          kUsePaintedTopicCard &&
          _pendingWarmUp == null &&
          _warmIndex < _warmLimit) {
        _scheduleStep(_generation);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (kUsePaintedTopicCard && widget.signature != _lastSignature) {
      _lastSignature = widget.signature;
      _restart();
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: widget.child,
    );
  }

  @override
  void dispose() {
    _generation++;
    _pendingWarmUp?.cancel();
    _pendingWarmUp = null;
    _glyphBaker.dispose();
    _activeScrolls.clear();
    super.dispose();
  }

  void _restart() {
    _pendingWarmUp?.cancel();
    _pendingWarmUp = null;
    _glyphBaker.clear();
    final generation = ++_generation;
    _warmIndex = 0;
    if (widget.items.isEmpty || _isScrolling) return;
    _scheduleStep(generation);
  }

  void _scheduleStep(int generation) {
    bool canceled() => !mounted || generation != _generation || _isScrolling;

    void step() {
      _pendingWarmUp = null;
      if (canceled()) return;
      final items = widget.items;
      final limit = _warmLimit;
      final stopwatch = Stopwatch()..start();
      final baked = <TopicCardLayout>[];
      while (_warmIndex < limit &&
          stopwatch.elapsedMicroseconds < _budgetMicros) {
        final item = items[_warmIndex++];
        final buildsBefore = TopicCardLayout.layoutBuildCount;
        final layout = widget.warmItem(context, item);
        if (layout == null) continue;
        // 命中项 = O(1) 查表,免费;图片也早已在途/在缓存,跳过
        if (TopicCardLayout.layoutBuildCount == buildsBefore) continue;
        baked.add(layout);
        // 排版就绪后顺带预解码头像/标题 emoji:首见帧连图一起同步画,
        // 消掉灰底占位 → markNeedsPaint 补画的闪变
        final avatarUrl = layout.avatarUrl;
        if (avatarUrl != null) {
          TopicCardImages.prewarm(avatarUrl);
        }
        for (final (_, url) in [
          ...layout.titleEmojis,
          ...layout.excerptEmojis,
        ]) {
          TopicCardImages.prewarm(url, bucket: BlobImageCache.emojiBucket);
        }
      }
      _bakeGlyphs(baked);
      if (_warmIndex < limit && !canceled()) {
        _pendingWarmUp = scheduleIdleTask(step, isCanceled: canceled);
      }
    }

    _pendingWarmUp = scheduleIdleTask(step, isCanceled: canceled);
  }

  /// 字形预烤:把本步新排版的段落经 [GlyphPrebaker] 按真实 devicePixelRatio
  /// 离屏光栅化一次（带全局串行背压，滚动开始即清队），让字形提前进入引擎
  /// 全局字形图集（glyph atlas）对应的物理像素缩放桶。
  void _bakeGlyphs(List<TopicCardLayout> layouts) {
    if (layouts.isEmpty || !mounted) return;
    final paragraphs = <ui.Paragraph>[];
    for (final l in layouts) {
      for (final p in [
        l.band,
        l.title,
        l.excerpt,
        l.author,
        l.time,
        l.catTags,
        l.stats,
      ]) {
        if (p != null) paragraphs.add(p);
      }
      for (final (_, p) in l.titleIcons) {
        paragraphs.add(p);
      }
      for (final (_, p) in l.bandIcons) {
        paragraphs.add(p);
      }
      for (final (_, p) in l.statsIcons) {
        paragraphs.add(p);
      }
      for (final (_, p) in l.extraTexts) {
        paragraphs.add(p);
      }
    }
    if (paragraphs.isEmpty) return;
    _glyphBaker.enqueueParagraphs(
      paragraphs,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
  }
}

/// 普通/私信话题列表的预热接线:取排版走 [obtainTopicItemLayout]
/// (与 buildTopicItem 挂载路径同一函数,天然同源)。构造参数须与
/// 列表页调用 buildTopicItem 时**逐参数一致**,缺省也要一致。
class TopicCardPrewarmScope extends StatelessWidget {
  const TopicCardPrewarmScope({
    super.key,
    required this.topics,
    this.categoryMap,
    this.statsAvailableWidth,
    this.messageStyle = false,
    this.compactPinned = false,
    required this.child,
  });

  final List<Topic> topics;
  final Map<int, Category>? categoryMap;
  final double? statsAvailableWidth;
  final bool messageStyle;

  /// 仅话题发现列表使用紧凑置顶；历史、书签等列表照常预热普通卡片。
  final bool compactPinned;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CardPrewarmScope<Topic>(
      items: topics,
      signature: (
        identityHashCode(topics),
        TopicCardLayout.themeSignature(Theme.of(context)),
        topicCardWidthFor(context),
        statsAvailableWidth,
        messageStyle,
        compactPinned,
        identityHashCode(categoryMap),
        TopicCardStyleScope.current,
      ),
      warmItem: (context, topic) {
        // 只有列表显式选用紧凑置顶时，才跳过对应的普通卡片预热。
        if (compactPinned && topic.pinned) return null;
        return obtainTopicItemLayout(
          context: context,
          topic: topic,
          categoryMap: categoryMap,
          statsAvailableWidth: statsAvailableWidth,
          messageStyle: messageStyle,
        );
      },
      child: child,
    );
  }
}
