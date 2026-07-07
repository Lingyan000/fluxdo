import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../utils/frame_jank_monitor.dart';

/// 滚动锚定哨兵:浏览器 scroll anchoring 的**武装式**Flutter 等价物。
///
/// 问题:列表里视口上方的内容在静默更新时改变高度(msgbus 滚停回放的
/// reaction 行、编辑增减、话题列表顶部插入引发的 keyed 迁移平移),下方
/// 内容整体平移,视觉上正在读的文字"被拉一下"。浏览器有原生 scroll
/// anchoring 自动补偿,Flutter viewport 没有 —— 本哨兵用 sliver 协议的
/// [SliverGeometry.scrollOffsetCorrection] 在**同一帧内**补上这层。
///
/// ## 武装式(与浏览器全时锚定的关键差异)
///
/// 哨兵**默认只观察**(每趟布局刷新基线),永不修正。只有 [arm] 被调用
/// 后的那一帧才允许修正 —— arm 点是明确的"静默更新落地"时刻:
/// - 详情页 msgbus 更新应用前(实时/滚停回放)
/// - 话题列表结构变化落地帧(顶部插入/全量替换/pill 出现)
///
/// 用户主动交互(展开"回复给"、折叠引用等)产生的布局位移是**预期行为**
/// (内容就地展开、下方让位),不经过 arm 点,哨兵全程不介入 —— 保证
/// "没有滚动时,展开再收起,位置逐像素复原"这条硬约束。全时锚定曾在
/// 此类交互上产生位置漂移(多趟布局交叉时序的组合路径难以穷尽),故
/// 收缩为武装式:只保护确定该保护的帧。
///
/// ## 布局与修正机制
///
/// 零尺寸 sliver 挂 slivers 首尾各一。viewport 布局 reverse 区时从近
/// center 到远依次进行,首位哨兵最后布局;forward 区顺序布局,末位哨兵
/// 最后 —— 各自布局时本半场兄弟的位置都是新鲜值。**必须两个**:
/// `child.layout()` 在约束不变时跳过 performLayout,而 before 区高度变化
/// 不改 forward 区哨兵的约束,单哨兵会整半场失明。
///
/// 锚定限定**同半场**:哨兵只在与自己同增长方向的兄弟 sliver 里选锚
/// (含视口上沿的 segment,退而求其次取上沿下方最近者)。跨半场的锚在
/// 本趟布局里可能还没重排(reverse 先于 forward),读到陈旧位置会污染
/// 基线产生假修正。
///
/// 武装帧内:锚位移 Δ 超阈值即返回 scrollOffsetCorrection(reverse 区
/// 预先取负,viewport 对该区修正值会再取反),viewport `correctBy(Δ)`
/// 同帧重排 —— 像素纹丝不动,且 correctBy 不发滚动通知,eyeline/已读
/// 上报等不受扰动。滚动/跳楼/刷新会改 pixels,与基线逐位比较天然跳过。
///
/// 终止性:修正后 pixels 立即偏离基线,同帧重试趟必然走重建基线分支,
/// 一帧至多一次修正;[_correctionStreak] 是额外保险丝。
class AnchorGuardSliver extends LeafRenderObjectWidget {
  const AnchorGuardSliver({
    super.key,
    this.enabled = true,
    this.structureSignature = 0,
  });

  final bool enabled;

  /// 列表结构签名(segment 序列摘要)。签名变化 = 有帖子/分块被插入、
  /// 移除、换页 —— sliver child 按 index 复用,此时同一 RenderBox 可能
  /// 已换了内容,继续按旧基线修正会锚错对象,该帧只重建基线。纯数据
  /// 更新(点赞/reaction,列表身份变但结构不变)不改签名,正是哨兵要
  /// 消化的场景。(行已 key 化的列表可保持 0:身份由 key 保证。)
  final int structureSignature;

  /// 武装:本帧(含随后一帧,若当前不在帧内)的布局允许锚定修正。
  ///
  /// 在"静默更新落地"前调用 —— msgbus 帖子更新应用前、话题列表结构
  /// 变化落地的 build 里。帧末自动解除,用户交互引发的布局永不被锚定。
  /// 全局静态:同帧内所有哨兵实例共享武装状态(被遮挡页面的哨兵即使
  /// 被误武装,其布局也只会因数据事件触发,修正语义仍正确)。
  static void arm() {
    RenderAnchorGuardSliver._armed = true;
    if (RenderAnchorGuardSliver._disarmScheduled) return;
    RenderAnchorGuardSliver._disarmScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      RenderAnchorGuardSliver._disarmScheduled = false;
      RenderAnchorGuardSliver._armed = false;
    });
  }

  @override
  RenderAnchorGuardSliver createRenderObject(BuildContext context) =>
      RenderAnchorGuardSliver(
        enabled: enabled,
        structureSignature: structureSignature,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderAnchorGuardSliver renderObject,
  ) {
    renderObject
      ..enabled = enabled
      ..structureSignature = structureSignature;
  }
}

