import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../services/discourse_cache_manager.dart';
import '../../services/emoji_handler.dart';
import '../../utils/relative_time_clock.dart';
import '../common/animated_avatar_overlay.dart';
import '../common/smart_avatar.dart' show isSquareAvatarUrl;
import 'topic_card.dart' show TopicCardInteractiveSurface;
import 'topic_card_layout.dart';

/// 标题 emoji 短代码 → 图片 URL(自绘卡排版层注入;顶层函数,避免
/// 每个调用点手写 EmojiHandler 单例访问)
String topicCardEmojiUrlResolver(String name) =>
    EmojiHandler().getEmojiUrl(name);

/// 话题自绘卡:内容 = 单 RenderObject 绘制 [TopicCardLayout] 的排版
/// 成品;**壳与交互与 widget 版逐层同构** —— Padding(卡间距) →
/// ClipRRect(有色带时) → DecoratedBox(卡底色) →
/// [TopicCardInteractiveSurface](与 TopicCard 共用同一交互面:桌面
/// hover/水波纹/右键/中键,移动按压灰底) → 内容 leaf。
///
/// widget 版一张卡 = 百级组件树(挂载 7~13ms);本卡 = 4 个壳组件 +
/// 1 个内容 RenderObject,布局直接读 layout 几何,绘制 drawParagraph
/// 若干(1~2ms)。交互面是共用组件,水波纹/hover 动画与原卡完全一致。
///
/// 图片(头像/标题 emoji)经 [TopicCardImages] 全局解码缓存:命中
/// 同步画;miss 发起解码,完成后 markNeedsPaint 补画。
class PaintedTopicCard extends StatefulWidget {
  const PaintedTopicCard({
    super.key,
    required this.layout,
    this.onTap,
    this.onLongPress,
    this.onMiddleClick,
    this.onPreviewIntent,
    this.isSelected = false,
    this.highlightColor,
  });

  final TopicCardLayout layout;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onMiddleClick;

  /// 预览意图回调(预加载正文),见 TopicCardInteractiveSurface
  final VoidCallback? onPreviewIntent;

  /// 双栏选中态(与 widget 版 TopicCard 同款:primaryContainer 0.4 底
  /// + primary 0.5 描边)
  final bool isSelected;

  /// 新话题落地的高亮渐变色(TweenAnimationBuilder 驱动时逐帧传入)
  final Color? highlightColor;

  @override
  State<PaintedTopicCard> createState() => _PaintedTopicCardState();
}

class _PaintedTopicCardState extends State<PaintedTopicCard> {
  /// 已就绪在播的动图 URL:与当前 layout.animatedAvatarUrl 一致时画布
  /// 停画静态头像(透明 gif 的帧挡不住底图,静态层继续画会从透明像素
  /// 后面透出成"静态+动态双影");对不上(开关切换/换头像/出错回退/
  /// 无 key 复用元素换了话题)自动恢复画静态兜底
  String? _readyAnimatedUrl;

  @override
  Widget build(BuildContext context) {
    final layout = widget.layout;
    final cardRadius = BorderRadius.circular(10);
    final theme = Theme.of(context);
    final bgColor = widget.isSelected
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
        : (widget.highlightColor ?? layout.cardColor);
    // 动图头像混合岛:layout.animatedAvatarUrl 非空(开关开启且用户有
    // 动图)时挂播放 overlay 钉在 avatarRect,画布先画静态模板小图
    // (几 KB 秒出)顶住观感;overlay 首帧就绪后画布停画静态层,防
    // 透明 gif 透出底下的静态首帧
    final animatedUrl = layout.animatedAvatarUrl;
    final Widget? avatarOverlay = animatedUrl != null
        ? AnimatedAvatarOverlay(
            url: animatedUrl,
            onReadyChanged: (ready) {
              final value = ready ? animatedUrl : null;
              if (value != _readyAnimatedUrl) {
                setState(() => _readyAnimatedUrl = value);
              }
            },
          )
        : null;
    Widget card = DecoratedBox(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: cardRadius,
        border: widget.isSelected
            ? Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
              )
            : null,
      ),
      child: TopicCardInteractiveSurface(
        borderRadius: cardRadius,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onPreviewIntent: widget.onPreviewIntent,
        onMiddleClick: widget.onMiddleClick,
        child: _PaintedTopicCardLeaf(
          layout: layout,
          paintStaticAvatar:
              animatedUrl == null || animatedUrl != _readyAnimatedUrl,
          child: avatarOverlay,
        ),
      ),
    );
    if (layout.band != null) {
      card = ClipRRect(borderRadius: cardRadius, child: card);
    }
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: card);
  }
}

class _PaintedTopicCardLeaf extends SingleChildRenderObjectWidget {
  const _PaintedTopicCardLeaf({
    required this.layout,
    required this.paintStaticAvatar,
    super.child,
  });

  final TopicCardLayout layout;

  /// 动图 overlay 已就绪在播时为 false:画布停画静态头像,防透明 gif
  /// 从透明像素后透出静态层成"双影"
  final bool paintStaticAvatar;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderTopicCard(
      layout: layout,
      paintStaticAvatar: paintStaticAvatar,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderTopicCard renderObject,
  ) {
    renderObject
      ..layoutData = layout
      ..paintStaticAvatar = paintStaticAvatar;
  }
}

