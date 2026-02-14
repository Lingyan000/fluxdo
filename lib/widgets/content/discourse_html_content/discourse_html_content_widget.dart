import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pangutext/pangutext.dart';
import '../../../constants.dart';
import '../../../models/topic.dart';
import '../../../providers/preferences_provider.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../services/emoji_handler.dart';
import '../../../utils/link_launcher.dart';
import 'discourse_widget_factory.dart';
import 'builders/quote_card_builder.dart';
import 'builders/onebox_card_builder.dart';
import 'builders/blockquote_builder.dart';
import 'builders/code_block_builder.dart';
import 'builders/spoiler_builder.dart';
import 'builders/table_builder.dart';
import 'builders/details_builder.dart';
import 'builders/footnote_builder.dart';
import 'builders/poll_builder.dart';
import 'builders/math_builder.dart';
import 'builders/chat_transcript_builder.dart';
import 'builders/iframe_builder.dart';
import 'builders/image_grid_builder.dart';
import 'builders/combined_decorator_overlay.dart';
import 'builders/mention_builder.dart';
import 'image_utils.dart';

/// Discourse HTML 内容渲染 Widget
/// 封装了所有自定义渲染逻辑
class DiscourseHtmlContent extends ConsumerStatefulWidget {
  final String html;
  final TextStyle? textStyle;
  final bool compact; // 紧凑模式：移除段落边距
  /// 内部链接点击回调 (linux.do 话题链接)
  final void Function(int topicId, String? topicSlug, int? postNumber)? onInternalLinkTap;
  /// 链接点击统计数据
  final List<LinkCount>? linkCounts;
  /// 外部传入的画廊图片列表（用于分块渲染时共享完整画廊）
  final List<String>? galleryImages;
  /// 是否启用选择区域（分块渲染时由外层统一控制）
  final bool enableSelectionArea;
  /// 被提及用户列表（含状态 emoji）
  final List<MentionedUser>? mentionedUsers;
  /// 完整 HTML（用于脚注匹配，分块渲染时传递）
  final String? fullHtml;
  /// 是否是分块渲染的子块（子块仍需注入点击数，与嵌套渲染区分）
  final bool isChunkChild;
  /// Post 对象（用于投票数据）
  final Post? post;
  /// 话题 ID（用于链接点击追踪）
  final int? topicId;
  /// 覆盖混排优化开关（null 表示使用全局设置）
  final bool? enablePanguSpacing;
  /// 截图模式：展开代码块、表格等滚动区域，确保完整显示
  final bool screenshotMode;

  const DiscourseHtmlContent({
    super.key,
    required this.html,
    this.textStyle,
    this.compact = false,
    this.onInternalLinkTap,
    this.linkCounts,
    this.galleryImages,
    this.enableSelectionArea = true,
    this.mentionedUsers,
    this.fullHtml,
    this.isChunkChild = false,
    this.post,
    this.topicId,
    this.enablePanguSpacing,
    this.screenshotMode = false,
  });

  @override
  ConsumerState<DiscourseHtmlContent> createState() => _DiscourseHtmlContentState();
}

class _DiscourseHtmlContentState extends ConsumerState<DiscourseHtmlContent> {
  late final DiscourseWidgetFactory _widgetFactory;
  late final GalleryInfo _galleryInfo;
  final Pangu _pangu = Pangu();

  /// 已揭示的内联 spoiler ID 集合
  final Set<String> _revealedSpoilers = {};

  @override
  void initState() {
    super.initState();
    // 优先使用外部传入的画廊图片列表，否则从 HTML 提取
    if (widget.galleryImages != null && widget.galleryImages!.isNotEmpty) {
      // 从外部传入的画廊列表构建 GalleryInfo
      _galleryInfo = GalleryInfo.fromImages(widget.galleryImages!);
    } else {
      // 从 HTML 提取画廊信息（包含缩略图到索引的映射）
      _galleryInfo = GalleryInfo.fromHtml(widget.html);
    }
    _widgetFactory = DiscourseWidgetFactory(
      context: context,
      galleryInfo: _galleryInfo,
    );
  }



