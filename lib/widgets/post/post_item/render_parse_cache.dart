import 'dart:developer' as developer;

import 'package:fluxdo_render/fluxdo_render.dart';

import '../../../models/topic.dart';
import '../../../utils/fluxdo_render_callbacks.dart';
import '../../../utils/frame_jank_monitor.dart';

/// 帖子 cooked 解析产物的全局 LRU 缓存(跨挂载、跨页面)。
///
/// 对齐 legacy HtmlParseService 的设计(isolate 解析 + LRU 200 条,见
/// commit 524ad4f):sliver item 滚出 cacheExtent 即 dispose,State 级缓存
/// 跟着丢,来回滚动 = 反复重付 preprocess + DOM parse;旧引擎靠全局 LRU
/// 让"滚回来"与"重进话题"的解析全免,新引擎接入时该层缺失 —— 这里补齐。
///
/// 只缓存**纯数据**(preprocessed html / BlockNode 树 / chunk 切分),
/// callbacks(闭包持 post/topicId)由调用方每次自建,不进缓存。
///
/// 失效:key 按 post.id,值携带内容签名(cooked + mentions + links,
/// 注入产物受这三者影响),签名不匹配即重算 —— 帖子编辑/状态 emoji 变化
/// 自然失效,无需主动清理。
class RenderParseCache {
  RenderParseCache._();

  static const int _shortCap = 256;

  /// 分块阈值 5000→2000 后,2~5K 字符的中等帖子全部涌入长帖(分块)
  /// 体系,64 的容量会频繁驱逐、滚回来重付解析,相应扩容。
  /// 单条 LongPostParseData 持有的是节点树而非位图,内存量级可控。
  static const int _longCap = 128;

  /// 短帖:post.id → (签名, preprocessed, parsedNodes)
  static final _short = <int, _ShortEntry>{};

  /// 长帖:post.id → (签名, LongPostParseData)
  static final _long = <int, _LongEntry>{};

  /// 帖子渲染内容签名:cooked + mention 状态 + 链接点击数
  /// (preprocessCookedForRender 的全部输入)。
  static int signatureOf(Post post) {
    final mentionedUsers = post.mentionedUsers;
    final linkCounts = post.linkCounts;
    return Object.hash(
      post.cooked.length,
      post.cooked.hashCode,
      mentionedUsers == null
          ? 0
          : Object.hashAll(mentionedUsers.map((u) => Object.hash(
                u.id,
                u.username,
                u.statusEmoji,
                u.statusDescription,
              ))),
      linkCounts == null
          ? 0
          : Object.hashAll(linkCounts.map((l) => Object.hash(
                l.url,
                l.clicks,
                l.title,
                l.internal,
                l.reflection,
              ))),
    );
  }

  /// 短帖解析产物(preprocessed + nodes),命中签名直接复用。
  static ({String preprocessed, List<BlockNode> nodes}) shortPost(Post post) {
    final signature = signatureOf(post);
    final cached = _short.remove(post.id);
    if (cached != null && cached.signature == signature) {
      _short[post.id] = cached; // 触摸移到 LRU 尾
      return (preprocessed: cached.preprocessed, nodes: cached.nodes);
    }
    // Timeline 标记:STALL/jank 现场抓取的摘要里能点名"这段是帖子
    // 首次解析"(固定名,按名聚合;监控相关开销仅字符串一枚)。
    // Stopwatch + noteSpan:release(无 VM Service)下解析成本也进 JANK
    // 账单,条目名带帖号与正文大小(监控关闭时 noteSpan 空操作)。
    final watch = Stopwatch()..start();
    final parsed = developer.Timeline.timeSync('ParseShortPost', () {
      final preprocessed =
          FluxdoRenderCallbacks.preprocessCookedForRender(post);
      final nodes = List<BlockNode>.unmodifiable(
        ParagraphParser().parse(preprocessed),
      );
      return (preprocessed: preprocessed, nodes: nodes);
    });
    watch.stop();
    FrameJankMonitor.noteSpan(
      'parse:short#${post.postNumber}'
      '(${(post.cooked.length / 1000).toStringAsFixed(1)}k)',
      watch.elapsedMicroseconds,
    );
    _short[post.id] = _ShortEntry(
      signature: signature,
      preprocessed: parsed.preprocessed,
      nodes: parsed.nodes,
    );
    _evict(_short, _shortCap);
    return parsed;
  }

