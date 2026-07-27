import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ImageRun;
import 'package:markdown/markdown.dart' as md;
import '../../services/discourse_cook_service.dart';
import '../../services/emoji_handler.dart';
import '../../constants.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../utils/url_helper.dart';

/// 官方 composer 的图片 markdown 正则(uploads.js IMAGE_MARKDOWN_REGEX
/// 逐字翻译):`![alt|WxH(, N%)(其余后缀)](upload://…)`,排除行内 code
/// 尾随反引号的近似(与 web 端同口径)。
final _imageMarkdownRegex = RegExp(
    r'!\[(.*?)\|(\d{1,4}x\d{1,4})(,\s*\d{1,3}%)?(.*?)\]\((upload://.*?)\)(?!(.*`))');

/// 预览缩放胶囊点击 → 改 raw 的 `, N%` 后缀(对齐官方
/// `_handleImageScaleButtonClick`:第 [ImageRun.previewImageIndex] 个
/// 正则命中整体替换)。定位失败(index 缺失/越界)返回 null 不动 raw。
String? applyImageScaleToRaw(String raw, ImageRun image, int scale) {
  final index = image.previewImageIndex;
  if (index == null || index < 0) return null;
  final matches = _imageMarkdownRegex.allMatches(raw).toList();
  if (index >= matches.length) return null;
  final m = matches[index];
  final replacement =
      '![${m[1]}|${m[2]}, $scale%${m[4]}](${m[5]})';
  if (raw.substring(m.start, m.end) == replacement) return null;
  return raw.replaceRange(m.start, m.end, replacement);
}

/// Markdown 预览组件
///
/// 首选链路：DiscourseCookService（app 内跑 Discourse 官方 markdown-it
/// cook bundle）产出与服务端 1:1 的 cooked HTML → FluxdoRender 渲染。
///
/// 降级链路（web 平台 / JS 引擎不可用 / cook 失败 / JS 结果未就绪的首帧）：
/// 沿用旧的 Dart 近似管线（markdown 包 + 手写预处理）。
///
/// 刷新策略：data 变化后 throttle（首次立即 cook，之后至多每 250ms 一次，
/// 末次变化必有 trailing cook）；期间继续显示上一次成功的 cooked
/// （AI 流式场景既不闪烁也不冻结），尚无结果时显示 Dart fallback。
class MarkdownBody extends StatefulWidget {
  final String data;

  /// 内部链接点击回调（话题链接）
  final void Function(int topicId, String? topicSlug, int? postNumber)?
  onInternalLinkTap;

  /// 图片缩放胶囊点击回调（编辑器预览场景传入；只读预览不传）。
  /// 可缩放图（客户端 cook 预览形态）出 100/75/50 胶囊，点击后宿主
  /// 按官方 IMAGE_MARKDOWN_REGEX 语义改 raw 的 `, N%` 后缀。
  final void Function(ImageRun image, int scale)? onImageScaleChanged;

  const MarkdownBody({
    super.key,
    required this.data,
    this.onInternalLinkTap,
    this.onImageScaleChanged,
  });

  @override
  State<MarkdownBody> createState() => _MarkdownBodyState();
}

class _MarkdownBodyState extends State<MarkdownBody> {
  static const _cookInterval = Duration(milliseconds: 250);

  /// 最近一次 JS cook 成功的结果及其对应的源文本
  String? _cooked;
  String? _cookedFor;

  /// Dart fallback 结果缓存（避免文本未变时每次 build 重算）
  String? _fallbackHtml;
  String? _fallbackFor;

  Timer? _pendingCook;
  DateTime? _lastCookStart;
  int _cookSeq = 0;

  @override
  void initState() {
    super.initState();
    // 兜底预热（编辑器入口已提前 warmUp，AI 总结等场景靠这里）
    DiscourseCookService().warmUp();
    _startCook();
  }