class RenderAnchorGuardSliver extends RenderSliver {
  RenderAnchorGuardSliver({
    required bool enabled,
    required int structureSignature,
  }) : _enabled = enabled,
       _structureSignature = structureSignature;

  /// 武装状态(见 [AnchorGuardSliver.arm]):静默更新帧才允许修正
  static bool _armed = false;
  static bool _disarmScheduled = false;

  bool get enabled => _enabled;
  bool _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) _invalidateBaseline();
  }

  int get structureSignature => _structureSignature;
  int _structureSignature;
  set structureSignature(int value) {
    if (_structureSignature == value) return;
    _structureSignature = value;
    // 结构变了:旧锚的 RenderBox 可能被 index 复用换了内容,基线作废。
    // updateRenderObject 在 build 期执行,先于本帧布局,时序正确。
    _invalidateBaseline();
  }

  // —— 基线:上一趟布局结束时的锚元素与环境快照 ——
  // 锚元素 = 同半场里含视口上沿的帖子(退而求其次:上沿下方最近的
  // 帖子)。持有 RenderBox 引用:数据更新只换 Post 内容,Element/
  // RenderObject 按 index 复用不变;被回收(detach/keptAlive)则基线
  // 自动作废。
  RenderBox? _anchorBox;
  double _anchorTop = 0.0;
  double _basePixels = 0.0;
  double _baseViewportAnchor = 0.0;
  Size _baseViewportSize = Size.zero;

  /// 连续修正保险丝:修正后 pixels 必然偏离基线、下一趟只能重建基线,
  /// 理论上不存在连环修正;万一有布局怪癖打破该假设,到 3 次直接放弃,
  /// 宁可跳一下也不逼近 viewport 的布局循环上限。
  int _correctionStreak = 0;

  /// 位移小于该值不修正:吸收文本重排的亚像素噪音,避免无意义的重排趟数
  static const _minCorrection = 0.5;

  void _invalidateBaseline() {
    _anchorBox = null;
  }

  @override
  void performLayout() {
    geometry = SliverGeometry.zero;
    if (!_enabled || constraints.axis != Axis.vertical) {
      _invalidateBaseline();
      return;
    }
    final viewport = _findViewport();
    final offset = viewport?.offset;
    if (viewport == null ||
        offset is! ScrollPosition ||
        !offset.hasPixels ||
        !viewport.hasSize) {
      _invalidateBaseline();
      return;
    }

    // 跨子树量兄弟 sliver 的 child 尺寸/位置属于"布局期越界访问",debug
    // 断言只对 layout callback 放行(invokeLayoutCallback 正是框架给
    // viewport 系"布局中做树外读取"留的正门)。本半场兄弟本趟已布局
    // 完毕,读到的是新鲜值;若发出修正,viewport 整趟重排,一致性由
    // 协议保证。
    double? correction;
    invokeLayoutCallback<SliverConstraints>((_) {
      correction = _measure(viewport, offset);
    });
    if (correction != null) {
      // reverse 区:viewport 对该区子级的修正值取反后 correctBy,这里
      // 预先反号,保证语义统一为"pixels += Δ"
      final sign = constraints.growthDirection == GrowthDirection.reverse
          ? -1.0
          : 1.0;
      geometry = SliverGeometry(scrollOffsetCorrection: sign * correction!);
    }
  }

  /// 返回本趟要发出的修正值(语义:pixels 应增加多少);null = 不修正
  /// (基线已按需重建)
  double? _measure(RenderViewport viewport, ScrollPosition offset) {
    final anchor = _anchorBox;
    // 只有武装帧才允许修正(见类文档);其余趟只观察、刷新基线。
    // pixels 用逐位相等:空闲期没人动它,双精度原样保留;任何滚动/
    // 跳转/修正都会让它偏离基线,正是"这趟只重建基线"的信号。
    // 顶部抑制(浏览器 scroll anchoring 同款):滚动位置贴着列表顶端时
    // 不锚定 —— 驻留顶部的用户应该看到新内容自然推入视野(话题列表的
    // "N 个新话题"pill、插入的新话题),钉住反而把它们藏进视口上方。
    final canCompare =
        _armed &&
        !offset.isScrollingNotifier.value &&
        anchor != null &&
        _anchorStillValid(anchor, viewport) &&
        offset.pixels == _basePixels &&
        offset.hasContentDimensions &&
        offset.pixels > offset.minScrollExtent + 1.0 &&
        viewport.anchor == _baseViewportAnchor &&
        viewport.size == _baseViewportSize;

    if (canCompare && _correctionStreak < 3) {
      final top = _boxTopInViewport(anchor, viewport);
      final delta = top - _anchorTop;
      if (delta.abs() > _minCorrection) {
        // 锚往下移 Δ(上方内容变高)→ pixels 需同增 Δ 把它拉回原位;
        // 变矮同理(Δ 为负)
        _correctionStreak++;
        _pendingLogDelta += delta;
        _scheduleLog();
        return delta;
      }
    }

    _correctionStreak = 0;
    _captureBaseline(viewport, offset);
    return null;
  }

  /// 锚元素仍可参与比较:还挂在树上、有尺寸、没被挪进 keepAlive 桶
  /// (桶里的 child 仍 attached 但 layoutOffset 是陈旧值),且确实在本
  /// viewport 之下(getTransformTo 对非祖先会 assert)。
  bool _anchorStillValid(RenderBox anchor, RenderViewport viewport) {
    if (!anchor.attached || !anchor.hasSize) return false;
    final parentData = anchor.parentData;
    if (parentData is! SliverMultiBoxAdaptorParentData ||
        parentData.keptAlive ||
        parentData.layoutOffset == null) {
      return false;
    }
    RenderObject? node = anchor.parent;
    while (node != null) {
      if (identical(node, viewport)) return true;
      node = node.parent;
    }
    return false;
  }

  /// box 顶边在 viewport 坐标系(0 = 视口上沿)里的 y
  double _boxTopInViewport(RenderBox box, RenderViewport viewport) {
    return MatrixUtils.transformPoint(
      box.getTransformTo(viewport),
      Offset.zero,
    ).dy;
  }

  /// 重建基线:只遍历**与自己同增长方向**的兄弟 sliver 里的帖子列表
  /// (RenderSliverMultiBoxAdaptor;header/typing/分页指示器都是单 box
  /// 适配器,自动排除),选含视口上沿的 child 为锚。
  ///
  /// 限定同半场的原因:viewport 每趟先布局 reverse 区再布局 forward 区,
  /// reverse 哨兵布局时 forward 兄弟可能尚未重排,跨半场读到的是陈旧
  /// 位置,存进基线会在下一次武装帧产生假位移假修正。同半场兄弟在
  /// 本哨兵布局时(各自半场的最后)必然新鲜。
  void _captureBaseline(RenderViewport viewport, ScrollPosition offset) {
    RenderBox? containing;
    double containingTop = 0;
    RenderBox? below;
    double belowTop = double.infinity;

    void visit(RenderObject node) {
      if (node is RenderSliverMultiBoxAdaptor) {
        RenderBox? child = node.firstChild;
        while (child != null) {
          final parentData = child.parentData;
          if (parentData is SliverMultiBoxAdaptorParentData &&
              parentData.layoutOffset != null &&
              child.hasSize) {
            final top = _boxTopInViewport(child, viewport);
            final bottom = top + child.size.height;
            if (top <= 0 && bottom > 0) {
              // 多个候选(理论上仅重叠边界)取顶边最贴近上沿的
              if (containing == null || top > containingTop) {
                containing = child;
                containingTop = top;
              }
            } else if (top > 0 && top < belowTop) {
              below = child;
              belowTop = top;
            }
          }
          child = node.childAfter(child);
        }
      } else if (node is RenderSliver) {
        node.visitChildren(visit);
      }
    }

    // 从 center 出发沿本半场方向遍历兄弟(不含自己)
    final reverse = constraints.growthDirection == GrowthDirection.reverse;
    final center = viewport.center;
    RenderSliver? node = center == null
        ? null
        : (reverse ? viewport.childBefore(center) : center);
    while (node != null) {
      if (!identical(node, this)) visit(node);
      node = reverse ? viewport.childBefore(node) : viewport.childAfter(node);
    }

    final anchorBox = containing ?? below;
    if (anchorBox == null) {
      _invalidateBaseline();
      return;
    }
    _anchorBox = anchorBox;
    _anchorTop = containing != null ? containingTop : belowTop;
    _basePixels = offset.pixels;
    _baseViewportAnchor = viewport.anchor;
    _baseViewportSize = viewport.size;
  }

  RenderViewport? _findViewport() {
    RenderObject? node = parent;
    while (node != null) {
      if (node is RenderViewport) return node;
      node = node.parent;
    }
    return null;
  }

  @override
  void detach() {
    _invalidateBaseline();
    super.detach();
  }

  // —— 诊断:修正事件汇入性能时间轴,生产日志可见哨兵工作频率与幅度 ——
  // 布局期不能碰 FrameJankMonitor(revision 通知会触发监听方 setState),
  // 攒到帧末统一上报。
  static double _pendingLogDelta = 0;
  static bool _logScheduled = false;

  static void _scheduleLog() {
    if (_logScheduled) return;
    _logScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _logScheduled = false;
      final delta = _pendingLogDelta;
      _pendingLogDelta = 0;
      FrameJankMonitor.logEvent(
        'ANCHOR',
        '静默更新帧布局位移已锚定修正 Δ${delta.toStringAsFixed(1)}px',
      );
    });
  }
}
