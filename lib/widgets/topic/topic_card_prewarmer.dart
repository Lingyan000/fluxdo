import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/category.dart';
import '../../models/topic.dart';
import '../../models/topic_card_style.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/idle_task.dart';
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

  Object? _lastSignature;

  static const int _budgetMicros = 4000;

  /// 预热规模上限:TopicCardLayout 全局 LRU 上限 500(满了清一半),
  /// 多页 load more 后列表可达数百条,不设限的全列表预热会把在屏项
  /// 从缓存里冲掉(不破坏正确性 —— 下次 obtain 重建,但白费预热)。
  /// 300 = 覆盖十几屏的余量,同时给其他列表页留出共享空间。
  static const int _maxWarmCount = 300;

  @override
  Widget build(BuildContext context) {
    if (kUsePaintedTopicCard && widget.signature != _lastSignature) {
      _lastSignature = widget.signature;
      _restart();
    }
    return widget.child;
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  void _restart() {
    final generation = ++_generation;
    var index = 0;
    bool canceled() => !mounted || generation != _generation;

    void step() {
      if (canceled()) return;
      final items = widget.items;
      final limit = items.length < _maxWarmCount
          ? items.length
          : _maxWarmCount;
      final stopwatch = Stopwatch()..start();
      final baked = <TopicCardLayout>[];
      while (index < limit && stopwatch.elapsedMicroseconds < _budgetMicros) {
        final item = items[index++];
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
        for (final (_, url) in layout.titleEmojis) {
          TopicCardImages.prewarm(url, bucket: BlobImageCache.emojiBucket);
        }
      }
      _bakeGlyphs(baked);
      if (index < limit) {
        scheduleIdleTask(step, isCanceled: canceled);
      }
    }

    scheduleIdleTask(step, isCanceled: canceled);
  }

  /// 字形预烤:把本步新排版的段落离屏光栅化一次,字形提前进引擎
  /// 全局字形图集(glyph atlas)。
  ///
  /// 动机(拖影定案实验):快滚含摘要列表时"灰块替代摘要文字 = 明显
  /// 变顺",坐实卡顿来自字形光栅化/图集上传 —— 两行中文摘要每卡
  /// 60~80 个不重复汉字,且 12px 摘要与标题不同字号在图集中互不共享,
  /// 首见字形的光栅化+纹理上传全堆在滚入帧的 raster 线程。
  ///
  /// 只 build 段落不够:图集在 raster 阶段才填充,必须真画一次。
  /// 所有段落原点重叠着画进一张 Picture(重叠不影响图集收录),
  /// toImage 走引擎同一光栅上下文,每步一次、离屏小图、即弃。
  void _bakeGlyphs(List<TopicCardLayout> layouts) {
    if (layouts.isEmpty) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    double w = 1, h = 1;
    void draw(ui.Paragraph p) {
      canvas.drawParagraph(p, Offset.zero);
      if (p.longestLine > w) w = p.longestLine;
      if (p.height > h) h = p.height;
    }

    for (final l in layouts) {
      for (final p in [l.band, l.title, l.excerpt, l.author, l.time,
          l.catTags, l.stats]) {
        if (p != null) draw(p);
      }
      for (final (_, p) in l.titleIcons) {
        draw(p);
      }
      for (final (_, p) in l.bandIcons) {
        draw(p);
      }
      for (final (_, p) in l.statsIcons) {
        draw(p);
      }
      for (final (_, p) in l.extraTexts) {
        draw(p);
      }
    }
    final picture = recorder.endRecording();
    picture
        .toImage(w.ceil().clamp(1, 4096), h.ceil().clamp(1, 4096))
        .then((img) => img.dispose())
        .catchError((_) {})
        .whenComplete(picture.dispose);
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
    required this.child,
  });

  final List<Topic> topics;
  final Map<int, Category>? categoryMap;
  final double? statsAvailableWidth;
  final bool messageStyle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CardPrewarmScope<Topic>(
      items: topics,
      signature: (
        identityHashCode(topics),
        identityHashCode(Theme.of(context)),
        topicCardWidthFor(context),
        statsAvailableWidth,
        messageStyle,
        identityHashCode(categoryMap),
        TopicCardStyleScope.current,
      ),
      warmItem: (context, topic) {
        // 置顶走 CompactTopicCard(widget 版),无排版缓存可热
        if (topic.pinned) return null;
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