class _RenderTopicCard extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  _RenderTopicCard({
    required TopicCardLayout layout,
    required bool paintStaticAvatar,
  }) : _layout = layout,
       _paintStaticAvatar = paintStaticAvatar;

  TopicCardLayout _layout;
  int _seenRevision = 0;
  set layoutData(TopicCardLayout v) {
    if (identical(_layout, v) && _seenRevision == v.revision) return;
    _layout = v;
    _seenRevision = v.revision;
    markNeedsLayout();
  }

  bool _paintStaticAvatar;
  set paintStaticAvatar(bool v) {
    if (v == _paintStaticAvatar) return;
    _paintStaticAvatar = v;
    markNeedsPaint();
  }

  /// 在屏订阅分钟心跳:跳一次即原地重排本卡(时间串换新)并重绘。
  /// attach/detach 管理生命周期 —— 滚出 cacheExtent 即退订,离屏卡
  /// 靠 obtain 的分钟代惰性换新,全 app 每分钟只有在屏的十几张卡
  /// 各付一次 ~1ms 重排,发生在无滚动的静止帧
  void _onClockTick() {
    _layout.refreshTime();
    _seenRevision = _layout.revision;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    RelativeTimeClock.instance.addListener(_onClockTick);
  }

  @override
  void detach() {
    RelativeTimeClock.instance.removeListener(_onClockTick);
    super.detach();
  }

  // 命中不拦截:点按/长按/hover 全部由外层共用交互面(InkWell /
  // _MobileTopicTapSurface)处理,本对象只负责画
  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void performLayout() {
    // 布局期宽度纠正:build 期的排版宽是视口估算(桌面双栏/分屏下与
    // 列表格子真实宽不同,估错 = 右对齐元素画出卡外)。真实约束宽在
    // 此才可知,差 >0.5px 触发一次按宽重排(结果缓存,后续帧零成本)
    _layout.ensureWidth(constraints.maxWidth);
    // cardHeight 含底部 8px 卡间距(由外层 Padding 提供),内容体扣除
    size = constraints.constrain(
      Size(constraints.maxWidth, _layout.cardHeight - 8),
    );
    // 动图头像子节点(SmartAvatar 混合岛):钉在 avatarRect
    final c = child;
    if (c != null) {
      c.layout(BoxConstraints.tight(_layout.avatarRect.size));
      (c.parentData! as BoxParentData).offset = _layout.avatarRect.topLeft;
    }
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final l = _layout;

    // 色带底色(裁剪由外层 ClipRRect 承担,与 widget 版同构)
    if (l.band != null) {
      canvas.drawRect(
        Rect.fromLTWH(offset.dx, offset.dy, size.width, l.bandHeight),
        Paint()..color = l.bandColor,
      );
      canvas.drawParagraph(l.band!, offset + l.bandTextOffset);
      for (final (rect, icon) in l.bandIcons) {
        canvas.drawParagraph(icon, rect.topLeft + offset + l.bandTextOffset);
      }
    }

    // 标题 + 内嵌状态图标 + 内嵌 emoji
    canvas.drawParagraph(l.title!, offset + l.titleOffset);
    for (final (rect, icon) in l.titleIcons) {
      canvas.drawParagraph(icon, rect.topLeft + offset + l.titleOffset);
    }
    for (final (rect, url) in l.titleEmojis) {
      final img = TopicCardImages.lookup(
        url,
        this,
        bucket: BlobImageCache.emojiBucket,
      );
      if (img != null) {
        canvas.drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          rect.shift(offset + l.titleOffset),
          Paint()..filterQuality = FilterQuality.low,
        );
      }
    }

    if (l.excerpt != null) {
      canvas.drawParagraph(l.excerpt!, offset + l.excerptOffset);
    }

    // 头像:动图 overlay 未就绪时画静态首帧(TopicCardImages 单帧,
    // 未到则灰底)顶住观感;overlay 首帧就绪后停画 —— 透明 gif 的帧
    // 挡不住底图,继续画会从透明像素后透出"静态+动态双影"
    if (_paintStaticAvatar) {
      final avatarRect = l.avatarRect.shift(offset);
      final avatar = l.avatarUrl == null
          ? null
          : TopicCardImages.lookup(
              l.avatarUrl!,
              this,
              bucket: BlobImageCache.avatarBucket,
            );
      if (avatar != null) {
        canvas.save();
        // linux.do 站点定制:个别账号头像方形化,画布直绘不走 SmartAvatar,
        // 得同一份 isSquareAvatarUrl 判断,不然图是方的、这里裁切还是圆的。
        final clipPath = isSquareAvatarUrl(l.avatarUrl)
            ? (Path()..addRRect(
                RRect.fromRectAndRadius(
                  avatarRect,
                  Radius.circular(avatarRect.shortestSide * 0.1),
                ),
              ))
            : (Path()..addOval(avatarRect));
        canvas.clipPath(clipPath);
        canvas.drawImageRect(
          avatar,
          Rect.fromLTWH(
            0,
            0,
            avatar.width.toDouble(),
            avatar.height.toDouble(),
          ),
          avatarRect,
          Paint()..filterQuality = FilterQuality.low,
        );
        canvas.restore();
      } else {
        canvas.drawOval(avatarRect, Paint()..color = const Color(0x14888888));
      }
    }

    // 署名/时间可被字段开关关闭(layout 中为 null)
    if (l.author != null) {
      canvas.drawParagraph(l.author!, offset + l.authorOffset);
    }
    if (l.time != null) {
      canvas.drawParagraph(l.time!, offset + l.timeOffset);
    }
    if (l.categoryDotColor != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          l.categoryDotRect.shift(offset),
          const Radius.circular(2),
        ),
        Paint()..color = l.categoryDotColor!,
      );
    }
    if (l.catTags != null) {
      canvas.drawParagraph(l.catTags!, offset + l.catTagsOffset);
    }
    if (l.stats != null) {
      canvas.drawParagraph(l.stats!, offset + l.statsOffset);
      for (final (rect, icon) in l.statsIcons) {
        canvas.drawParagraph(icon, rect.topLeft + offset + l.statsOffset);
      }
    }

    // 通用装饰通道:徽章/蓝点/楼层 chip 底 + 徽章数字/AI 图标
    for (final (rrect, color) in l.extraFills) {
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          rrect.left + offset.dx,
          rrect.top + offset.dy,
          rrect.right + offset.dx,
          rrect.bottom + offset.dy,
          topLeft: rrect.tlRadius,
          topRight: rrect.trRadius,
          bottomLeft: rrect.blRadius,
          bottomRight: rrect.brRadius,
        ),
        Paint()..color = color,
      );
    }
    for (final (pos, p) in l.extraTexts) {
      canvas.drawParagraph(p, pos + offset);
    }

    // 动图头像子节点(SmartAvatar 混合岛,内含 RepaintBoundary,
    // 逐帧重绘不连累本画布)
    final c = child;
    if (c != null) {
      context.paintChild(c, offset + (c.parentData! as BoxParentData).offset);
    }
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    // 点按/长按动作由外层交互面的 Semantics 提供,这里只报内容
    config
      ..label = _layout.semanticsLabel
      ..textDirection = TextDirection.ltr;
  }
}

