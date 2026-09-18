import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'preloaded_data_service.dart';
import 'discourse/discourse_service.dart';
import 'cook/cook_js_engine_stub.dart'
    if (dart.library.io) 'cook/cook_js_engine_io.dart';

/// Discourse 1:1 cook 服务。
///
/// 在 app 内跑 Discourse 官方 markdown-it cook 管线（与服务端 MiniRacer
/// 同一份 JS，由 tools/discourse-cook-bundle 打成 assets/cook/discourse-cook.js），
/// 把 raw markdown cook 成与服务端一致的 cooked HTML，供编辑器预览直接
/// 喂 FluxdoRender。
///
/// 失败面（web 平台 / bundle eval 失败 / 站点数据未加载 / JS 抛错）统一
/// 返回 null，由调用方降级到旧的 Dart 近似预览管线。
class DiscourseCookService {
  static final DiscourseCookService _instance =
      DiscourseCookService._internal();
  factory DiscourseCookService() => _instance;
  DiscourseCookService._internal();

  CookJsEngine? _engine;
  Future<bool>? _initFuture;
  bool _unavailable = false;

  /// 预热：编辑器打开时 fire-and-forget 调用，把「读 551K bundle + eval +
  /// init 站点数据」的开销挪到用户切预览之前。
  void warmUp() {
    unawaited(ensureInitialized());
  }

  /// 幂等初始化。失败后置为不可用（本次进程内不再重试 eval 大 bundle，
  /// 站点数据缺失导致的失败除外——那种情况保留重试机会）。
  Future<bool> ensureInitialized() {
    if (_unavailable) return Future.value(false);
    return _initFuture ??= _initialize().then((ok) {
      if (!ok) _initFuture = null; // 允许下次重试（如站点数据晚到）
      return ok;
    });
  }

  Future<bool> _initialize() async {
    if (!cookJsSupported) {
      _unavailable = true;
      return false;
    }

    // 1. 站点数据（cook 需要 siteSettings/site/customEmoji/baseUri）
    final preloaded = PreloadedDataService();
    Map<String, dynamic>? siteSettings;
    Map<String, dynamic>? site;
    try {
      await preloaded.ensureLoaded();
      siteSettings = preloaded.siteSettingsSync;
      site = await preloaded.getSite();
    } catch (e) {
      debugPrint('[DiscourseCook] 站点数据未就绪，暂不初始化: $e');
      return false;
    }
    if (siteSettings == null || site == null) {
      debugPrint('[DiscourseCook] siteSettings/site 为空，暂不初始化');
      return false;
    }

    // 2. eval bundle（一次性大开销，放 warmUp 阶段做）
    try {
      final bundleJs = await rootBundle.loadString(
        'assets/cook/discourse-cook.js',
      );
      final engine = CookJsEngine();
      String? evalError;
      engine.evaluate(bundleJs, onError: (e) => evalError = e);
      if (evalError != null) {
        debugPrint('[DiscourseCook] bundle eval 失败: $evalError');
        _unavailable = true;
        return false;
      }

      // 3. 注入站点数据建 engine
      final initJson = jsonEncode({
        'baseUri': preloaded.baseUri,
        'siteSettings': siteSettings,
        'site': {
          'censored_regexp': site['censored_regexp'],
          'watched_words_replace': site['watched_words_replace'],
          'watched_words_link': site['watched_words_link'],
          'custom_emoji_translation': site['custom_emoji_translation'],
          'denied_emojis': site['denied_emojis'],
          'markdown_additional_options': site['markdown_additional_options'],
          'hashtag_configurations': site['hashtag_configurations'],
          'hashtag_icons': site['hashtag_icons'],
          'categories': site['categories'],
        },
        'customEmoji': preloaded.customEmoji,
        'tagNames': _extractTagNames(site),
      });
      String? initError;
      final initResult = engine.evaluate(
        '__fluxdoCook.init(${jsonEncode(initJson)})',
        onError: (e) => initError = e,
      );
      if (initResult != 'ok') {
        debugPrint('[DiscourseCook] init 失败: ${initError ?? initResult}');
        _unavailable = true;
        return false;
      }

      _engine = engine;
      debugPrint('[DiscourseCook] 初始化完成');
      return true;
    } catch (e) {
      debugPrint('[DiscourseCook] 初始化异常: $e');
      _unavailable = true;
      return false;
    }
  }