  @override
  void didUpdateWidget(MarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _scheduleCook();
    }
  }

  @override
  void dispose() {
    _pendingCook?.cancel();
    super.dispose();
  }

  /// throttle：已有排队 cook 时不重置计时（流式输入不会饿死 trailing），
  /// 距上次 cook 超过间隔则立即执行
  void _scheduleCook() {
    if (_pendingCook != null) return;
    final last = _lastCookStart;
    final elapsed = last == null
        ? _cookInterval
        : DateTime.now().difference(last);
    final wait = elapsed >= _cookInterval
        ? Duration.zero
        : _cookInterval - elapsed;
    _pendingCook = Timer(wait, () {
      _pendingCook = null;
      _startCook();
    });
  }

  Future<void> _startCook() async {
    final text = widget.data;
    if (_cookedFor == text) return;
    _lastCookStart = DateTime.now();
    final seq = ++_cookSeq;
    final cooked = await DiscourseCookService().cook(text);
    if (!mounted || seq != _cookSeq) return;
    // null（不可用/失败）→ 保持当前显示（fallback 或旧 cooked），不闪动
    if (cooked != null) {
      setState(() {
        _cooked = cooked;
        _cookedFor = text;
      });
      unawaited(_resolveOneboxes(text, cooked));
    }
  }

  /// 异步解析 onebox 占位（对齐 web 预览的 loadOneboxes）：
  /// 请求端点 → seed 进 JS 引擎缓存 → 有新结果时对同一文本重 cook 一次，
  /// 占位替换成卡片/标题。已请求过的 URL 由服务层去重，不会重复打点。
  Future<void> _resolveOneboxes(String text, String cooked) async {
    final service = DiscourseCookService();
    final seeded = await service.resolveOneboxes(cooked);
    if (!seeded || !mounted) return;
    // 期间文本已变则放弃：新文本的 cook 会自己再走一轮解析
    if (widget.data != text) return;
    final recooked = await service.cook(text);
    if (!mounted || recooked == null || widget.data != text) return;
    setState(() {
      _cooked = recooked;
      _cookedFor = text;
    });
  }

  @override
  Widget build(BuildContext context) {
    // JS cooked 可用即显示（可能对应略旧的文本，debounce 窗口内属预期）；
    // 完全没有 cooked 时用 Dart fallback 保证首帧有内容。
    final html = _cooked ?? _buildFallbackHtml(widget.data);

    return FluxdoRenderCallbacks.generic(
      heroTagNamespace: 'markdown_preview',
      onInternalLinkTap: widget.onInternalLinkTap,
      onImageScaleChanged: widget.onImageScaleChanged,
    ).render(
      cookedHtml: html,
      baseTextStyle: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(height: 1.5),
      selectionEnabled: false,
    );
  }

  // ---------------------------------------------------------------------
  // 以下为 Dart 近似 cook 管线（降级路径），逻辑与旧版 MarkdownBody 一致
  // ---------------------------------------------------------------------

  String _buildFallbackHtml(String data) {
    if (_fallbackFor == data && _fallbackHtml != null) {
      return _fallbackHtml!;
    }

    // 1. 处理 Emoji 替换 (将 :smile: 转为 <img>)
    var processedData = EmojiHandler().replaceEmojis(data);

    // 2. 预处理 @用户名 提及（转换为 HTML 链接）
    processedData = _processMentions(processedData);

    // 3. 预处理 Discourse 图片格式 (![alt|WxH](url) -> HTML img)
    processedData = _processDiscourseImages(processedData);

    // 3.5 确保标准 markdown 图片前后有空行，使其独占段落
    processedData = processedData.replaceAllMapped(
      RegExp(r'(?<!\n\n)(!\[[^\]]*\]\([^)]+\))'),
      (m) => '\n\n${m.group(1)!}',
    );
    processedData = processedData.replaceAllMapped(
      RegExp(r'(!\[[^\]]*\]\([^)]+\))(?!\n\n)'),
      (m) => '${m.group(1)!}\n\n',
    );
    processedData = processedData.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    processedData = processedData.trim();

    // 4. 预处理 [quote] 标记（转换为占位符，避免被 markdown 解析干扰）
    final quoteBlocks = <String, String>{};
    processedData = _processQuoteBlocks(processedData, quoteBlocks);

    // 5. 预处理 [spoiler] 标记（转换为占位符或行内 HTML）
    final spoilerBlocks = <String, String>{};
    processedData = _processSpoilerBlocks(processedData, spoilerBlocks);

    // 5. 预处理 [grid] 标记（转换为占位符，避免被 markdown 解析干扰）
    final gridBlocks = <String, String>{};
    processedData = _extractGridBlocks(processedData, gridBlocks);

    // 6. 将单个换行转换为硬换行，使预览换行行为符合用户直觉
    processedData = _convertSoftBreaks(processedData);

    // 7. 使用 GitHub Flavored Markdown 扩展集转换为 HTML
    var html = md.markdownToHtml(
      processedData,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );

    // 8. 后处理：将 grid 占位符替换回 div.d-image-grid 包裹的图片
    html = _restoreGridBlocks(html, gridBlocks);

    // 9. 后处理：将 spoiler 占位符替换回 div.spoiler
    html = _restoreSpoilerBlocks(html, spoilerBlocks);

    // 10. 后处理：将 quote 占位符替换回 aside.quote
    html = _restoreQuoteBlocks(html, quoteBlocks);

    _fallbackFor = data;
    _fallbackHtml = html;
    return html;
  }

  /// 将单个换行转换为硬换行（行尾添加两个空格）
  /// 标准 Markdown 把单个换行当作空格，但用户通常期望换行就是换行
  String _convertSoftBreaks(String text) {
    final lines = text.split('\n');
    final result = StringBuffer();
    bool inCodeBlock = false;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (line.trimLeft().startsWith('```')) {
        inCodeBlock = !inCodeBlock;
      }

      if (!inCodeBlock &&
          i < lines.length - 1 &&
          line.isNotEmpty &&
          lines[i + 1].isNotEmpty &&
          !line.endsWith('  ')) {
        result.write('$line  ');
      } else {
        result.write(line);
      }

      if (i < lines.length - 1) {
        result.write('\n');
      }
    }

    return result.toString();
  }

  /// 处理 Discourse 图片格式：![alt|widthxheight](url) -> <img src="" width="" height="" alt="">
  /// 标准 Markdown 包不识别竖线语法，需要手动转换
  String _processDiscourseImages(String text) {
    // 匹配 ![alt|WxH](url) 格式
    final discourseImageRegex = RegExp(
      r'!\[([^\]|]*)\|(\d+)x(\d+)\]\(([^)\s]+)\)',
    );

    return text.replaceAllMapped(discourseImageRegex, (match) {
      final alt = match.group(1) ?? '';
      final width = match.group(2)!;
      final height = match.group(3)!;
      var src = match.group(4) ?? '';

      // upload:// 短链接保留原始值，由下游 widget factory 异步解析
      if (!src.startsWith('upload://')) {
        src = UrlHelper.resolveUrlWithCdn(src);
      }

      return '\n\n<img src="$src" alt="$alt" width="$width" height="$height">\n\n';
    });
  }

  /// 预处理 [spoiler]...[/spoiler] 标记
  /// 块级 spoiler（内容含换行）使用占位符模式，行内 spoiler 直接替换为 HTML
  String _processSpoilerBlocks(String text, Map<String, String> spoilerBlocks) {
    final spoilerRegex = RegExp(
      r'\[spoiler\](.*?)\[/spoiler\]',
      multiLine: true,
      dotAll: true,
    );

    int index = 0;
    return text.replaceAllMapped(spoilerRegex, (match) {
      final content = match.group(1) ?? '';

      if (content.contains('\n')) {
        // 块级 spoiler：使用占位符，避免 markdown 解析器干扰
        final placeholder = '<!--SPOILER_PLACEHOLDER_$index-->';
        spoilerBlocks[placeholder] = content.trim();
        index++;
        return placeholder;
      } else {
        // 行内 spoiler：直接转为 HTML
        return '<span class="spoiler">${_escapeHtml(content)}</span>';
      }
    });
  }

  /// 后处理：将 spoiler 占位符替换为 div.spoiler
  String _restoreSpoilerBlocks(String html, Map<String, String> spoilerBlocks) {
    var result = html;

    for (final entry in spoilerBlocks.entries) {
      final placeholder = entry.key;
      final markdownContent = entry.value;

      // 将 spoiler 内的 markdown 转成 HTML
      final spoilerHtml = md.markdownToHtml(
        markdownContent,
        extensionSet: md.ExtensionSet.gitHubFlavored,
      );

      final replacement = '<div class="spoiler">$spoilerHtml</div>';

      // 替换占位符（可能被 <p> 包裹了）
      result = result.replaceAll('<p>$placeholder</p>', replacement);
      result = result.replaceAll(placeholder, replacement);
    }

    return result;
  }

  /// 转义 HTML 特殊字符
  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  /// 提取 [grid]...[/grid] 块，用唯一占位符替换
  /// 这样 markdown 解析器会正常处理其中的图片为 <img> 标签
  String _extractGridBlocks(String text, Map<String, String> gridBlocks) {
    final gridRegex = RegExp(
      r'\[grid\]\s*(.*?)\s*\[/grid\]',
      multiLine: true,
      dotAll: true,
    );

    int index = 0;
    return text.replaceAllMapped(gridRegex, (match) {
      final content = match.group(1) ?? '';
      final placeholder = '<!--GRID_PLACEHOLDER_$index-->';
      gridBlocks[placeholder] = content;
      index++;
      return placeholder;
    });
  }

  /// 后处理：将 grid 占位符替换为 div.d-image-grid 包裹的图片
  String _restoreGridBlocks(String html, Map<String, String> gridBlocks) {
    var result = html;

    for (final entry in gridBlocks.entries) {
      final placeholder = entry.key;
      var markdownContent = entry.value;

      // 预处理 Discourse 图片格式（grid 内也可能包含 ![alt|WxH](url)）
      markdownContent = _processDiscourseImages(markdownContent);

      // 将 grid 内的 markdown 图片转成 HTML
      var gridHtml = md.markdownToHtml(
        markdownContent,
        extensionSet: md.ExtensionSet.gitHubFlavored,
      );

      // 移除 markdown 生成的 <p> 标签包裹，只保留 <img> 标签
      gridHtml = gridHtml.replaceAll(RegExp(r'</?p>'), '');

      // 用 d-image-grid div 包裹
      final replacement = '<div class="d-image-grid">$gridHtml</div>';

      // 替换占位符（可能被 <p> 包裹了）
      result = result.replaceAll('<p>$placeholder</p>', replacement);
      result = result.replaceAll(placeholder, replacement);
    }

    return result;
  }

  /// 预处理 [quote="username, post:N, topic:T"]...[/quote] 标记
  /// 将其替换为占位符，避免被 markdown 解析器干扰
  String _processQuoteBlocks(String text, Map<String, String> quoteBlocks) {
    final quoteRegex = RegExp(
      r'\[quote(?:="([^"]*)")?\](.*?)\[/quote\]',
      multiLine: true,
      dotAll: true,
    );

    int index = 0;
    return text.replaceAllMapped(quoteRegex, (match) {
      final attrs = match.group(1) ?? '';
      final content = match.group(2) ?? '';
      final placeholder = '<!--QUOTE_PLACEHOLDER_$index-->';
      quoteBlocks[placeholder] = '$attrs\n$content';
      index++;
      return placeholder;
    });
  }

  /// 后处理：将 quote 占位符替换为 aside.quote HTML
  String _restoreQuoteBlocks(String html, Map<String, String> quoteBlocks) {
    var result = html;

    for (final entry in quoteBlocks.entries) {
      final placeholder = entry.key;
      final raw = entry.value;
      final firstNewline = raw.indexOf('\n');
      final attrs = firstNewline >= 0 ? raw.substring(0, firstNewline) : '';
      final markdownContent = firstNewline >= 0
          ? raw.substring(firstNewline + 1)
          : raw;

      // 解析属性
      String? username;
      String? displayName;
      String? post;
      String? topic;
      if (attrs.isNotEmpty) {
        // 格式: "displayName, post:N, topic:T, username:realUsername"
        // 首字段是显示名(昵称),真实用户名优先取 username: 参数——没有
        // 这个参数(老格式/外部来源)才退回首字段当用户名用。显示名本身
        // 可能含逗号被 split 打散,与官方解析(features/quotes.js)一致地
        // 取 post: 之前的全部片段拼回。
        final parts = attrs.split(',').map((s) => s.trim()).toList();
        for (final part in parts.skip(1)) {
          if (part.startsWith('post:')) {
            post = part.substring(5);
          } else if (part.startsWith('topic:')) {
            topic = part.substring(6);
          } else if (part.startsWith('username:')) {
            username = part.substring(9);
          }
        }
        final postIdx = parts.indexWhere((p) => p.startsWith('post:'));
        final first = (postIdx == -1 ? parts.take(1) : parts.take(postIdx))
            .join(', ');
        if (first.isNotEmpty) {
          if (username == null) {
            username = first;
          } else if (first != username) {
            displayName = first;
          }
        }
      }

      // 将引用内的 markdown 转成 HTML
      final quoteHtml = md.markdownToHtml(
        markdownContent.trim(),
        extensionSet: md.ExtensionSet.gitHubFlavored,
      );

      // 构建 aside.quote HTML（与 Discourse 的格式一致；官方 cooked 里
      // 显示名≠用户名时带 data-display-name,fluxdo_render 解析端会消费）
      final dataAttrs = StringBuffer();
      if (username != null) dataAttrs.write(' data-username="$username"');
      if (displayName != null) {
        dataAttrs.write(' data-display-name="$displayName"');
      }
      if (post != null) dataAttrs.write(' data-post="$post"');
      if (topic != null) dataAttrs.write(' data-topic="$topic"');

      final replacement =
          '<aside class="quote"$dataAttrs>'
          '<blockquote>$quoteHtml</blockquote>'
          '</aside>';

      result = result.replaceAll('<p>$placeholder</p>', replacement);
      result = result.replaceAll(placeholder, replacement);
    }

    return result;
  }

  /// 将 @用户名 转换为 HTML 链接
  /// 匹配规则：@ 后面跟字母、数字、下划线、连字符
  String _processMentions(String text) {
    // 匹配 @用户名，但不匹配邮箱中的 @
    // 要求 @ 前面是空白/开头，后面是合法的用户名字符
    final mentionRegex = RegExp(
      r'(?<=^|\s)@([\w_-]+)(?=\s|$|[,.!?;:]|\))',
      multiLine: true,
    );

    return text.replaceAllMapped(mentionRegex, (match) {
      final username = match.group(1)!;
      // 生成与 Discourse 一致的 mention 链接格式
      return '<a class="mention" href="${AppConstants.baseUrl}/u/$username">@$username</a>';
    });
  }
}
