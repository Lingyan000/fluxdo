import 'dart:async';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../utils/url_helper.dart';
import 'discourse/discourse_service.dart';
import 'topic_preview_preloader.dart';

/// 话题正文摘要及媒体数据结构
class TopicExcerptData {
  final String text;
  final List<String> imageUrls;

  const TopicExcerptData({required this.text, this.imageUrls = const []});

  bool get isEmpty => text.isEmpty && imageUrls.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

/// 话题正文摘要服务：负责 HTML 正文清洗、媒体图片提取、文本缓存与异步按需获取。
/// 适用于类似 X（推特）首页信息流的长文智能截断展示与媒体图片网格。
class TopicExcerptService {
  static final TopicExcerptService _instance = TopicExcerptService._internal();
  factory TopicExcerptService() => _instance;
  TopicExcerptService._internal();

  /// 内存 LRU 缓存：topicId -> 清洗后的正文与图片数据
  final Map<int, TopicExcerptData> _cache = {};
  static const int _maxCacheSize = 500;

  /// 在途异步拉取任务，避免同一话题并发重复请求
  final Map<int, Future<TopicExcerptData?>> _inFlight = {};

  /// 记录加载失败的话题 ID（15 秒内不重试，避免网络错误时死循环拉取）
  final Map<int, DateTime> _failedCooldown = {};
  static const Duration _failedCooldownDuration = Duration(seconds: 15);

  /// 最大并发网络请求数
  static const int _maxConcurrent = 4;
  int _currentRunning = 0;
  final List<Future<void> Function()> _pendingQueue = [];

  /// 在提取文字和图片前移除引用与未揭示内容，保留 spoiler 的隐藏语义。
  static dom.DocumentFragment _visibleContent(String raw) {
    final fragment = html.parseFragment(raw);
    for (final element in fragment.querySelectorAll(
      'aside.quote, .spoiler, script, style, template',
    )) {
      element.remove();
    }
    return fragment;
  }

  /// 清洗 Discourse 的 HTML/Cooked 内容为适合推特式信息流阅读的纯文本
  static String cleanExcerpt(String? raw) {
    if (raw == null || raw.isEmpty) return '';

    final buffer = StringBuffer();
    const blockTags = {
      'p',
      'div',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'tr',
      'li',
      'pre',
      'blockquote',
      'ul',
      'ol',
    };
    void append(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.data);
        return;
      }
      final tag = node is dom.Element ? node.localName : null;
      if (tag == 'br') {
        buffer.writeln();
        return;
      }
      if (blockTags.contains(tag)) buffer.writeln();
      if (tag == 'li') buffer.write('• ');
      for (final child in node.nodes) {
        append(child);
      }
      if (blockTags.contains(tag)) buffer.writeln();
    }

    append(_visibleContent(raw));

    var text = buffer
        .toString()
        .split('\n')
        .map((line) => line.trim())
        .join('\n');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    text = text.trim();

    // 限制单条摘要长度，防止极端长文消耗过多排版内存
    if (text.length > 2000) {
      text = '${text.substring(0, 2000)}...';
    }