  /// top_tags 兼容新旧格式（对齐 PreloadedDataService.getTopTags）
  static List<String> _extractTagNames(Map<String, dynamic> site) {
    final topTags = site['top_tags'] as List?;
    if (topTags == null) return const [];
    return topTags
        .map((t) => t is Map<String, dynamic> ? (t['name'] as String? ?? '') : t.toString())
        .where((name) => name.isNotEmpty)
        .toList();
  }

  /// cook raw markdown → cooked HTML。任何失败返回 null（调用方降级）。
  Future<String?> cook(String raw) async {
    if (raw.trim().isEmpty) return '';
    if (!await ensureInitialized()) return null;
    final engine = _engine;
    if (engine == null) return null;

    String? cookError;
    final cooked = engine.evaluate(
      '__fluxdoCook.cook(${jsonEncode(raw)})',
      onError: (e) => cookError = e,
    );
    if (cooked == null) {
      debugPrint('[DiscourseCook] cook 失败: $cookError');
      return null;
    }
    return postProcessCooked(cooked, baseUri: PreloadedDataService().baseUri);
  }

  /// 编辑器原文导入：官方独立引擎的版本化 token DTO，不经过 HTML。
  /// 失败返回 null；日志只包含阶段，不记录用户原文或 JS 异常正文。
  Future<Map<String, dynamic>?> parseForEditor(String raw) async {
    try {
      if (!await ensureInitialized()) return null;
      var failed = false;
      final result = _engine?.evaluate(
        '__fluxdoCook.parseForEditor(${jsonEncode(raw)})',
        onError: (_) => failed = true,
      );
      if (failed || result == null) return null;
      final data = jsonDecode(result);
      if (data is! Map<String, dynamic> ||
          data['version'] != 1 ||
          data['tokens'] is! List ||
          !(data['tokens'] as List).every(_isEditorToken)) {
        debugPrint('[DiscourseCook] 编辑 token DTO 无效');
        return null;
      }
      return data;
    } catch (_) {
      debugPrint('[DiscourseCook] 编辑 token 解析失败');
      return null;
    }
  }

  static bool _isEditorToken(dynamic value, [int depth = 0]) {
    if (depth >= 256 || value is! Map<String, dynamic>) return false;
    const fields = [
      'type', 'tag', 'nesting', 'attrs', 'content', 'markup', 'info',
      'children', 'meta', 'map', 'block', 'hidden',
    ];
    if (!fields.every(value.containsKey)) return false;
    for (final key in ['type', 'tag', 'content', 'markup', 'info']) {
      if (value[key] is! String) return false;
    }
    if (value['nesting'] is! int ||
        !const [-1, 0, 1].contains(value['nesting']) ||
        value['block'] is! bool || value['hidden'] is! bool) {
      return false;
    }
    final attrs = value['attrs'];
    if (attrs != null && (attrs is! List || !attrs.every((pair) =>
        pair is List && pair.length == 2 && pair[0] is String &&
        (pair[1] is String || pair[1] is num || pair[1] is bool)))) {
      return false;
    }
    final map = value['map'];
    if (map != null && (map is! List || map.length != 2 ||
        map[0] is! int || map[1] is! int ||
        map[0] < 0 || map[1] < map[0])) {
      return false;
    }
    final children = value['children'];
    return children == null || (children is List &&
        children.every((child) => _isEditorToken(child, depth + 1)));
  }

  /// 客户端 cook 输出的 Dart 后处理（纯函数，可单测）。
  ///
  /// mention：客户端 cook 输出 `<span class="mention">@user</span>`（服务端
  /// 的 `<a class="mention">` 是 Ruby 后处理），fluxdo_render 只识别
  /// a.mention → 这里补成锚点，href 确定性拼 {baseUri}/u/{username}。
  /// code/pre 内的同形文本已被 cook 转义成 `&lt;span`，不会误伤。
  @visibleForTesting
  static String postProcessCooked(String cooked, {required String baseUri}) {
    return cooked.replaceAllMapped(_mentionSpanRe, (m) {
      final username = m.group(1)!;
      return '<a class="mention" href="$baseUri/u/$username">@$username</a>';
    });
  }

  static final RegExp _mentionSpanRe = RegExp(
    r'<span class="mention">@([^<]+)</span>',
  );

