import 'dart:async';
import 'package:flutter/foundation.dart';
import '../utils/url_helper.dart';
import 'discourse/discourse_service.dart';
import 'topic_preview_preloader.dart';

/// 话题正文摘要及媒体数据结构
class TopicExcerptData {
  final String text;
  final List<String> imageUrls;

  const TopicExcerptData({
    required this.text,
    this.imageUrls = const [],
  });

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

  /// HTML 实体解码表
  static final Map<String, String> _htmlEntities = {
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&lt;': '<',
    '&gt;': '>',
    '&amp;': '&',
    '&nbsp;': ' ',
    '&hellip;': '...',
    '&#x2F;': '/',
  };

  /// 清洗 Discourse 的 HTML/Cooked 内容为适合推特式信息流阅读的纯文本
  static String cleanExcerpt(String? raw) {
    if (raw == null || raw.isEmpty) return '';

    String text = raw;

    // 1. 去除引用块 <aside class="quote">...</aside>，避免摘要被大段引用占据
    text = text.replaceAll(RegExp(r'<aside[^>]*>[\s\S]*?<\/aside>', caseSensitive: false), '');

    // 2. 将段落、换行等结构标签转化为换行符
    text = text.replaceAll(RegExp(r'<br\s*\/?>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<\/(p|div|h[1-6]|tr)>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '• ');
    text = text.replaceAll(RegExp(r'<\/li>', caseSensitive: false), '\n');

    // 3. 去除所有剩余 HTML 标签
    text = text.replaceAll(RegExp(r'<[^>]*>'), '');

    // 4. 解码常见 HTML 实体
    _htmlEntities.forEach((entity, replacement) {
      text = text.replaceAll(entity, replacement);
    });

    // 5. 解码十进制数字实体 &#1234;
    text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
      final code = int.tryParse(match.group(1) ?? '');
      if (code != null && code > 0 && code < 0x10FFFF) {
        try {
          return String.fromCharCode(code);
        } catch (_) {}
      }
      return '';
    });

    // 6. 处理每行缩进和多余的连续换行（保留最多连续两个换行）
    final lines = text.split('\n');
    final cleanedLines = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      cleanedLines.add(trimmed);
    }

    text = cleanedLines.join('\n');
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

    // 匹配 <img> 标签
    final imgRegex = RegExp(r'''<img[^>]+src=["']([^"']+)["']''', caseSensitive: false);
    final matches = imgRegex.allMatches(rawHtml);
    for (final m in matches) {
      final fullTag = m.group(0) ?? '';
      final src = m.group(1) ?? '';

      // 过滤 emoji 表情、小图标、avatar、svg
      if (fullTag.contains('class="emoji"') ||
          fullTag.contains('class="avatar"') ||
          fullTag.contains('class="site-icon"') ||
          src.contains('/images/emoji/') ||
          src.endsWith('.svg')) {
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

  /// 同步读取缓存：如果已存在或 [fallbackRaw] 非空，直接返回清洗后的数据
  TopicExcerptData? getCached(int topicId, {String? fallbackRaw}) {
    final cached = _cache[topicId];
    if (cached != null) return cached;

    if (fallbackRaw != null && fallbackRaw.trim().isNotEmpty) {
      final cleaned = cleanExcerpt(fallbackRaw);
      final images = extractImages(fallbackRaw);
      if (cleaned.isNotEmpty || images.isNotEmpty) {
        final data = TopicExcerptData(text: cleaned, imageUrls: images);
        _putCache(topicId, data);
        return data;
      }
    }
    return null;
  }

  /// 异步获取话题正文摘要与图片：
  /// 1. 优先读取内存缓存
  /// 2. 其次清洗传入的 [fallbackRaw]
  /// 3. 若均无，则并发节流请求接口获取第一楼 cooked 内容并清洗
  Future<TopicExcerptData?> getOrFetchExcerpt(
    int topicId, {
    String? fallbackRaw,
    DiscourseService? service,
  }) async {
    final syncHit = getCached(topicId, fallbackRaw: fallbackRaw);
    if (syncHit != null) return syncHit;

    if (service == null) return null;

    // 冷却检查：近期请求失败过则暂不重试
    final failedAt = _failedCooldown[topicId];
    if (failedAt != null && DateTime.now().difference(failedAt) < _failedCooldownDuration) {
      return null;
    }

    // 优先复用正在进行的网络任务
    if (_inFlight.containsKey(topicId)) {
      return _inFlight[topicId];
    }

    final completer = Completer<TopicExcerptData?>();
    _inFlight[topicId] = completer.future;

    _scheduleFetch(() async {
      try {
        // 先检查是否有在途的预加载任务
        String? cooked = await (TopicPreviewPreloader.take(topicId) ??
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

    return completer.future;
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
