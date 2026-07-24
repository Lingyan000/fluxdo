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
      // Polyfill:部分平台(Windows/Android 的 QuickJS 版本)未实现
      // Array.prototype.at(ES2022)。bundle 的 bbcode ruler 收尾逻辑
      // (`tokens.at(-1)?.meta`)依赖它——BBCode 闭合标签([/spoiler]/
      // [/color]/[/size]/[/u] 等)cook 时必经这条路径，缺了直接 TypeError:
      // not a function，cook 整体失败。V8/JavaScriptCore 已原生支持，
      // 这段判断为 no-op；只在缺失的 QuickJS 上补上。
      engine.evaluate('''
        if (!Array.prototype.at) {
          Array.prototype.at = function(n) {
            n = Math.trunc(n) || 0;
            if (n < 0) n += this.length;
            if (n < 0 || n >= this.length) return undefined;
            return this[n];
          };
        }
      ''');
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

  /// 客户端 cook 输出的 Dart 后处理（纯函数，可单测）。
  ///
  /// mention：客户端 cook 输出 `<span class="mention">@user</span>`（服务端
  /// 的 `<a class="mention">` 是 Ruby 后处理），fluxdo_render 只识别
  /// a.mention → 这里补成锚点，href 确定性拼 {baseUri}/u/{username}。
  /// code/pre 内的同形文本已被 cook 转义成 `&lt;span`，不会误伤。
  @visibleForTesting
  static String postProcessCooked(String cooked, {required String baseUri}) {
    final withMentions = cooked.replaceAllMapped(_mentionSpanRe, (m) {
      final username = m.group(1)!;
      return '<a class="mention" href="$baseUri/u/$username">@$username</a>';
    });
    return applyBbcodeSize(applyBbcodeColor(withMentions));
  }

  static final RegExp _mentionSpanRe = RegExp(
    r'<span class="mention">@([^<]+)</span>',
  );

  /// `[color=…]` / `[bgcolor=…]` → 带行内 style 的 span。
  ///
  /// **为什么在 cook 之后做**:着色 BBCode 由 discourse-bbcode-color 插件
  /// 提供,不在我们的 cook bundle 里(bundle 只打了 spoiler/details/math/
  /// poll/policy/checklist/local-dates/chat/footnote),所以 cook 把
  /// `[color=…]` 原样当普通文字吐回来。
  ///
  /// 也**不能改成 cook 之前**把它换成 `<span style="…">` —— Discourse 的
  /// HTML 消毒器会把 span 上的 style 剥掉(实测
  /// `<span style="color:#FF0000">红</span>` → `<span>红</span>`),
  /// 只有那个插件在注册语法时一并把它加进了消毒白名单。放在 cook 之后
  /// 消毒器已经跑完,加什么留什么。
  ///
  /// 阅读端本就认 `span[style]` 里的 color / background-color
  /// (paragraph_parser → ColoredRun),所以这里补完即可复用整条渲染链。
  ///
  /// 只处理**颜色值合法**的形态(`#rgb`/`#rrggbb`/CSS 颜色名),否则原样
  /// 留着 —— 免得把 `[color=不是颜色]` 这种普通文本也吞了。
  @visibleForTesting
  static String applyBbcodeColor(String html) {
    var out = html;
    for (var i = 0; i < _maxBbcodeColorDepth; i++) {
      final next = out.replaceAllMapped(_bbcodeColorRe, (m) {
        final tag = m.group(1)!.toLowerCase();
        // 颜色值可能已经被 cook 的 hashtag 特性包了标签:
        // `[color=#FF0000]` → `[color=<span class="hashtag-raw">#FF0000</span>]`
        // (`#FF0000` 长得像话题标签)。先剥标签再校验,否则带 `#` 的
        // 十六进制颜色**全都**会被判非法 —— 实测就是这个原因导致
        // `[color=#FF0000]` 不渲染,而 `[color=red]` 正常。
        final value = _stripTags(m.group(2)!).trim();
        if (!_isSafeCssColor(value)) return m.group(0)!;
        final prop = tag == 'bgcolor' ? 'background-color' : 'color';
        return '<span style="$prop:$value">${m.group(3)}</span>';
      });
      if (next == out) break; // 收敛(无嵌套可展开)
      out = next;
    }
    return out;
  }

  /// `[size=N]` → `<span style="font-size:N%">`。
  ///
  /// 与 [applyBbcodeColor] 同因同法:字号 BBCode 也由服务端插件提供,不在
  /// 我们的 cook bundle 里,cook 会把 `[size=N]` 原样当文字吐回来;而放在
  /// cook 之前替换又会被 HTML 消毒器把 style 剥掉 —— 只能在 cook 之后补。
  ///
  /// 映射取自服务端实测样本:`[size=0]` → `font-size:0%`(视觉隐藏)、
  /// `[size=150]` → `font-size:150%`,即 `N` ↔ `N%` 直给。
  /// 阅读端已认 `span[style]` 的 font-size(paragraph_parser → SizedRun),
  /// 补完即复用整条渲染链;两端一致才能过往返门禁。
  ///
  /// 只认纯数字值,`[size=大]` 这类原样留着当普通文本。
  @visibleForTesting
  static String applyBbcodeSize(String html) {
    var out = html;
    for (var i = 0; i < _maxBbcodeColorDepth; i++) {
      final next = out.replaceAllMapped(
        _bbcodeSizeRe,
        (m) => '<span style="font-size:${m.group(1)}%">${m.group(2)}</span>',
      );
      if (next == out) break; // 收敛
      out = next;
    }
    return out;
  }

  /// 最内层优先(内容里不再有同名开/闭标签),配合循环由内向外展开。
  static final RegExp _bbcodeSizeRe = RegExp(
    r'\[size=(\d{1,4})\]((?:(?!\[/?size)[\s\S])*)\[/size\]',
    caseSensitive: false,
  );

  /// 嵌套展开上限:`[bgcolor][color]…[/color][/bgcolor]` 这类套两层就够,
  /// 留点余量;有界防病态输入下的长循环。
  static const int _maxBbcodeColorDepth = 4;

  /// 最内层优先(内容里不再有同名开/闭标签),配合循环由内向外展开。
  ///
  /// 颜色值放宽到"可含 HTML 标签"(见上面 hashtag 的坑),长度给到 120
  /// 是因为包一层 `<span class="hashtag-raw">…</span>` 就要 40 多字符;
  /// 真正的合法性由 [_isSafeCssColor] 在剥标签之后把关。
  static final RegExp _bbcodeColorRe = RegExp(
    r'\[(color|bgcolor)=((?:[^\]<]|<[^>]*>){1,120}?)\]'
    r'((?:(?!\[/?(?:color|bgcolor))[\s\S])*)\[/\1\]',
    caseSensitive: false,
  );

  /// 剥掉字符串里的 HTML 标签,只留纯文本。
  static String _stripTags(String s) => s.replaceAll(RegExp(r'<[^>]*>'), '');

  /// 颜色值白名单:`#rgb` / `#rrggbb` / 纯字母 CSS 颜色名。
  /// 不放行 `url(...)`、`expression(...)` 等可注入形态。
  static bool _isSafeCssColor(String v) =>
      RegExp(r'^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').hasMatch(v) ||
      RegExp(r'^[a-zA-Z]{1,20}$').hasMatch(v);

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