  // -------------------------------------------------------------------
  // onebox 异步解析（对齐 web composer 预览的 loadOneboxes /
  // applyInlineOneboxes：cook 先输出占位 → 请求端点 → seed 进 JS 引擎
  // 的 oneboxer 缓存 → 重 cook 时占位替换成卡片/标题）
  // -------------------------------------------------------------------

  /// 已请求过的 URL（成功已 seed / 失败不重试），进程级
  final Set<String> _oneboxAttempted = {};
  final Set<String> _inlineOneboxAttempted = {};

  /// 解析 [cooked] 中的未完成 onebox 占位。
  ///
  /// 有任何新结果 seed 进引擎时返回 true（调用方应重 cook 刷新预览）；
  /// 无占位/全部请求过/全部失败返回 false。块级 onebox 串行请求
  /// （服务端限制每用户同时只允许 1 个预览）；行内每批 ≤10。
  Future<bool> resolveOneboxes(String cooked) async {
    final engine = _engine;
    if (engine == null) return false;

    final targets = extractOneboxTargets(cooked);
    var seeded = false;
    final service = DiscourseService();

    // 块级：串行
    for (final url in targets.blockUrls) {
      if (!_oneboxAttempted.add(url)) continue;
      final html = await service.fetchOneboxPreview(url);
      if (html == null) continue;
      String? err;
      engine.evaluate(
        '__fluxdoCook.seedOnebox(${jsonEncode(url)}, ${jsonEncode(html)})',
        onError: (e) => err = e,
      );
      if (err == null) {
        seeded = true;
      } else {
        debugPrint('[DiscourseCook] seedOnebox 失败: $err');
      }
    }

    // 行内：分批
    final pendingInline = targets.inlineUrls
        .where(_inlineOneboxAttempted.add)
        .toList();
    for (var i = 0; i < pendingInline.length; i += 10) {
      final batch = pendingInline.sublist(
        i,
        i + 10 > pendingInline.length ? pendingInline.length : i + 10,
      );
      final boxes = await service.fetchInlineOneboxes(batch);
      for (final entry in boxes.entries) {
        String? err;
        engine.evaluate(
          '__fluxdoCook.seedInlineOnebox(${jsonEncode(entry.key)}, '
          '${jsonEncode(entry.value.title)}, '
          '${jsonEncode(entry.value.cssClass)})',
          onError: (e) => err = e,
        );
        if (err == null) {
          seeded = true;
        } else {
          debugPrint('[DiscourseCook] seedInlineOnebox 失败: $err');
        }
      }
    }

    return seeded;
  }

  /// 从 cooked HTML 提取待解析的 onebox 链接（纯函数，可单测）。
  ///
  /// 块级占位：`<a class="onebox">`（cook 时无缓存的裸链接独行）；
  /// 行内占位：`<a class="inline-onebox-loading">`。class 按空白拆 token
  /// 精确匹配，避免 `inline-onebox` 误入块级组。href 做 HTML 实体解码
  /// （引擎缓存键是未转义 URL）。
  @visibleForTesting
  static ({List<String> blockUrls, List<String> inlineUrls})
  extractOneboxTargets(String cooked) {
    final blockUrls = <String>[];
    final inlineUrls = <String>[];
    for (final m in _anchorTagRe.allMatches(cooked)) {
      final attrs = m.group(1)!;
      final classAttr = _classAttrRe.firstMatch(attrs)?.group(1);
      if (classAttr == null) continue;
      final classes = classAttr.split(RegExp(r'\s+'));
      final href = _hrefAttrRe.firstMatch(attrs)?.group(1);
      if (href == null || href.isEmpty) continue;
      final url = _unescapeHtml(href);
      if (classes.contains('onebox')) {
        if (!blockUrls.contains(url)) blockUrls.add(url);
      } else if (classes.contains('inline-onebox-loading')) {
        if (!inlineUrls.contains(url)) inlineUrls.add(url);
      }
    }
    return (blockUrls: blockUrls, inlineUrls: inlineUrls);
  }

  static final RegExp _anchorTagRe = RegExp(r'<a\b([^>]*)>');
  static final RegExp _classAttrRe = RegExp(r'class="([^"]*)"');
  static final RegExp _hrefAttrRe = RegExp(r'href="([^"]*)"');

  static String _unescapeHtml(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }
}