  /// 长帖解析产物;非长帖(不足分块)返回 null。
  /// [build] 由调用方提供(preprocess + chunk 切分),仅 miss 时执行。
  static LongPostParseData? longPost(
    Post post,
    LongPostParseData? Function() build,
  ) {
    final signature = signatureOf(post);
    final cached = _long.remove(post.id);
    if (cached != null && cached.signature == signature) {
      _long[post.id] = cached;
      return cached.data;
    }
    final data = build();
    // 非长帖也记负缓存(data null):避免每次 build 都重跑 preprocess+切分判定
    _long[post.id] = _LongEntry(signature: signature, data: data);
    _evict(_long, _longCap);
    return data;
  }

  static void _evict(Map<int, Object?> map, int cap) {
    while (map.length > cap) {
      map.remove(map.keys.first);
    }
  }

  /// 全清(系统内存压力响应)。纯数据缓存无 dispose 语义,清空安全:
  /// 在屏帖子 State 自持解析产物引用不受影响,滚回来 miss 重解析即可。
  static void clear() {
    _short.clear();
    _long.clear();
  }
}

class _ShortEntry {
  const _ShortEntry({
    required this.signature,
    required this.preprocessed,
    required this.nodes,
  });
  final int signature;
  final String preprocessed;
  final List<BlockNode> nodes;
}

class _LongEntry {
  const _LongEntry({required this.signature, required this.data});
  final int signature;
  final LongPostParseData? data;
}

/// 长帖的可全局缓存解析状态:chunk 切分(eager)+ 逐 chunk 懒解析(记忆化)。
/// 与 callbacks(不可缓存的闭包)分离 —— 见 NewEngineLongPostData。
class LongPostParseData {
  LongPostParseData({
    required this.preprocessed,
    required this.chunks,
    required this.footnotesHtml,
  })  : _parser = ParagraphParser(),
        _parsed = List<List<BlockNode>?>.filled(chunks.length, null),
        _offsets = List<int?>.filled(chunks.length, null);

  final String preprocessed;
  final List<HtmlChunk> chunks;
  final String? footnotesHtml;

  final ParagraphParser _parser;
  final List<List<BlockNode>?> _parsed;
  final List<int?> _offsets;

  /// 第 [index] 块的解析结果(未解析时顺序补齐前缀并缓存)。
  List<BlockNode> parsedChunkAt(int index) {
    ensureParsedThrough(index);
    return _parsed[index]!;
  }

  /// 第 [index] 块的图片 indexInPost 起始偏移。
  int imageOffsetAt(int index) {
    ensureParsedThrough(index);
    return _offsets[index]!;
  }

  /// 是否还有未解析的 chunk(空闲预热用)。
  bool get fullyParsed => _parsed.isNotEmpty && _parsed.last != null;

  /// 顺序解析 0..[index](offset 有前缀依赖)。已解析的块直接跳过,
  /// 单块只解析一次。
  void ensureParsedThrough(int index) {
    for (var i = 0; i <= index; i++) {
      if (_parsed[i] != null) continue;
      final prevOffset = i == 0 ? 0 : _offsets[i - 1]!;
      final prevCount = i == 0 ? 0 : countImageRuns(_parsed[i - 1]!);
      final offset = prevOffset + prevCount;
      // Stopwatch + noteSpan:release 下单块解析成本进 JANK 账单
      // (类无 post 引用,标签用 块序号+大小;监控关闭时空操作)
      final watch = Stopwatch()..start();
      final nodes = developer.Timeline.timeSync(
        'ParseLongChunk',
        () => _parser.parse(
          chunks[i].html,
          imageIndexStart: offset,
          footnotesHtml: footnotesHtml,
        ),
      );
      watch.stop();
      FrameJankMonitor.noteSpan(
        'parse:chunk$i(${(chunks[i].html.length / 1000).toStringAsFixed(1)}k)',
        watch.elapsedMicroseconds,
      );
      _parsed[i] = List.unmodifiable(nodes);
      _offsets[i] = offset;
    }
  }

  /// 预热一步:解析下一个未解析的 chunk,返回是否还有剩余。
  /// 空闲时逐块调用,把 parse 挪出滚动关键帧。
  bool warmUpOneChunk() {
    for (var i = 0; i < _parsed.length; i++) {
      if (_parsed[i] == null) {
        ensureParsedThrough(i);
        return i < _parsed.length - 1;
      }
    }
    return false;
  }

  /// 全帖 lightbox 画廊项(触发全 chunk 解析)。首次点图时被
  /// callbacks 的惰性画廊 resolver 调用。
  List<ImageRun> collectAllLightboxImageRuns() {
    if (chunks.isEmpty) return const [];
    ensureParsedThrough(chunks.length - 1);
    final runs = <ImageRun>[];
    for (final nodes in _parsed) {
      runs.addAll(collectLightboxImageRuns(nodes!));
    }
    return runs;
  }
}
