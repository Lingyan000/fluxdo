import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

import '../../../models/topic.dart';
import '../../../widgets/post/post_item/render_parse_cache.dart';
import '../../../widgets/post/post_item/segmented_long_post.dart';
import 'topic_detail_controller.dart';

/// 话题目录(TOC)状态与滚动编排 —— 对齐 DiscoTOC(theme component)。
///
/// 显示口径(仅 1 楼,对齐 DiscoTOC 默认 `enable_TOC_for_replies=false`):
/// - cooked 含 `<div data-theme-toc="true">`(DiscoTOC「插入目录」标记);
/// - 或顶层标题数 ≥ [minHeadings](自动兜底 —— 站点主题的
///   `auto_TOC_categories/tags` 配置不暴露给 API,这里对齐其效果)。
///
/// 滚动模型:
/// - 点击跳转走「段级粗定位 + 渲染几何精确化」两段式(同 hero 图源跳转):
///   长帖标题可能落在未物化的 chunk 段,先 [TopicDetailController
///   .scrollToPostChunk] 把段跳进布局范围,挂载后再按 reveal 偏移对齐;
/// - scroll-spy 遍历已挂载锚点取顶对齐偏移,现行位置以下最后一个标题
///   即激活项,激活项祖先链一并高亮(对齐 DiscoTOC activeAncestorIds)。
class TopicTocController extends ChangeNotifier {
  TopicTocController({required this.detailController});

  final TopicDetailController detailController;

  /// 对齐 DiscoTOC `TOC_min_heading` 默认值。
  static const int minHeadings = 3;

  /// DiscoTOC「插入目录」在 cooked 里的标记。
  static const String tocMarker = 'data-theme-toc="true"';

  /// scroll-spy 激活缓冲(视口顶往下多少算"读到",对齐 DiscoTOC
  /// POSITION_BUFFER=150 的感受:提前激活,别等标题死死贴顶)。
  static const double _spyBuffer = 150;

  /// 标题锚点注册表(渲染侧 HeadingAnchorRegistrar 挂载即注册)。
  /// 页面用它建 [HeadingAnchorScope]。
  final HeadingAnchorRegistry registry = HeadingAnchorRegistry();

  TocData? _tocData;

  /// 提取来源的内容签名(post.id + cooked),变了才重提(编辑 1 楼、
  /// 换话题都会变;message bus 点赞等 copyWith 不改 cooked,不重提)。
  int _tocSignature = 0;

  /// 点击跳转进行中的目标 id:跳转动画期间 spy 不重算激活项,避免
  /// 高亮沿路径狂闪;落地后恢复。
  String? _jumpTargetId;

  String? _activeHeadingId;
  Set<String> _activeAncestorIds = const {};
  Map<String, TocEntry> _entryById = const {};
  Map<String, String?> _parentById = const {};

  Timer? _spyThrottle;

  TocData? get tocData => _tocData;
  bool get hasToc => _tocData != null && _tocData!.flat.isNotEmpty;
  String? get activeHeadingId => _activeHeadingId;
  Set<String> get activeAncestorIds => _activeAncestorIds;

  /// 点击跳转进行中:页面据此冻结 TOC 显隐(快速滚动途中 eyeline
  /// 会瞬报其他楼层,不冻结会闪隐)。
  bool get isJumping => _jumpTargetId != null;

  /// 顶对齐后的视觉缓冲:帖子列表视口顶就在 AppBar 下缘(标准 Scaffold
  /// 不重叠),reveal 0 对齐后标题贴边,留一点间距好看。
  static const double _topBuffer = 12;

  /// 话题数据落地/更新后调用:条件满足则(重新)提取 1 楼 TOC。
  ///
  /// 1 楼不在当前已加载流里(如从通知直达 20 楼)时不提取,等它分页进来
  /// 后下次调用自然补上(对齐 DiscoTOC 需要首帖 cooked 的前提)。
  void updateTopic(TopicDetail detail) {
    final posts = detail.postStream.posts;
    final firstIndex = posts.indexWhere((p) => p.postNumber == 1);
    if (firstIndex == -1) {
      if (_tocData != null) _clear();
      return;
    }
    final post = posts[firstIndex];

    final signature = Object.hash(post.id, post.cooked.hashCode);
    if (signature == _tocSignature) return;
    _tocSignature = signature;

    // 阈值口径在 _extract 内:有标记时放宽到 1(尊重作者显式意图),
    // 无标记时按 minHeadings(对齐 DiscoTOC TOC_min_heading 默认 3)
    final data = _extract(post, topicId: detail.id);
    if (data == null) {
      if (_tocData != null) _clear();
      return;
    }
    _apply(data);
  }

  /// 从 1 楼提取 TOC:长帖按渲染 chunk 逐块解析(命中渲染同款
  /// LRU,不重复付费),短帖整帖提取。
  TocData? _extract(Post post, {required int topicId}) {
    final longData = NewEngineLongPostData.tryBuild(post, topicId: topicId);
    if (longData != null) {
      final chunks = <List<BlockNode>>[
        for (var i = 0; i < longData.chunks.length; i++)
          longData.parsedChunkAt(i),
      ];
      return TocExtractor.buildFromChunks(
        chunks,
        postId: post.id,
        minHeadings: post.cooked.contains(tocMarker) ? 1 : minHeadings,
      );
    }
    return TocExtractor.build(
      RenderParseCache.shortPost(post).nodes,
      postId: post.id,
      minHeadings: post.cooked.contains(tocMarker) ? 1 : minHeadings,
    );
  }