  /// 预处理 HTML：注入用户状态 emoji、链接点击次数，添加内联元素 padding
  String _preprocessHtml(String html, bool enablePanguSpacing) {
    var processedHtml = html;

    // 0. 将相对路径转换为绝对路径（修复新发帖子图片不显示的问题）
    // Discourse 创建帖子返回的 cooked 中图片使用相对路径 src="/uploads/..."
    // 而已 rebake 的帖子使用完整 URL src="https://linux.do/uploads/..."
    processedHtml = processedHtml.replaceAllMapped(
      RegExp(r'(src|href)="(/[^"]+)"', caseSensitive: false),
      (match) {
        final attr = match.group(1)!;
        final path = match.group(2)!;
        // 只处理以 / 开头的相对路径，排除协议相对路径 //
        if (path.startsWith('//')) return match.group(0)!;
        return '$attr="${AppConstants.baseUrl}$path"';
      },
    );

    // 1. 注入用户状态 emoji 到 mention 链接
    if (widget.mentionedUsers != null && widget.mentionedUsers!.isNotEmpty) {
      for (final user in widget.mentionedUsers!) {
        if (user.statusEmoji != null) {
          final emojiUrl = EmojiHandler().getEmojiUrl(user.statusEmoji!);
          if (emojiUrl.isNotEmpty) {
            // 查找该用户的 mention 链接，在 </a> 前注入 emoji 图片
            final escapedUsername = RegExp.escape(user.username);
            final pattern = RegExp(
              '(<a[^>]*class="[^"]*mention[^"]*"[^>]*href="[^"]*\\/u\\/$escapedUsername"[^>]*>)(@[^<]*)(</a>)',
              caseSensitive: false,
            );
            processedHtml = processedHtml.replaceAllMapped(pattern, (match) {
              final openTag = match.group(1)!;
              final content = match.group(2)!;
              final closeTag = match.group(3)!;
              return '$openTag$content<img src="$emojiUrl" class="emoji mention-status" style="width:14px;height:14px;vertical-align:middle;margin-left:2px">$closeTag';
            });
          }
        }
      }
    }

    // 2. 给内联代码前后添加不换行空格（\u00A0）作为粘性内边距
    // 在 code 外部使用普通字体渲染（宽度可控），不换行特性确保和 code 粘在一起
    // 同时匹配 \u00A0 和 &nbsp;（innerHtml 会将 \u00A0 序列化为 &nbsp;）
    processedHtml = processedHtml.replaceAllMapped(
      RegExp('(?:\u00A0|&nbsp;)?<code>([^<]*)</code>(?:\u00A0|&nbsp;)?', caseSensitive: false),
      (match) {
        final content = match.group(1)!;
        return '\u00A0<code>$content</code>\u00A0';
      },
    );

    // 3. 给 mention 链接后面添加零宽度空格，确保右边圆角正确渲染
    processedHtml = processedHtml.replaceAllMapped(
      RegExp(r'(<a[^>]*class="[^"]*mention[^"]*"[^>]*>.*?</a>)'),
      (match) => '${match.group(1)}\u200B',
    );

    // 5. 注入链接点击数（顶层处理或分块子块处理，避免嵌套重复）
    // - fullHtml == null: 顶层渲染
    // - isChunkChild: 分块子块（需要注入，因为分块时顶层没有处理 HTML）
    if (widget.linkCounts != null && (widget.fullHtml == null || widget.isChunkChild)) {
      processedHtml = _injectClickCounts(processedHtml);
    }

    if (enablePanguSpacing) {
      processedHtml = _pangu.spacingText(processedHtml);
    }

    return processedHtml;
  }