    return text;
  }

  /// 从 Cooked/HTML 内容中提取媒体图片链接（最多 4 张，过滤 emoji 与小图标）
  static List<String> extractImages(String? rawHtml, {int maxCount = 4}) {
    if (rawHtml == null || rawHtml.isEmpty) return const [];
    final results = <String>[];

    for (final image in _visibleContent(rawHtml).querySelectorAll('img')) {
      final src = image.attributes['src'] ?? '';
      final classes = image.classes;

      // 过滤 emoji 表情、小图标、avatar、svg
      if (src.isEmpty ||
          classes.contains('emoji') ||
          classes.contains('avatar') ||
          classes.contains('site-icon') ||
          src.contains('/images/emoji/') ||
          (Uri.tryParse(src)?.path.toLowerCase().endsWith('.svg') ?? false)) {
        continue;
      }

      final resolved = UrlHelper.resolveUrlWithCdn(src);
      if (!results.contains(resolved)) {
        results.add(resolved);
        if (results.length >= maxCount) break;
      }
    }
    return results;
  }

  /// 完整首楼优先；缺少文字或图片时保留对应列表内容，列表数据不写入缓存。
  static TopicExcerptData? _withListData(
    TopicExcerptData? data, {
    String? fallbackRaw,
    String? fallbackImageUrl,
  }) {
    final cover = fallbackImageUrl?.trim();
    final listImages = <String>{
      if (cover != null && cover.isNotEmpty) UrlHelper.resolveUrlWithCdn(cover),
      ...extractImages(fallbackRaw),
    }.take(4).toList();
    final images = data != null && data.imageUrls.isNotEmpty
        ? data.imageUrls
        : listImages;
    final text = data != null && data.text.isNotEmpty
        ? data.text
        : cleanExcerpt(fallbackRaw);
    return text.isEmpty && images.isEmpty
        ? null
        : TopicExcerptData(text: text, imageUrls: images);
  }

  TopicExcerptData? getCached(
    int topicId, {
    String? fallbackRaw,
    String? fallbackImageUrl,
  }) {
    final cached = _cache.remove(topicId);
    if (cached != null) {
      _cache[topicId] = cached;
      return _withListData(
        cached,
        fallbackRaw: fallbackRaw,
        fallbackImageUrl: fallbackImageUrl,
      );
    }

    return _withListData(
      null,
      fallbackRaw: fallbackRaw,
      fallbackImageUrl: fallbackImageUrl,
    );
  }

  /// 异步获取话题正文摘要与图片：
  /// 1. 优先读取内存缓存
  /// 默认只使用已有内容；显式允许后才请求首楼，失败时保留列表摘要。
  Future<TopicExcerptData?> getOrFetchExcerpt(
    int topicId, {
    String? fallbackRaw,
    String? fallbackImageUrl,
    DiscourseService? service,
    bool allowFetch = false,
  }) async {
    final cached = _cache[topicId];
    TopicExcerptData? withFallback(TopicExcerptData? data) => _withListData(
      data,
      fallbackRaw: fallbackRaw,
      fallbackImageUrl: fallbackImageUrl,
    );
    if (cached != null) {
      return getCached(
        topicId,
        fallbackRaw: fallbackRaw,
        fallbackImageUrl: fallbackImageUrl,
      );
    }
    final fallback = withFallback(null);

    if (!allowFetch || service == null) return fallback;

    // 冷却检查：近期请求失败过则暂不重试
    final failedAt = _failedCooldown[topicId];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _failedCooldownDuration) {
      return fallback;
    }

    // 优先复用正在进行的网络任务
    if (_inFlight.containsKey(topicId)) {
      return withFallback(await _inFlight[topicId]);
    }

    final completer = Completer<TopicExcerptData?>();
    _inFlight[topicId] = completer.future;

    _scheduleFetch(() async {
      try {
        // 先检查是否有在途的预加载任务
        String? cooked =
            await (TopicPreviewPreloader.take(topicId) ??
                service.getTopicFirstPostCooked(topicId));

        if (cooked != null && cooked.isNotEmpty) {
          final cleaned = cleanExcerpt(cooked);
          final images = extractImages(cooked);
          if (cleaned.isNotEmpty || images.isNotEmpty) {
            final data = TopicExcerptData(text: cleaned, imageUrls: images);
            _putCache(topicId, data);
            _failedCooldown.remove(topicId);
            completer.complete(data);
            return;
          }
        }
        _failedCooldown[topicId] = DateTime.now();
        completer.complete(null);
      } catch (e) {
        _failedCooldown[topicId] = DateTime.now();
        completer.complete(null);
      } finally {
        _inFlight.remove(topicId);
      }
    });

    return withFallback(await completer.future);
  }

  void _scheduleFetch(Future<void> Function() task) {
    if (_currentRunning < _maxConcurrent) {
      _currentRunning++;
      _runTask(task);
    } else {
      _pendingQueue.add(task);
    }
  }

  Future<void> _runTask(Future<void> Function() task) async {
    try {
      await task();
    } finally {
      _currentRunning--;
      if (_pendingQueue.isNotEmpty && _currentRunning < _maxConcurrent) {
        final next = _pendingQueue.removeAt(0);
        _currentRunning++;
        _runTask(next);
      }
    }
  }

  void _putCache(int topicId, TopicExcerptData data) {
    _cache.remove(topicId);
    if (_cache.length >= _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    _cache[topicId] = data;
  }

  /// 清除缓存
  void clear() {
    _cache.clear();
    _inFlight.clear();
    _failedCooldown.clear();
  }
}