  void _apply(TocData data) {
    _tocData = data;
    _entryById = {for (final e in data.flat) e.id: e};
    // 父链(spy 祖先高亮用)
    final parents = <String, String?>{};
    void walk(List<TocEntry> items, String? parentId) {
      for (final item in items) {
        parents[item.id] = parentId;
        walk(item.subItems, item.id);
      }
    }

    walk(data.tree, null);
    _parentById = parents;
    _activeHeadingId = null;
    _activeAncestorIds = const {};
    notifyListeners();
    // 初次激活:不滚动不触发 spy,等帧后标题挂载先算一次
    WidgetsBinding.instance.addPostFrameCallback((_) => updateActiveHeading());
  }
  /// 测试入口:直接注入提取产物(绕过帖子解析)。
  @visibleForTesting
  void debugSetTocData(TocData data) => _apply(data);

  void _clear() {
    _tocData = null;
    _tocSignature = 0;
    _entryById = const {};
    _parentById = const {};
    _activeHeadingId = null;
    _activeAncestorIds = const {};
    _jumpTargetId = null;
    notifyListeners();
  }

  /// 点击目录项跳转:先段级粗定位(短帖 null chunk → 整帖段),
  /// 等两帧让标题挂载,再按 reveal 几何精确对齐到视口顶。
  Future<void> scrollToHeading(TocEntry entry, List<Post> posts) async {
    _jumpTargetId = entry.id;
    _setActive(entry.id);
    try {
      await detailController.scrollToPostChunk(1, entry.chunkIndex, posts);
      // 等两帧:目标段构建、HeadingAnchorRegistrar 完成注册
      // (同 _scrollToHeroTagSource 的节奏)
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      _preciseAlign(entry.anchorKey);
    } finally {
      _jumpTargetId = null;
    }
  }

  /// 把已挂载标题精确对齐到视口顶(留 [_topBuffer] 视觉缓冲)。
  void _preciseAlign(String anchorKey) {
    final ctx = registry.contextOf(anchorKey);
    if (ctx == null) return;
    final RenderObject? box;
    try {
      box = ctx.findRenderObject();
    } catch (_) {
      return; // element 失活(inactive)时 findRenderObject 会抛
    }
    if (box == null || !box.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    final sc = detailController.scrollController;
    if (!sc.hasClients) return;
    final target =
        viewport.getOffsetToReveal(box, 0.0).offset - _topBuffer;
    sc.jumpTo(target.clamp(
      sc.position.minScrollExtent,
      sc.position.maxScrollExtent,
    ));
  }

  /// 页面滚动回调里调用(内部 80ms 节流)。
  void scheduleSpyUpdate() {
    if (!hasToc) return;
    if (_spyThrottle?.isActive ?? false) return;
    _spyThrottle = Timer(const Duration(milliseconds: 80), () {
      _spyThrottle = null;
      updateActiveHeading();
    });
  }

  /// scroll-spy:视口现行位置以上最后一个已挂载标题为激活项。
  /// 未挂载(滚出回收)的标题跳过;跳转进行中不重算(防路径闪烁)。
  void updateActiveHeading() {
    final data = _tocData;
    if (data == null || _jumpTargetId != null) return;
    final sc = detailController.scrollController;
    if (!sc.hasClients) return;

    final threshold = sc.position.pixels + _topBuffer + _spyBuffer;
    String? activeId;
    for (final entry in data.flat) {
      final offset = _topAlignOffsetOf(entry.anchorKey);
      if (offset == null) continue; // 未挂载:位置未知,跳过
      if (offset <= threshold) activeId = entry.id;
    }
    _setActive(activeId);
  }

  /// 标题顶对齐所需的滚动偏移;未挂载返回 null。
  double? _topAlignOffsetOf(String anchorKey) {
    final ctx = registry.contextOf(anchorKey);
    if (ctx == null) return null;
    final RenderObject? box;
    try {
      box = ctx.findRenderObject();
    } catch (_) {
      return null;
    }
    if (box == null || !box.attached) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    return viewport?.getOffsetToReveal(box, 0.0).offset;
  }

  void _setActive(String? id) {
    if (id == _activeHeadingId) return;
    _activeHeadingId = id;
    final ancestors = <String>{};
    var cursor = _parentById[id];
    while (cursor != null) {
      ancestors.add(cursor);
      cursor = _parentById[cursor];
    }
    _activeAncestorIds = ancestors;
    notifyListeners();
  }

  /// 深链锚点(`#p-123-h-xxx-1`)找目录项;找不到返回 null。
  TocEntry? entryByAnchorName(String anchorName) => _entryById[anchorName];

  @override
  void dispose() {
    _spyThrottle?.cancel();
    super.dispose();
  }
}