  /// 注入链接点击数到 HTML
  String _injectClickCounts(String html) {
    if (widget.linkCounts == null) return html;

    var result = html;
    for (final lc in widget.linkCounts!) {
      if (lc.clicks <= 0) continue;

      // 匹配链接（排除已有点击数标记的、mention、hashtag 等特殊链接）
      // 使用 data-clicks 属性标记已处理
      final escapedUrl = RegExp.escape(lc.url);
      final pattern = RegExp(
        '(<a(?![^>]*data-clicks)[^>]*href="[^"]*$escapedUrl[^"]*"[^>]*>)(.*?)(</a>)(?!\\s*<span[^>]*class="[^"]*click-count)',
        caseSensitive: false,
      );

      final formattedCount = _formatClickCount(lc.clicks);
      result = result.replaceAllMapped(pattern, (match) {
        final openTag = match.group(1)!;
        final content = match.group(2)!;
        final closeTag = match.group(3)!;
        // 添加 data-clicks 属性防止重复处理，追加点击数 span
        final newOpenTag = openTag.replaceFirst('<a', '<a data-clicks="$formattedCount"');
        return '$newOpenTag$content$closeTag <span class="click-count">\u2009$formattedCount\u2009</span>';
      });
    }
    return result;
  }

  /// 追踪链接点击
  /// 仅当有 topicId 和 post 时才追踪
  void _trackClick(String url) {
    if (widget.topicId == null || widget.post == null) return;

    // 不追踪以下类型的链接：
    // 1. 用户链接 (/u/username) - 相当于 mention
    if (RegExp(r'(?:linux\.do)?/u/[^/?#]+').hasMatch(url)) return;
    // 2. 附件/上传链接
    if (url.contains('/uploads/')) return;
    // 3. Email 链接
    if (url.startsWith('mailto:')) return;
    // 4. 锚点链接
    if (url.startsWith('#')) return;

    DiscourseService().trackClick(
      url: url,
      postId: widget.post!.id,
      topicId: widget.topicId!,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final linkColor = theme.colorScheme.primary.toARGB32().toRadixString(16).substring(2);
    final enablePanguSpacing =
        widget.enablePanguSpacing ?? ref.watch(preferencesProvider).autoPanguSpacing;
    final processedHtml = _preprocessHtml(widget.html, enablePanguSpacing);

    final htmlWidget = HtmlWidget(
      processedHtml,
      textStyle: widget.textStyle,
      factoryBuilder: () => _widgetFactory,
      customWidgetBuilder: (element) => _buildCustomWidget(context, element),
      customStylesBuilder: (element) {
        final isDark = theme.brightness == Brightness.dark;

        // 检查元素是否在 spoiler 内
        bool isInSpoiler = false;
        var parent = element.parent;
        while (parent != null) {
          if (parent.classes.contains('spoiler') || parent.classes.contains('spoiled')) {
            isInSpoiler = true;
            break;
          }
          parent = parent.parent;
        }

        // 修复 Emoji 垂直居中问题
        if (element.classes.contains('emoji')) {
           return {'vertical-align': 'middle'};
        }

        // 内联代码样式：回归文档流，支持自然换行
        // 注意：padding 和 border-radius 会导致 WidgetSpan，只使用可内联的属性
        if (element.localName == 'code' && element.parent?.localName != 'pre') {
          return getInlineCodeStyles(isDark, isInSpoiler: isInSpoiler);
        }

        // Callout 标题内的链接继承标题颜色
        if (element.localName == 'a') {
          final parentClasses =
              (element.parent?.classes ?? const <String>[]).cast<String>();
          if (parentClasses.contains('callout-title')) {
            return {
              'color': 'inherit',
              'text-decoration': 'none',
            };
          }
        }

        // 紧凑模式下移除段落边距
        if (widget.compact && element.localName == 'p') {
          return {'margin': '0'};
        }
        // 优化链接样式
        if (element.localName == 'a') {
          return {
            'color': '#$linkColor',
            'text-decoration': 'none',
          };
        }
        // 无序列表样式
        if (element.localName == 'ul') {
          return {
            'padding-left': '20px',
            'margin': '8px 0',
          };
        }
        // 有序列表样式
        if (element.localName == 'ol') {
          return {
            'padding-left': '20px',
            'margin': '8px 0',
          };
        }
        // 列表项样式
        if (element.localName == 'li') {
          return {
            'margin': '4px 0',
            'line-height': '1.5',
          };
        }
        // 内联 spoiler：使用特殊 font-family 标记，让文本正常渲染但可被识别
        if (element.localName == 'span' &&
            (element.classes.contains('spoiler') || element.classes.contains('spoiled'))) {
          return getSpoilerStyles();
        }
        return {};
      },
      onTapUrl: (url) async {
        // 追踪链接点击（fire-and-forget）
        _trackClick(url);

        // 统一链接处理逻辑
        await launchContentLink(
          context,
          url,
          onInternalLinkTap: widget.onInternalLinkTap,
        );
        return true;
      },
    );

    // 用 CombinedDecoratorOverlay 包裹（合并处理内联代码背景和 spoiler 粒子效果）
    Widget result = CombinedDecoratorOverlay(
      revealedSpoilers: _revealedSpoilers,
      onReveal: (id) {
        setState(() {
          _revealedSpoilers.add(id);
        });
      },
      child: htmlWidget,
    );

    // 根据参数决定是否包裹 SelectionArea
    if (widget.enableSelectionArea) {
      return SelectionArea(child: result);
    }
    return result;
  }

  Widget? _buildCustomWidget(BuildContext context, dynamic element) {
    final theme = Theme.of(context);

    // 处理 iframe：统一使用 InAppWebView 渲染
    // flutter_widget_from_html 的实现全屏退出后高度异常
    if (element.localName == 'iframe') {
      final iframe = buildIframe(context: context, element: element);
      if (iframe != null) return iframe;
    }

    // 屏蔽 Discourse Lightbox 的元数据区域和图标
    if (element.classes.contains('meta') ||
        element.classes.contains('d-icon') ||
        element.localName == 'svg') {
      return const SizedBox.shrink();
    }

    // 用户提及链接 (a.mention)：直接 WidgetSpan 渲染
    if (element.localName == 'a' && element.classes.contains('mention')) {
      return buildMention(
        context: context,
        theme: theme,
        element: element,
        baseFontSize: widget.textStyle?.fontSize ?? 14.0,
      );
    }

    // 链接点击数 (span.click-count)：直接 WidgetSpan 渲染
    if (element.localName == 'span' && element.classes.contains('click-count')) {
      final count = element.text.trim();
      final isDark = theme.brightness == Brightness.dark;

      return InlineCustomWidget(
        child: buildClickCountWidget(
          count: count,
          isDark: isDark,
        ),
      );
    }

    // 内联代码：通过扫描方案渲染背景

    // HTML 构建器：用于嵌套渲染
    Widget htmlBuilder(String html, TextStyle? textStyle) {
      return DiscourseHtmlContent(
        html: html,
        compact: true,
        textStyle: textStyle,
        galleryImages: _galleryInfo.images,
        onInternalLinkTap: widget.onInternalLinkTap,
        post: widget.post,
        topicId: widget.topicId,
        linkCounts: widget.linkCounts,
        mentionedUsers: widget.mentionedUsers,
        enableSelectionArea: widget.enableSelectionArea,
        enablePanguSpacing: widget.enablePanguSpacing,
        screenshotMode: widget.screenshotMode,
      );
    }

    // 处理投票块 (div.poll)
    if (element.localName == 'div' && element.classes.contains('poll')) {
      if (widget.post != null) {
        return buildPoll(
          context: context,
          theme: theme,
          element: element,
          post: widget.post!,
        );
      }
      return const SizedBox.shrink();
    }

    // 处理 Discourse 图片网格 (div.d-image-grid)
    if (element.localName == 'div' && element.classes.contains('d-image-grid')) {
      return buildImageGrid(
        context: context,
        theme: theme,
        element: element,
        galleryInfo: _galleryInfo,
      );
    }

    // 处理 table：自定义渲染避免布局问题
    if (element.localName == 'table') {
      return buildTable(
        context: context,
        theme: theme,
        element: element,
        galleryImages: _galleryInfo.images,
        screenshotMode: widget.screenshotMode,
      );
    }

    // 处理 Discourse 回复引用块 (aside.quote)
    if (element.localName == 'aside' && element.classes.contains('quote')) {
      return buildQuoteCard(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
      );
    }

    // 处理 Discourse 链接卡片 (aside.onebox)
    if (element.localName == 'aside' && element.classes.contains('onebox')) {
      return buildOneboxCard(
        context: context,
        theme: theme,
        element: element,
        linkCounts: widget.linkCounts,
      );
    }

    // 处理 Discourse Chat Transcript (div.chat-transcript)
    if (isChatTranscript(element)) {
      return buildChatTranscript(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
      );
    }

    // 处理普通引用块 (可能是 Obsidian Callout)
    if (element.localName == 'blockquote') {
      return buildBlockquote(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
      );
    }

    // 处理代码块
    if (element.localName == 'pre') {
      final codeElements = element.getElementsByTagName('code');
      if (codeElements.isNotEmpty) {
        return buildCodeBlock(
          context: context,
          theme: theme,
          codeElement: codeElements.first,
          screenshotMode: widget.screenshotMode,
        );
      }
    }

    // 处理 Spoiler 隐藏内容
    if (element.classes.contains('spoiler') || element.classes.contains('spoiled')) {
      // span.spoiler：返回 null 让文本正常渲染（样式由 customStylesBuilder 设置）
      // 粒子效果由外层的 SpoilerOverlay 通过 RenderTree 扫描实现
      if (element.localName == 'span') {
        return null;
      }
      // div.spoiler 等块级元素使用块级方案
      final innerHtml = element.innerHtml as String;
      final spoilerId = 'block_spoiler_${innerHtml.hashCode}';
      final isRevealed = _revealedSpoilers.contains(spoilerId);

      return buildSpoiler(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
        textStyle: widget.textStyle,
        isRevealed: isRevealed,
        onReveal: () {
          setState(() {
            _revealedSpoilers.add(spoilerId);
          });
        },
      );
    }

    // 处理 details 折叠块
    if (element.localName == 'details') {
      return buildDetails(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
      );
    }

    // 处理脚注引用 (sup.footnote-ref)
    if (element.localName == 'sup' && element.classes.contains('footnote-ref')) {
      final footnoteRef = buildFootnoteRef(
        context: context,
        theme: theme,
        element: element,
        fullHtml: widget.fullHtml ?? widget.html,
        galleryImages: _galleryInfo.images,
      );
      return InlineCustomWidget(child: footnoteRef);
    }

    // 处理脚注分隔线 (.footnotes-sep) - 隐藏
    if (element.localName == 'hr' && element.classes.contains('footnotes-sep')) {
      return buildFootnotesSep();
    }

    // 处理脚注列表 (section.footnotes / ol.footnotes-list)
    if (element.localName == 'section' && element.classes.contains('footnotes')) {
      return buildFootnotesList(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
      );
    }
    if (element.localName == 'ol' && element.classes.contains('footnotes-list')) {
      return buildFootnotesList(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
      );
    }

    // 处理块级数学公式 (div.math)
    if (element.localName == 'div' && element.classes.contains('math')) {
      return buildMathBlock(
        context: context,
        theme: theme,
        element: element,
      );
    }

    // 处理行内数学公式 (span.math)
    if (element.localName == 'span' && element.classes.contains('math')) {
      return buildInlineMath(
        context: context,
        theme: theme,
        element: element,
      );
    }

    // 处理分割线
    if (element.localName == 'hr') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Container(
          height: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      );
    }

    // 带点击数的链接：点击数已通过 _injectClickCounts 注入为 span.click-count
    // 使用 CSS 样式渲染，回归文档流

    return null;
  }

  /// 格式化点击数
  String _formatClickCount(int count) {
    if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}k';
    }
    return count.toString();
  }
}