/// 自绘卡的图片解码缓存(头像 / 标题 emoji):URL → ui.Image。
///
/// 命中同步返回;miss 记下发起方 RenderObject,经 cache_manager 取
/// 文件 → instantiateImageCodec(走 FluxdoWidgetsBinding 的解码闸门,
/// 与全局图片调度统一)→ 解码完成 markNeedsPaint 补画。
class TopicCardImages {
  TopicCardImages._();

  static final Map<String, ui.Image> _images = {};
  static final Map<String, Set<RenderObject>> _waiters = {};
  static const int _cap = 400;

  static ui.Image? lookup(
    String url,
    RenderObject requester, {
    String bucket = BlobImageCache.avatarBucket,
  }) {
    final hit = _images[url];
    if (hit != null) return hit;
    final waiters = _waiters[url];
    if (waiters != null) {
      waiters.add(requester);
      return null;
    }
    _waiters[url] = {requester};
    unawaited(_load(url, bucket));
    return null;
  }

  /// 空闲预解码(TopicCardPrewarmScope):无发起方 RenderObject,命中
  /// /在途都免费返回;miss 时登记空 waiter 集发起解码 —— 后续真实
  /// 挂载若在解码完成前 lookup,会并入同一份 waiter 正常收到补画。
  static void prewarm(
    String url, {
    String bucket = BlobImageCache.avatarBucket,
  }) {
    if (_images.containsKey(url) || _waiters.containsKey(url)) return;
    _waiters[url] = {};
    unawaited(_load(url, bucket));
  }

  static Future<void> _load(String url, String bucket) async {
    try {
      final bytes = await BlobImageCache.fetch(bucket, url);
      if (bytes.isEmpty) {
        _waiters.remove(url);
        return;
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      // 头像显示 32dp、emoji ~19dp;96px 解码对两者都双倍富余
      final codec = await PaintingBinding.instance
          .instantiateImageCodecWithSize(
            buffer,
            getTargetSize: (w, h) {
              if (w <= 96 && h <= 96) {
                return ui.TargetImageSize(width: w, height: h);
              }
              final ratio = 96 / (w > h ? w : h);
              return ui.TargetImageSize(
                width: (w * ratio).round(),
                height: (h * ratio).round(),
              );
            },
          );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (_images.length >= _cap) {
        for (final k in _images.keys.take(_cap ~/ 4).toList()) {
          _images.remove(k)?.dispose();
        }
      }
      _images[url] = frame.image;
    } catch (_) {
      // 失败不重试本会话(fallback 占位继续显示);滚动重访会因 waiters
      // 已清除而重新尝试
    } finally {
      final waiters = _waiters.remove(url);
      if (waiters != null && _images.containsKey(url)) {
        for (final r in waiters) {
          if (r.attached) r.markNeedsPaint();
        }
      }
    }
  }
}
