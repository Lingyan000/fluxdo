import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart' show ZLibEncoder;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:fluxdo_render/editor.dart' show EditorImageScaleBar;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:jovial_svg/jovial_svg.dart';
import 'package:popover/popover.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import '../pages/image_viewer_page.dart';
import '../pages/mermaid_viewer_page.dart';
import '../pages/user_profile_page.dart';
import '../pages/topic_detail_page/topic_detail_page.dart';
import '../models/topic.dart' show Post, MentionedUser, LinkCount;
import '../providers/download_provider.dart';
import '../services/discourse/discourse_service.dart';
import '../services/discourse_cache_manager.dart';
import '../services/emoji_handler.dart';
import '../services/highlighter_service.dart';
import '../services/media_compat_service.dart';
import '../services/toast_service.dart';
import '../utils/discourse_url_parser.dart';
import '../utils/link_launcher.dart';
import '../utils/svg_utils.dart';
import '../utils/url_helper.dart';
import '../widgets/common/image_context_menu.dart';
import '../widgets/common/smart_avatar.dart';
import '../widgets/post/quote_image_scope.dart';
import '../widgets/content/animated_svg_view.dart';
import '../widgets/content/audio/discourse_audio_player.dart';
import '../widgets/content/svg_view.dart';
import '../widgets/content/discourse_html_content/builders/iframe_builder.dart'
    show IframeWidget, IframeAttributes;
import '../widgets/content/discourse_html_content/builders/image_carousel_builder.dart'
    as legacy_carousel;
import '../widgets/content/discourse_html_content/builders/image_grid_builder.dart'
    show GridImageData;
import '../widgets/content/discourse_html_content/builders/lazy_video_builder.dart'
    as legacy_video;
import '../widgets/content/discourse_html_content/builders/local_date_builder.dart'
    as legacy_local_date;
import '../widgets/content/discourse_html_content/builders/onebox_card_builder.dart';
import '../widgets/content/discourse_html_content/builders/policy_builder.dart'
    as legacy_policy;
import '../widgets/content/discourse_html_content/builders/poll_builder.dart'
    as legacy_poll;
import '../widgets/content/discourse_html_content/builders/chat_transcript_builder.dart'
    as legacy_chat;
import '../widgets/content/discourse_html_content/builders/video_builder.dart';
import '../widgets/content/discourse_html_content/image_utils.dart';
import '../widgets/content/discourse_html_content/lazy_image.dart';
import '../widgets/content/lazy_load_scope.dart';

/// 把 fluxdo_render 的全部 callback 一次性创建好,给 FluxdoRender 用。
///
/// 这是主项目侧的"接入层" —— 子包不依赖任何主项目 service,所有真实
/// 体系(emojiImageProvider / SmartAvatar / DiscourseImageUtils.openViewer /
/// HighlighterService / UserProfilePage 路由 / launchContentLink 等)
/// 都在这里组装。
///
/// 两个入口:
/// - [FluxdoRenderCallbacks.forPost]:帖子正文场景,有完整 Post 上下文
///   (画廊左右切 / 图片引用菜单 / 链接点击追踪 / policy/poll 交互)。
/// - [FluxdoRenderCallbacks.generic]:非正文场景(用户卡 bio / 回复预览 /
///   徽章 / 分享卡 等),无 Post,按需降级(见该 factory 文档)。
///
/// 不依赖 Post 的 builder(emoji/mention/code/avatar/math/svg/video/audio/
/// download/iframe/localDate/imageGrid + footnote/chat)抽成共享 static,
/// 两个入口复用;依赖 Post 的(link/image/lazyVideo/onebox/policy/poll)
/// 各自组装或降级。
///
/// 用法:
/// ```dart
/// final callbacks = FluxdoRenderCallbacks.forPost(post: post, topicId: id);
/// return callbacks.render(cookedHtml: post.cooked, baseTextStyle: style);
/// ```
class FluxdoRenderCallbacks {
  FluxdoRenderCallbacks({
    required this.linkHandler,
    required this.emojiImageBuilder,
    required this.mentionTapHandler,
    required this.imageContentBuilder,
    required this.codeBlockHighlighter,
    required this.codeBlockBuilder,
    required this.quoteAvatarBuilder,
    required this.footnoteTapHandler,
    required this.lazyVideoBuilder,
    required this.iframeBuilder,
    required this.localDateBuilder,
    required this.mathBlockBuilder,
    required this.mathInlineBuilder,
    required this.oneboxBuilder,
    required this.imageGridBuilder,
    required this.policyBuilder,
    required this.pollBuilder,
    required this.chatTranscriptBuilder,
    required this.svgBuilder,
    required this.videoBuilder,
    required this.audioBuilder,
    required this.onDownloadAttachment,
  });

  final LinkActionHandler linkHandler;
  final EmojiImageBuilder emojiImageBuilder;
  final MentionTapHandler mentionTapHandler;
  final ImageContentBuilder imageContentBuilder;
  final CodeBlockHighlighter codeBlockHighlighter;
  final CodeBlockBuilder codeBlockBuilder;
  final QuoteAvatarBuilder quoteAvatarBuilder;
  final FootnoteTapHandler footnoteTapHandler;
  final LazyVideoBuilder lazyVideoBuilder;
  final IframeBuilder iframeBuilder;
  final LocalDateBuilder localDateBuilder;
  final MathBlockBuilder mathBlockBuilder;
  final MathInlineBuilder mathInlineBuilder;
  final OneboxBuilder oneboxBuilder;
  final ImageGridBuilder imageGridBuilder;
  final PolicyBuilder policyBuilder;
  final PollBuilder pollBuilder;
  final ChatTranscriptBuilder chatTranscriptBuilder;
  final SvgBuilder svgBuilder;
  final VideoBuilder videoBuilder;
  final AudioBuilder audioBuilder;
  final AttachmentDownloadHandler onDownloadAttachment;

  /// 把本组 callback 应用到一个 [FluxdoRender]。
  ///
  /// 主项目所有渲染场景的统一出口:正文 / 用户卡 bio / 回复预览 / 分享卡 等
  /// 只需 `callbacks.render(cookedHtml: html, baseTextStyle: style)`,不用再
  /// 逐字段展开 21 个 builder。[selectionEnabled] 默认 true;只读预览传 false。
  FluxdoRender render({
    required String cookedHtml,
    Key? key,
    TextStyle? baseTextStyle,
    bool selectionEnabled = true,
    bool compact = false,
    bool screenshotMode = false,
    List<BlockNode>? parsedNodes,
    String? footnotesHtml,
    int imageIndexOffset = 0,
    Object? selectionScopeId,
    int chunkIndex = 0,
    bool trimTopMargin = false,
    bool trimBottomMargin = false,
    QuoteRequestCallback? onQuoteRequest,
    QuoteRequestCallback? onCopyQuoteRequest,
    CopyToastCallback? onCopyToast,
  }) {
    return FluxdoRender(
      key: key,
      cookedHtml: cookedHtml,
      parsedNodes: parsedNodes,
      baseTextStyle: baseTextStyle,
      selectionEnabled: selectionEnabled,
      compact: compact,
      screenshotMode: screenshotMode,
      footnotesHtml: footnotesHtml,
      imageIndexOffset: imageIndexOffset,
      selectionScopeId: selectionScopeId,
      chunkIndex: chunkIndex,
      trimTopMargin: trimTopMargin,
      trimBottomMargin: trimBottomMargin,
      onQuoteRequest: onQuoteRequest,
      onCopyQuoteRequest: onCopyQuoteRequest,
      onCopyToast: onCopyToast,
      linkHandler: linkHandler,
      emojiImageBuilder: emojiImageBuilder,
      mentionTapHandler: mentionTapHandler,
      imageContentBuilder: imageContentBuilder,
      codeBlockHighlighter: codeBlockHighlighter,
      codeBlockBuilder: codeBlockBuilder,
      quoteAvatarBuilder: quoteAvatarBuilder,
      oneboxBuilder: oneboxBuilder,
      imageGridBuilder: imageGridBuilder,
      footnoteTapHandler: footnoteTapHandler,
      lazyVideoBuilder: lazyVideoBuilder,
      iframeBuilder: iframeBuilder,
      videoBuilder: videoBuilder,
      audioBuilder: audioBuilder,
      localDateBuilder: localDateBuilder,
      policyBuilder: policyBuilder,
      pollBuilder: pollBuilder,
      chatTranscriptBuilder: chatTranscriptBuilder,
      mathBlockBuilder: mathBlockBuilder,
      mathInlineBuilder: mathInlineBuilder,
      svgBuilder: svgBuilder,
      onDownloadAttachment: onDownloadAttachment,
    );
  }

  /// 渲染前预处理 cooked —— 把 legacy 渲染前动态注入的内容补进 HTML,
  /// 让新引擎 FluxdoRender(接收原始 post.cooked)也能解析渲染。
  ///
  /// 注入两类(对齐 legacy `_preprocessHtml` / `_injectClickCounts`):
  /// 1. **mention 状态 emoji**:原始 cooked 的 mention 链接不含状态 emoji,
  ///    legacy 用 post.mentionedUsers[].statusEmoji 在 `</a>` 前注入
  ///    `<img class="emoji mention-status">`。子包 parser 已能从 mention
  ///    子树提取 EmojiRun,只缺这个 img。
  /// 2. **链接点击数 click-count**:原始 cooked 不含点击数,legacy 用
  ///    post.linkCounts 在普通 `<a>` 后注入 `<span class="click-count">`。
  ///    子包 parser/flattener 已实现 click-count 节点。
  ///
  /// onebox/video 的点击数走另一条路(builder 传 linkCounts 按 URL 匹配),
  /// 不在这里注入(`_injectClickCounts` 正则只匹配普通 `<a>` 不匹配 aside)。
  static String preprocessCookedForRender(Post post) {
    var html = post.cooked;
    html = _injectMentionStatusEmoji(html, post.mentionedUsers);
    html = _injectClickCounts(html, post.linkCounts);
    return html;
  }

  /// 判断普通链接点击是否应上报 trackClick(skip-list,纯函数,便于单测)。
  ///
  /// 逐字对齐 legacy `discourse_html_content_widget._trackClick` 的 skip 判定:
  /// 跳过 1) 用户链接 /u/username(等价 mention);2) 附件/上传链接
  /// (upload:// 或 /uploads//secure-uploads//secure-media-uploads/);
  /// 3) mailto: 邮件;4) # 页内锚点。
  static bool shouldTrackClick(String url) {
    // 1. 用户链接(/u/username)
    if (DiscourseUrlParser.isUserLink(url)) return false;
    // 2. 附件/上传链接
    if (url.startsWith('upload://') ||
        url.contains('/uploads/') ||
        url.contains('/secure-uploads/') ||
        url.contains('/secure-media-uploads/')) {
      return false;
    }
    // 3. Email 链接
    if (url.startsWith('mailto:')) return false;
    // 4. 锚点链接
    if (url.startsWith('#')) return false;
    return true;
  }

  /// 追踪普通链接点击(fire-and-forget)。
  ///
  /// 逐字对齐 legacy `discourse_html_content_widget._trackClick`:仅当有
  /// [topicId] 时才追踪,且跳过 [shouldTrackClick] 判定的链接。底层
  /// `DiscourseService().trackClick` 自带 catchError(POST /clicks/track),
  /// 失败只 debugPrint 不抛,这里直接调用即可,无需再包 try。
  static void _trackClick(String url, int postId, int? topicId) {
    if (topicId == null) return;
    if (!shouldTrackClick(url)) return;
    DiscourseService().trackClick(url: url, postId: postId, topicId: topicId);
  }

  /// 默认内部链接点击 —— push 一个新的 TopicDetailPage。
  /// 供 [linkHandler] 在调用方未定制 onInternalLinkTap 时兜底。
  static void _defaultInternalLinkTap(
    BuildContext ctx,
    int topicId,
    String? topicSlug,
    int? postNumber,
  ) {
    Navigator.of(ctx).push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topicId,
          initialTitle: topicSlug,
          scrollToPostNumber: postNumber,
        ),
      ),
    );
  }

  // ==========================================================================
  // 共享 static builder —— 不依赖 Post,forPost / generic 复用。
  // ==========================================================================

  /// Emoji 图片:走主项目 emojiImageProvider(鉴权 + CDN)。
  static EmojiImageBuilder get _emojiBuilder => (ctx, emoji, size) {
    if (emoji.url.isEmpty) {
      return Text(emoji.name.isEmpty ? ':?:' : ':${emoji.name}:');
    }
    final resolvedUrl = UrlHelper.resolveUrlWithCdn(emoji.url);
    // 按显示尺寸 × dpr 解码:动图 emoji 是全帧驻留内存(GIF 每帧一张位图),
    // 原图尺寸解码内存翻倍且无视觉收益
    final dpr = MediaQuery.devicePixelRatioOf(ctx);
    Widget image = Image(
      image: ResizeImage.resizeIfNeeded(
        (size * dpr).round(),
        null,
        emojiImageProvider(resolvedUrl),
      ),
      width: size,
      height: size,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => Icon(
        Symbols.broken_image_rounded,
        size: size,
        color: Theme.of(ctx).colorScheme.outline,
      ),
    );
    // 动图 emoji 逐帧 markNeedsPaint,不隔离会冒泡到帖子 segment 的
    // RepaintBoundary 造成整帖每帧重绘(滚动中有动图 emoji 即持续掉帧)。
    // 无条件包 boundary:此前按 .gif 后缀判定,动 WebP/动 AVIF/无后缀
    // CDN 改写 URL 全部漏网 —— 一个漏网动表情 = 整帖每帧全量重光栅。
    // boundary 本身只是一个 layer 节点(Impeller 无独立纹理驻留成本),
    // 静图多付的这层远小于漏网代价。
    return RepaintBoundary(child: image);
  };

  /// Mention chip 点击 → 跳用户资料页。
  static MentionTapHandler get _mentionTapHandler => (ctx, username, href) {
    // 优先 href 解析(group/user 路由不同);兜底走 username
    final user = DiscourseUrlParser.parseUser(href);
    Navigator.of(ctx).push(
      MaterialPageRoute(
        builder: (_) => UserProfilePage(username: user?.username ?? username),
      ),
    );
  };

  /// 代码块高亮:走 HighlighterService(mermaid 不会到这里 ——
  /// [_codeBlockBuilder] 已按 language 整块接管)。
  static CodeBlockHighlighter get _codeBlockHighlighter =>
      (ctx, code, language) {
        // 同步 fast-path,async 高亮用 _AsyncHighlightedCode 包一层。
        return _AsyncHighlightedCode(code: code, language: language);
      };

  /// 代码块整块 override:mermaid 换成独立图表块(灰底容器 + 图表/代码
  /// 切换顶栏 + mermaid.ink 出图,逐字对齐 legacy _MermaidWidget)。
  /// 其余语言返回 null → 子包默认代码块外壳(行号/滚动/复制)+ 上面的
  /// highlighter。language 由子包 parser 提取并已小写化(lang-mermaid →
  /// 'mermaid'),直接全等比较即可。
  static CodeBlockBuilder get _codeBlockBuilder => (ctx, node) {
    if (node.language == 'mermaid') {
      return _MermaidBlock(code: node.code);
    }
    return null;
  };

  /// 引用卡头像:走 SmartAvatar(鉴权 + CDN 重写)。
  static QuoteAvatarBuilder get _quoteAvatarBuilder =>
      (ctx, username, avatarUrl, size) {
        final resolvedUrl = (avatarUrl ?? '').isEmpty
            ? null
            : UrlHelper.resolveUrlWithCdn(avatarUrl!);
        return SmartAvatar(
          imageUrl: resolvedUrl,
          radius: size / 2,
          fallbackText: username,
          backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHighest,
        );
      };

  /// 块级数学公式:flutter_math_fork,失败回退 monospace 原文。
  static MathBlockBuilder get _mathBlockBuilder => (ctx, node) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Math.tex(
            node.latex,
            textStyle: TextStyle(
              fontSize: 16,
              color: Theme.of(ctx).colorScheme.onSurface,
            ),
            onErrorFallback: (_) => Text(
              node.latex,
              style: TextStyle(
                fontFamily: 'monospace',
                color: Theme.of(
                  ctx,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ),
      ),
    );
  };

  /// 行内数学公式:flutter_math_fork,失败回退 monospace 原文。
  static MathInlineBuilder get _mathInlineBuilder => (ctx, node) {
    return Math.tex(
      node.latex,
      textStyle: TextStyle(
        fontSize: 14,
        color: Theme.of(ctx).colorScheme.onSurface,
      ),
      onErrorFallback: (_) => Text(
        node.latex,
        style: TextStyle(
          fontFamily: 'monospace',
          color: Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      ),
    );
  };

  /// 内容型 SVG:jovial_svg 等比铺满列宽。
  static SvgBuilder get _svgBuilder => (ctx, node) {
    return _buildInlineSvgFromSource(node.svgSource);
  };

  /// 原生上传视频:复用 DiscourseVideoPlayer(chewie)。VideoNode 已结构化,
  /// upload:// 短链先解析成真实 URL(与 image builder 同套路);再过
  /// MediaCompatService 处理「改名上传」(.xz 装 mp4 等,AVFoundation
  /// 按扩展名认容器,须本地化改回正确后缀,详见该服务文档)。
  static VideoBuilder get _videoBuilder => (ctx, node) {
    final rawSrc = node.src;
    if (rawSrc.isEmpty) return null; // 让子包出占位卡
    // poster 只接受能解析成绝对 http(s) 的:手写 <video poster="cover.jpg">
    // 的相对路径解析不出来(resolveUrlWithCdn 原样返回),upload:// 缓存
    // miss 也拿不到真实地址 —— 这类喂给 Image 必失败,而 poster 的 Image
    // 此前没配 errorBuilder,debug 模式下 Flutter 会显示暗红 Placeholder
    // + 错误文字(_debugBuildErrorWidget),就是「出画前红色一闪」的来源。
    // 源头滤掉,失败降级为无封面(转圈),而不是红块。
    String? posterUrl;
    final rawPoster = node.poster;
    if (rawPoster != null && rawPoster.isNotEmpty) {
      final resolved = DiscourseImageUtils.isUploadUrl(rawPoster)
          ? DiscourseImageUtils.getCachedUploadUrl(rawPoster)
          : UrlHelper.resolveUrlWithCdn(rawPoster);
      final uri = resolved == null ? null : Uri.tryParse(resolved);
      if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
        posterUrl = resolved;
      }
    }
    final dimensOk =
        node.width != null &&
        node.width! > 0 &&
        node.height != null &&
        node.height! > 0;
    Widget playerFor(String resolvedSrc) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: DiscourseVideoPlayer(
          resolvedSrc,
          aspectRatio: dimensOk ? node.width! / node.height! : 16 / 9,
          autoResize: !dimensOk,
          controls: true,
          poster: posterUrl == null
              ? null
              : Image(
                  // 封面按列宽(屏宽兜底)× dpr 解码,不吃原图全分辨率
                  image: ResizeImage.resizeIfNeeded(
                    (MediaQuery.sizeOf(ctx).width *
                            MediaQuery.devicePixelRatioOf(ctx))
                        .round(),
                    null,
                    discourseImageProvider(posterUrl),
                  ),
                  fit: BoxFit.contain,
                  // 加载失败降级为无封面。不配的话 debug 模式下
                  // Flutter 用暗红 Placeholder 顶上来(红色一闪)。
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
          errorBuilder: (c, failedUrl, error) =>
              _VideoErrorFallback(url: failedUrl, error: error),
          loadingBuilder: (c, _, child) => Center(
            child: posterUrl != null
                ? child
                : const LoadingSpinner(size: 24),
          ),
        ),
      ),
    );
    const probing = Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    );
    Widget compatPlayerFor(String src) =>
        _withPlayableUrl(src, playerFor, probing);
    if (!DiscourseImageUtils.isUploadUrl(rawSrc)) {
      return compatPlayerFor(UrlHelper.resolveUrlWithCdn(rawSrc));
    }
    final cached = DiscourseImageUtils.getCachedUploadUrl(rawSrc);
    if (cached != null) return compatPlayerFor(cached);
    return FutureBuilder<String?>(
      future: DiscourseImageUtils.resolveUploadUrl(rawSrc),
      builder: (c, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return probing;
        }
        final url = snap.data;
        if (url == null || url.isEmpty) return const SizedBox.shrink();
        return compatPlayerFor(url);
      },
    );
  };

  /// 原生上传音频:just_audio 的 DiscourseAudioPlayer。upload:// 先解析,
  /// 再过 MediaCompatService(改名上传的 mp3 等同样过不了 AVFoundation)。
  static AudioBuilder get _audioBuilder => (ctx, node) {
    final rawSrc = node.src;
    if (rawSrc.isEmpty) return null;
    const probing = Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        height: 56,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    );
    Widget compatPlayerFor(String src) => _withPlayableUrl(
      src,
      (url) => DiscourseAudioPlayer(url: url, voice: node.voice),
      probing,
    );
    if (!DiscourseImageUtils.isUploadUrl(rawSrc)) {
      return compatPlayerFor(UrlHelper.resolveUrlWithCdn(rawSrc));
    }
    final cached = DiscourseImageUtils.getCachedUploadUrl(rawSrc);
    if (cached != null) return compatPlayerFor(cached);
    return FutureBuilder<String?>(
      future: DiscourseImageUtils.resolveUploadUrl(rawSrc),
      builder: (c, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return probing;
        }
        final url = snap.data;
        if (url == null || url.isEmpty) return const SizedBox.shrink();
        return compatPlayerFor(url);
      },
    );
  };

  /// 媒体 URL 过 MediaCompatService 的通用包装:无需处理(绝大多数)
  /// 时同步直出 [builder];需要嗅探/本地化时先出 [placeholder],完成后
  /// 换可播放地址(失败回退原 URL,交给播放器错误链路)。
  static Widget _withPlayableUrl(
    String url,
    Widget Function(String url) builder,
    Widget placeholder,
  ) {
    final compat = MediaCompatService.instance;
    if (!compat.needsProbe(url)) return builder(url);
    final cached = compat.cachedPlayableUrl(url);
    if (cached != null) return builder(cached);
    return FutureBuilder<String>(
      future: compat.resolvePlayableUrl(url),
      builder: (c, snap) {
        if (snap.connectionState != ConnectionState.done) return placeholder;
        return builder(snap.data ?? url);
      },
    );
  }

  /// 附件下载:复用 legacy launchContentLink 的下载链路(_isUploadLink 判附件
  /// 后回调 startDownload);文件名用 parser 抓到的锚点文件名。
  static AttachmentDownloadHandler get _onDownloadAttachment =>
      (ctx, href, filename) {
        launchContentLink(
          ctx,
          href,
          onDownloadAttachment: (downloadUrl) {
            ProviderScope.containerOf(ctx, listen: false)
                .read(downloadProvider.notifier)
                .startDownload(
                  url: downloadUrl,
                  suggestedFilename: filename.isEmpty ? null : filename,
                );
          },
        );
      };

  /// 嵌入 iframe:用 IframeNode 结构化字段直接构造 IframeWidget(webview),
  /// 不再反构造 DOM。web 平台无 InAppWebView,返回 null 走子包内置占位卡。
  static IframeBuilder get _iframeBuilder => (ctx, node) {
    if (kIsWeb) return null; // web 走子包内置占位卡
    if (node.src.isEmpty) return null;
    return IframeWidget(
      attributes: IframeAttributes(
        src: node.src,
        width: node.width,
        height: node.height,
        sandbox: node.sandboxFlags.isEmpty ? null : node.sandboxFlags,
        allow: node.allowFlags,
        allowFullscreen: node.allowFullscreen,
        referrerPolicy: node.referrerPolicy,
        lazyLoad: node.lazyLoad,
        title: node.title,
        classes: node.cssClasses,
      ),
    );
  };

  /// 本地日期 chip:复用 legacy 逻辑但取裸 chip(不包 fwfh InlineCustomWidget),
  /// 子包 local_date_handler 自行包 WidgetSpan 做行内排版。
  static LocalDateBuilder get _localDateBuilder => (ctx, node) {
    final el = _localDateElementFrom(node);
    return legacy_local_date.buildLocalDateChip(
      context: ctx,
      theme: Theme.of(ctx),
      element: el,
      baseFontSize: Theme.of(ctx).textTheme.bodyMedium?.fontSize ?? 14,
    );
  };

  /// 图片网格 carousel:复用 legacy buildImageCarousel(分页 / 计数器 /
  /// 预加载 / upload:// 异步解析 / 画廊左右切)。不依赖 Post。
  static ImageGridBuilder get _imageGridBuilder => (ctx, node) {
    // 仅 carousel 形态会被子包调用(grid 形态子包内置 Wrap 渲染)。
    if (node.images.isEmpty) return null;
    // 缩略图用 src、原图用 lightboxUrl(无 lightbox 时回退 src)。
    final gridImages = [
      for (final img in node.images)
        GridImageData(
          src: img.src,
          fullSrc: img.lightboxUrl ?? img.src,
          width: img.width,
          height: img.height,
        ),
    ];
    // 画廊原图 URL 列表(非 upload:// 先 CDN 重写,保证 findIndex / 左右切
    // 命中)。upload:// 短链保持原样,由 viewer/解析侧处理。
    final galleryUrls = [
      for (final img in node.images)
        () {
          final full = img.lightboxUrl ?? img.src;
          return DiscourseImageUtils.isUploadUrl(full)
              ? full
              : UrlHelper.resolveUrlWithCdn(full);
        }(),
    ];
    return legacy_carousel.buildImageCarousel(
      context: ctx,
      theme: Theme.of(ctx),
      images: gridImages,
      galleryInfo: GalleryInfo.fromImages(galleryUrls),
    );
  };

  /// 脚注点击 → popover 显示脚注内容(嵌套 FluxdoRender 渲染,不再走 legacy
  /// DiscourseHtmlContent)。[heroNamespace] 用于嵌套图片 heroTag,避免与外层
  /// 正文冲突;[topicId] 透传给嵌套内部链接点击。
  static FootnoteTapHandler _footnoteHandler(
    String heroNamespace,
    int? topicId,
  ) {
    return (ctx, fnId, contentHtml) {
      if (contentHtml == null || contentHtml.isEmpty) return;
      showPopover(
        context: ctx,
        bodyBuilder: (popCtx) {
          final theme = Theme.of(popCtx);
          final screenHeight = MediaQuery.of(popCtx).size.height;
          final screenWidth = MediaQuery.of(popCtx).size.width;
          final nested = FluxdoRenderCallbacks.generic(
            heroTagNamespace: '${heroNamespace}_fn$fnId',
            topicId: topicId,
          );
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: screenHeight * 0.3,
              maxWidth: screenWidth * 0.85,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: nested.render(
                cookedHtml: contentHtml,
                baseTextStyle: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.5,
                ),
                selectionEnabled: false,
              ),
            ),
          );
        },
        direction: PopoverDirection.bottom,
        arrowHeight: 8,
        arrowWidth: 12,
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHigh,
        barrierColor: Colors.transparent,
        radius: 8,
        shadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      );
    };
  }

  /// 聊天记录:反构造 element 喂 legacy buildChatTranscript,消息内容走
  /// htmlBuilder 递归 —— 改用嵌套 FluxdoRender(generic)渲染,不再走
  /// DiscourseHtmlContent。[heroNamespace] 用于嵌套图片 heroTag。
  static ChatTranscriptBuilder _chatTranscriptHandler(
    String heroNamespace,
    int? topicId,
  ) {
    return (ctx, node) {
      if (node.rawHtml.isEmpty) return null;
      final el = _elementFromHtml(node.rawHtml);
      final nested = FluxdoRenderCallbacks.generic(
        heroTagNamespace: '${heroNamespace}_chat',
        topicId: topicId,
      );
      return legacy_chat.buildChatTranscript(
        context: ctx,
        theme: Theme.of(ctx),
        element: el,
        htmlBuilder: (html, textStyle) => nested.render(
          cookedHtml: html,
          baseTextStyle: textStyle,
          selectionEnabled: false,
        ),
      );
    };
  }

  /// 内容图片 builder(共享实现):算 heroTag + upload:// 解析 + 画廊/菜单上下文。
  ///
  /// forPost 传全帖 lightbox 画廊 resolver + Post(左右切 + 引用菜单);generic
  /// 不传 resolver(单图打开、菜单隐藏引用)。heroTag 统一 `${heroNamespace}_img_N`。
  /// [galleryResolver] 惰性:仅在用户点图时调用(见 _buildImageWidget onTap),
  /// build 阶段零解析成本。
  /// 按设备 dpr 从 srcset 选档(浏览器语义:scale ≥ dpr 的最小档,
  /// 都不够则取最大档)。Discourse 契约:src=1x 主档,srcset 含 1.5x/2x
  /// (cooked_processor_mixin optimize_image!)。无 srcset 返回 null
  /// (调用方回落 src)。3x 屏由此从"690px 拉伸模糊"变 2x 档,与 web
  /// 端渲染等价;解码纹理量不变(ResizeImage 仍按显示宽 × dpr cap)。
  static String? _pickSrcsetUrl(ImageRun image, double dpr) {
    if (image.srcset.isEmpty) return null;
    final sorted = [...image.srcset]..sort((a, b) => a.scale.compareTo(b.scale));
    for (final c in sorted) {
      if (c.scale >= dpr - 0.01) return c.url;
    }
    return sorted.last.url;
  }

  static ImageContentBuilder _imageContentBuilder({
    required String heroNamespace,
    _GalleryData Function()? galleryResolver,
    Post? post,
    int? topicId,
    void Function(String quote, Post post)? onQuoteImage,
    void Function(ImageRun image, int scale)? onImageScaleChanged,
  }) {
    return (ctx, image, totalImagesInPost) {
      final heroTag = '${heroNamespace}_img_${image.indexInPost}';
      // Discourse cooked 里图片 src 有两种形态:
      //   1. 普通 http(s) URL —— 直接走 CDN 重写
      //   2. upload:// 短链 —— 需要 ImageBuildAddon 异步解析为真实 URL
      // 这里同步用缓存命中(普通帖滚到第二次起命中);未命中走 FutureBuilder。
      if (!DiscourseImageUtils.isUploadUrl(image.src)) {
        final resolvedUrl = UrlHelper.resolveUrlWithCdn(image.src);
        return _buildImageWidget(
          resolvedUrl: resolvedUrl,
          originalUrl: image.src,
          heroTag: heroTag,
          image: image,
          galleryResolver: galleryResolver,
          post: post,
          topicId: topicId,
          onQuoteImage: onQuoteImage,
          onImageScaleChanged: onImageScaleChanged,
        );
      }
      // upload:// — 优先看缓存
      final cached = DiscourseImageUtils.getCachedUploadUrl(image.src);
      if (cached != null) {
        return _buildImageWidget(
          resolvedUrl: cached,
          originalUrl: image.src,
          heroTag: heroTag,
          image: image,
          galleryResolver: galleryResolver,
          post: post,
          topicId: topicId,
          onQuoteImage: onQuoteImage,
          onImageScaleChanged: onImageScaleChanged,
        );
      }
      return FutureBuilder<String?>(
        future: DiscourseImageUtils.resolveUploadUrl(image.src),
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return SizedBox(
              width: image.width ?? 120,
              height: image.height ?? 80,
              child: const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          if (snap.data == null) {
            return Icon(
              Symbols.broken_image_rounded,
              color: Theme.of(ctx).colorScheme.outline,
              size: 24,
            );
          }
          return _buildImageWidget(
            resolvedUrl: snap.data!,
            originalUrl: image.src,
            heroTag: heroTag,
            image: image,
            galleryResolver: galleryResolver,
            post: post,
            topicId: topicId,
            onQuoteImage: onQuoteImage,
            onImageScaleChanged: onImageScaleChanged,
          );
        },
      );
    };
  }

  /// 懒加载视频 builder(共享):反构造 element 喂 legacy buildLazyVideo。
  /// [linkCounts] 用于点击数(forPost 传 post.linkCounts,generic 传空)。
  static LazyVideoBuilder _lazyVideoHandler(List<LinkCount> linkCounts) {
    return (ctx, node) {
      final el = _lazyVideoElementFrom(node);
      return legacy_video.buildLazyVideo(
        context: ctx,
        theme: Theme.of(ctx),
        element: el,
        linkCounts: linkCounts,
      );
    };
  }

  /// Onebox builder(共享):OneboxNode.rawHtml 是完整 `<aside class="onebox">`,
  /// parseFragment 后喂 legacy buildOneboxCard(6 子 builder)。
  /// [linkCounts] 用于点击数(forPost 传 post.linkCounts,generic 传空)。
  static OneboxBuilder _oneboxHandler(List<LinkCount> linkCounts) {
    return (ctx, node) {
      if (node.rawHtml.isEmpty) return null;
      final el = _elementFromHtml(node.rawHtml);
      return buildOneboxCard(
        context: ctx,
        theme: Theme.of(ctx),
        element: el,
        linkCounts: linkCounts,
      );
    };
  }

  // ==========================================================================
  // 入口 factory
  // ==========================================================================

  /// 帖子场景:用 postId 作 Hero tag namespace,避免不同 post 间冲突。
  /// [post] 必传 — policyBuilder 需要 post 实例(legacy `_PolicyWidget`
  /// 监听 CurrentPostScope 的 post 状态变化)。
  factory FluxdoRenderCallbacks.forPost({
    required Post post,
    // 链接点击追踪 + 图片引用菜单需要 topicId(Post 模型本身不含 topicId,
    // 由调用方透传)。为 null 时(如分享截图场景)不追踪点击、图片菜单隐藏
    // 「引用」「复制引用」,对齐 legacy 在 topicId==null 时的降级行为。
    int? topicId,
    // 图片长按/右键菜单的引用回调(对齐 legacy DiscourseWidgetFactory
    // 的 onQuoteImage 字段)。为 null 时菜单隐藏「引用」「复制引用」。
    void Function(String quote, Post post)? onQuoteImage,
    String? preprocessedCooked,
    List<BlockNode>? parsedNodes,
    List<ImageRun>? lightboxImageRuns,
    // 惰性画廊源:首次点图才被调用(长帖懒解析场景由
    // NewEngineLongPostData 注入,调用时触发全 chunk 解析)。
    // 与 [lightboxImageRuns] 二选一,eager 列表优先。
    List<ImageRun> Function()? lightboxImageRunsProvider,
  }) {
    final postId = post.id;
    final heroNamespace = 'post_$postId';
    // 画廊数据惰性构建:预解析 cooked 收集 Discourse lightbox 口径的画廊项
    // (Web 版 PhotoSwipe 的 dataSource 来自 `a.lightbox`,不是所有 <img>;
    // 裸图只能单图打开,不参与左右切换)。
    //
    // 收集 + URL 拼装推迟到首次点图/长按:构建 callbacks 时零解析成本
    // (未传 parsedNodes 的场景此前会在这里同步 parse 整帖)。
    // 点图是离散动作,一次性收集后缓存复用。
    _GalleryData? galleryCache;
    _GalleryData resolveGallery() {
      final cached = galleryCache;
      if (cached != null) return cached;
      final galleryImages =
          lightboxImageRuns ??
          lightboxImageRunsProvider?.call() ??
          collectLightboxImageRuns(
            parsedNodes ??
                ParagraphParser().parse(
                  preprocessedCooked ?? preprocessCookedForRender(post),
                ),
          );
      // 画廊原图 URL + heroTag 列表(顺序 = lightbox 出现顺序)。indexInPost
      // 仍是全帖所有内容图的编号,所以额外建 imageIndex→galleryIndex 映射,
      // 避免裸图插在中间时 initialIndex 错位。
      final galleryUrls = <String>[];
      final galleryThumbs = <String>[];
      final galleryHeroTags = <String>[];
      final galleryIndexByImageIndex = <int, int>{};
      for (var i = 0; i < galleryImages.length; i++) {
        final img = galleryImages[i];
        final full = img.lightboxUrl ?? img.src;
        final resolvedFull = DiscourseImageUtils.isUploadUrl(full)
            ? (DiscourseImageUtils.getCachedUploadUrl(full) ?? full)
            : UrlHelper.resolveUrlWithCdn(full);
        final resolvedThumb = DiscourseImageUtils.isUploadUrl(img.src)
            ? (DiscourseImageUtils.getCachedUploadUrl(img.src) ?? img.src)
            : UrlHelper.resolveUrlWithCdn(img.src);
        galleryUrls.add(DiscourseImageUtils.getOriginalUrl(resolvedFull));
        galleryThumbs.add(resolvedThumb);
        galleryHeroTags.add('${heroNamespace}_img_${img.indexInPost}');
        galleryIndexByImageIndex[img.indexInPost] = i;
      }
      return galleryCache = (
        urls: galleryUrls,
        thumbs: galleryThumbs,
        heroTags: galleryHeroTags,
        indexByImageIndex: galleryIndexByImageIndex,
      );
    }

    return FluxdoRenderCallbacks(
      linkHandler: (ctx, href) {
        // 先追踪链接点击(fire-and-forget,对齐 legacy
        // discourse_html_content_widget._trackClick:在 launchContentLink
        // 之前调用,topicId 为 null 时内部直接跳过)。
        _trackClick(href, post.id, topicId);
        launchContentLink(
          ctx,
          href,
          onInternalLinkTap: (innerTopicId, topicSlug, postNumber) {
            _defaultInternalLinkTap(ctx, innerTopicId, topicSlug, postNumber);
          },
        );
      },
      emojiImageBuilder: _emojiBuilder,
      mentionTapHandler: _mentionTapHandler,
      imageContentBuilder: _imageContentBuilder(
        heroNamespace: heroNamespace,
        galleryResolver: resolveGallery,
        post: post,
        topicId: topicId,
        onQuoteImage: onQuoteImage,
      ),
      codeBlockHighlighter: _codeBlockHighlighter,
      codeBlockBuilder: _codeBlockBuilder,
      quoteAvatarBuilder: _quoteAvatarBuilder,
      footnoteTapHandler: _footnoteHandler(heroNamespace, topicId),
      lazyVideoBuilder: _lazyVideoHandler(post.linkCounts ?? const []),
      iframeBuilder: _iframeBuilder,
      localDateBuilder: _localDateBuilder,
      mathBlockBuilder: _mathBlockBuilder,
      mathInlineBuilder: _mathInlineBuilder,
      oneboxBuilder: _oneboxHandler(post.linkCounts ?? const []),
      imageGridBuilder: _imageGridBuilder,
      policyBuilder: (ctx, node) {
        // 优先用 rawHtml(完整 cooked,legacy htmlBuilder 能渲染 body 富文本);
        // 没有时回退用反构造的占位 element(BlockNode toString 兜底)
        final el = node.rawHtml.isNotEmpty
            ? _elementFromHtml(node.rawHtml)
            : _policyElementFrom(node);
        return legacy_policy.buildPolicy(
          context: ctx,
          theme: Theme.of(ctx),
          element: el,
          post: post,
          htmlBuilder: (html, textStyle) => _footnoteFreeNested(
            html: html,
            textStyle: textStyle,
            heroNamespace: '${heroNamespace}_policy',
            topicId: topicId,
          ),
        );
      },
      pollBuilder: (ctx, node) {
        // 把 PollNode.rawHtml 反构造成 element 喂给 legacy buildPoll。
        // legacy 从 element 读 data-poll-name,再从 post.polls match 出
        // 真实选项/票数,投票交互调 DiscourseService。
        if (node.rawHtml.isEmpty) return null;
        final el = _elementFromHtml(node.rawHtml);
        return legacy_poll.buildPoll(
          context: ctx,
          theme: Theme.of(ctx),
          element: el,
          post: post,
        );
      },
      chatTranscriptBuilder: _chatTranscriptHandler(heroNamespace, topicId),
      svgBuilder: _svgBuilder,
      videoBuilder: _videoBuilder,
      audioBuilder: _audioBuilder,
      onDownloadAttachment: _onDownloadAttachment,
    );
  }

  /// 非正文场景:用户卡 bio / 个人页 / 徽章 / 回复预览 / 分享卡 / 弹窗 等。
  ///
  /// 无 Post,按需降级(对齐 legacy 在无 post/topicId 时的行为):
  /// - [heroTagNamespace] 作图片 Hero tag namespace(调用方保证唯一,如
  ///   `'user_card_$userId'`),避免与正文/其他场景 heroTag 冲突。
  /// - 图片:单图打开(无全帖画廊左右切),菜单隐藏「引用」「复制引用」(无 post)。
  /// - 链接:走 [onInternalLinkTap] 定制(默认 push TopicDetailPage);不追踪
  ///   点击(trackClick 需 postId)。
  /// - onebox / lazyVideo:点击数传空(无 post.linkCounts)。
  /// - policy / poll:返回 null → 子包 fallback 占位(无 post 无法交互)。
  /// - 其余(emoji/mention/code/avatar/math/svg/video/audio/download/iframe/
  ///   localDate/imageGrid/footnote/chat)与 forPost 完全一致(共享 static)。
  factory FluxdoRenderCallbacks.generic({
    required String heroTagNamespace,
    int? topicId,
    void Function(int topicId, String? topicSlug, int? postNumber)?
    onInternalLinkTap,
    // 编辑器预览场景:可缩放图(客户端 cook 预览形态)出 100/75/50 缩放
    // 胶囊,点击回调宿主改 raw。阅读端不传(无控件,零成本)。
    void Function(ImageRun image, int scale)? onImageScaleChanged,
  }) {
    return FluxdoRenderCallbacks(
      linkHandler: (ctx, href) {
        launchContentLink(
          ctx,
          href,
          onInternalLinkTap: (innerTopicId, topicSlug, postNumber) {
            if (onInternalLinkTap != null) {
              onInternalLinkTap(innerTopicId, topicSlug, postNumber);
            } else {
              _defaultInternalLinkTap(ctx, innerTopicId, topicSlug, postNumber);
            }
          },
        );
      },
      emojiImageBuilder: _emojiBuilder,
      mentionTapHandler: _mentionTapHandler,
      imageContentBuilder: _imageContentBuilder(
        heroNamespace: heroTagNamespace,
        topicId: topicId,
        onImageScaleChanged: onImageScaleChanged,
      ),
      codeBlockHighlighter: _codeBlockHighlighter,
      codeBlockBuilder: _codeBlockBuilder,
      quoteAvatarBuilder: _quoteAvatarBuilder,
      footnoteTapHandler: _footnoteHandler(heroTagNamespace, topicId),
      lazyVideoBuilder: _lazyVideoHandler(const []),
      iframeBuilder: _iframeBuilder,
      localDateBuilder: _localDateBuilder,
      mathBlockBuilder: _mathBlockBuilder,
      mathInlineBuilder: _mathInlineBuilder,
      oneboxBuilder: _oneboxHandler(const []),
      imageGridBuilder: _imageGridBuilder,
      // 无 post → 无法做接受/撤销 + 票数交互,返回 null 让子包出 fallback 占位。
      policyBuilder: (ctx, node) => null,
      pollBuilder: (ctx, node) => null,
      chatTranscriptBuilder: _chatTranscriptHandler(heroTagNamespace, topicId),
      svgBuilder: _svgBuilder,
      videoBuilder: _videoBuilder,
      audioBuilder: _audioBuilder,
      onDownloadAttachment: _onDownloadAttachment,
    );
  }

  /// policy body 的嵌套渲染 helper —— 用 generic 嵌套 FluxdoRender 渲染
  /// policy 富文本 body,替代 legacy DiscourseHtmlContent。
  static Widget _footnoteFreeNested({
    required String html,
    required TextStyle? textStyle,
    required String heroNamespace,
    int? topicId,
  }) {
    final nested = FluxdoRenderCallbacks.generic(
      heroTagNamespace: heroNamespace,
      topicId: topicId,
    );
    return nested.render(
      cookedHtml: html,
      baseTextStyle: textStyle,
      selectionEnabled: false,
    );
  }

  /// 把已解析好的图片 URL 包装成 LazyImage + Hero + tap → openViewer。
  /// SVG 走 jovial_svg(ScalableImageWidget),非 SVG 走 LazyImage。
  ///
  /// [galleryResolver] 返回 Discourse lightbox 口径的全帖画廊数据,
  /// 非空画廊时点击走 gallery viewer 支持左右切。惰性:只在 onTap 里调用。
  static Widget _buildImageWidget({
    required String resolvedUrl,
    required String originalUrl,
    required String heroTag,
    required ImageRun image,
    _GalleryData Function()? galleryResolver,
    // 图片长按/右键菜单引用上下文(透传到 ImageContextMenu.show)。
    Post? post,
    int? topicId,
    void Function(String quote, Post post)? onQuoteImage,
    // 预览缩放控件(编辑器预览场景注入;帖子阅读端不传)。可缩放图
    // (客户端 cook 预览形态,image.scale 非 null)hover/常显 100/75/50
    // 胶囊,点击回调宿主改 raw 的 `, N%` 后缀。
    void Function(ImageRun image, int scale)? onImageScaleChanged,
  }) {
    final isSvg = _isSvgUrl(resolvedUrl) || _isSvgUrl(originalUrl);
    // max-width: 100% + 不上采样 —— 对齐 Discourse `.cooked img { max-width:
    // 100%; height: auto }`:按 <img width/height> 等比展示,超过可用宽时等比
    // 缩小(窄屏不溢出),绝不放大(宽屏小图不拉糊)。
    //
    // 用 LayoutBuilder 只「观察」WidgetSpan 给的可用宽,不改变约束,故不会像
    // FittedBox 那样强制无约束测量子树(那会让 LazyImage 占位的 AspectRatio
    // 在无约束下 assert 崩溃)。
    return LayoutBuilder(
      builder: (lbCtx, lbc) {
        double? dispW = image.width;
        double? dispH = image.height;
        if (dispW != null &&
            dispH != null &&
            dispW > 0 &&
            lbc.maxWidth.isFinite &&
            dispW > lbc.maxWidth) {
          dispH = dispH * (lbc.maxWidth / dispW);
          dispW = lbc.maxWidth;
        }
        if (isSvg) {
          // SVG 统一走 DiscourseSvgView(内容嗅探动画:静态 jovial_svg,
          // 动画 full_svg_flutter 首帧快照+点击播放);外包 GestureDetector
          // 支持长按/右键菜单(对齐 legacy buildGalleryImage 的 SVG 分支)。
          return Builder(
            builder: (svgCtx) => GestureDetector(
              onLongPress: () => _showImageContextMenu(
                svgCtx,
                image: image,
                resolvedUrl: resolvedUrl,
                post: post,
                topicId: topicId,
                onQuoteImage: onQuoteImage,
              ),
              onSecondaryTapUp: (details) => _showImageContextMenu(
                svgCtx,
                image: image,
                resolvedUrl: resolvedUrl,
                post: post,
                topicId: topicId,
                onQuoteImage: onQuoteImage,
                position: details.globalPosition,
              ),
              child: SizedBox(
                width: dispW,
                height: dispH,
                child: DiscourseSvgView(
                  url: resolvedUrl,
                  width: dispW,
                  height: dispH,
                  placeholderBuilder: (_) => const LoadingSpinner(size: 24),
                ),
              ),
            ),
          );
        }
        // LazyImage 加载态用 AspectRatio 包图 —— AspectRatio 会撑满可用宽
        // (只拿 width/height 算比例,不当实际尺寸),宽列里就被拉成整列宽。
        // 外层 SizedBox(dispW, dispH) 给它 tight 约束,强制按 Discourse
        // max-width:100% 的实际尺寸渲染(列宽富余时左对齐留白,不上采样)。
        //
        // 解码上限由 LazyImage 内的 ResizeImage 承担(decode-time,engine
        // 下采样解码,全格式生效)。不要走 CachedNetworkImageProvider 的
        // maxWidth —— 那是 flutter_cache_manager 的 resize 路径:webp 不在
        // supportedFileNames 里直接原图返回(Discourse CDN 主流恰是 webp,
        // 等于没约束);jpg/png 则解码后 PNG 重编码再写第二份磁盘缓存,
        // 首次加载反而多付几百 ms。
        return SizedBox(
          width: dispW,
          height: dispH,
          child: Builder(
            builder: (ctx) {
              // srcset 按 dpr 选档(仅 http(s) src;upload:// 短链解析后的
              // resolvedUrl 与 srcset 候选不同源,不混用)。cacheKey 保持
              // resolvedUrl:查看器 thumbnailUrl / Hero 同 key 复用不受
              // 档位影响。
              final srcsetUrl = DiscourseImageUtils.isUploadUrl(image.src)
                  ? null
                  : _pickSrcsetUrl(
                      image, MediaQuery.devicePixelRatioOf(ctx));
              final displayUrl = srcsetUrl == null
                  ? resolvedUrl
                  : UrlHelper.resolveUrlWithCdn(srcsetUrl);
              final dominant = image.dominantColor;
              Widget img = LazyImage(
                imageProvider: discourseImageProvider(displayUrl),
                placeholderColor: dominant == null
                    ? null
                    : Color(
                        0xFF000000 |
                            (int.tryParse(dominant, radix: 16) ?? 0xEEEEEE),
                      ),
                width: dispW,
                height: dispH,
                // 解码恒按**原始宽**(scale 乘之前的声明宽):缩放档切换
                // 显示宽变但解码宽不变 → ImageCache 同 key,切档零重
                // 解码零 spinner(此前解码宽跟显示宽走,每次切档全新
                // 解码,卡顿主因)。无 scale 场景 origWidth 为 null,
                // 行为不变。
                decodeWidth: image.origWidth ?? dispW,
                heroTag: heroTag,
                cacheKey: displayUrl,
                onTap: () {
                  // 打开大图前清掉自研选区:图片 tap 被 HeroImage 手势赢走,
                  // 选区层收不到不会自动清(否则返回后选区还残留)。
                  SelectionScope.clearAt(ctx);
                  // Discourse 契约:a.lightbox[href] 就是原图 URL,直接用;
                  // 只有裸 <img>(无 lightbox 包装)才用 /optimized/→
                  // /original/ 正则反推兜底(正则对 CDN 变体路径有漏配
                  // 风险,能不用就不用)。
                  final hasLightbox = image.lightboxUrl != null;
                  final fullUrl = image.lightboxUrl ?? resolvedUrl;
                  var resolvedFullUrl =
                      DiscourseImageUtils.isUploadUrl(fullUrl)
                      ? (DiscourseImageUtils.getCachedUploadUrl(fullUrl) ??
                            fullUrl)
                      : UrlHelper.resolveUrlWithCdn(fullUrl);
                  if (!hasLightbox) {
                    resolvedFullUrl =
                        DiscourseImageUtils.getOriginalUrl(resolvedFullUrl);
                  }
                  // 画廊数据在点击时才解析(长帖懒解析场景首次点图会触发
                  // 全 chunk parse,离散动作可接受;之后命中缓存)。
                  // 全帖画廊非空时走画廊 viewer(左右切同帖其他图);否则单图。
                  final gallery = galleryResolver?.call();
                  final galleryIndex =
                      gallery?.indexByImageIndex[image.indexInPost];
                  final hasGallery =
                      gallery != null &&
                      gallery.urls.length > 1 &&
                      galleryIndex != null &&
                      galleryIndex >= 0 &&
                      galleryIndex < gallery.urls.length;
                  DiscourseImageUtils.openViewer(
                    context: ctx,
                    imageUrl: resolvedFullUrl,
                    heroTag: heroTag,
                    thumbnailUrl: displayUrl,
                    galleryImages: hasGallery ? gallery.urls : null,
                    thumbnailUrls: hasGallery ? gallery.thumbs : null,
                    heroTags: hasGallery ? gallery.heroTags : null,
                    initialIndex: hasGallery ? galleryIndex : 0,
                  );
                },
                // 长按/右键 → 图片上下文菜单(对齐 legacy LazyImage
                // onLongPress/onSecondaryTapUp,discourse_widget_factory.dart)。
                onLongPress: () => _showImageContextMenu(
                  ctx,
                  image: image,
                  resolvedUrl: resolvedUrl,
                  post: post,
                  topicId: topicId,
                  onQuoteImage: onQuoteImage,
                  heroTag: heroTag,
                ),
                onSecondaryTapUp: (details) => _showImageContextMenu(
                  ctx,
                  image: image,
                  resolvedUrl: resolvedUrl,
                  post: post,
                  topicId: topicId,
                  onQuoteImage: onQuoteImage,
                  position: details.globalPosition,
                  heroTag: heroTag,
                ),
              );
              // 预览缩放胶囊(右上角浮层,子包统一视觉)。仅有界宽上下文
              // (正常文档流段落图)出 —— grid 瓦片在 FittedBox(cover) 内
              // 无约束测量(maxWidth infinite),浮层会随之缩放变形;grid
              // 布局本身吃掉显示尺寸,瓦片内缩放视觉意义也弱,改走源码。
              if (onImageScaleChanged != null &&
                  image.scale != null &&
                  lbc.maxWidth.isFinite) {
                img = Stack(
                  clipBehavior: Clip.none,
                  children: [
                    img,
                    Positioned(
                      top: 6,
                      right: 6,
                      child: EditorImageScaleBar(
                        current: image.scale!.round(),
                        onSelect: (s) => onImageScaleChanged(image, s),
                      ),
                    ),
                  ],
                );
              }
              return img;
            },
          ),
        );
      },
    );
  }

  /// 显示图片长按/右键菜单(对齐 legacy DiscourseWidgetFactory
  /// `_showImageContextMenu` → ImageContextMenu.show)。
  ///
  /// 菜单展示用「原图 URL」:优先 image.lightboxUrl(原图大版本),
  /// 否则用当前已 CDN 重写的 resolvedUrl;再过一遍 getOriginalUrl 还原
  /// /optimized/ → /original/(与 onTap 打开大图同口径)。getOriginalUrl
  /// 幂等,ImageContextMenu.show 内部还会再调一次,无副作用。
  ///
  /// 引用 handler 在 **tap 时刻**经 [QuoteImageScope] 就近现取(flatten
  /// 产物进全局缓存后,闭包冻结的 [onQuoteImage] 可能指向已销毁页面的
  /// State);无作用域场景(分享截图等)回落冻结引用。
  static void _showImageContextMenu(
    BuildContext context, {
    required ImageRun image,
    required String resolvedUrl,
    Post? post,
    int? topicId,
    void Function(String quote, Post post)? onQuoteImage,
    Offset? position,
    String? heroTag,
  }) {
    final scope = QuoteImageScope.maybeOf(context);
    final liveQuoteHandler = scope != null ? scope.handler : onQuoteImage;
    final fullUrl = image.lightboxUrl ?? resolvedUrl;
    final resolvedFullUrl = DiscourseImageUtils.isUploadUrl(fullUrl)
        ? (DiscourseImageUtils.getCachedUploadUrl(fullUrl) ?? fullUrl)
        : UrlHelper.resolveUrlWithCdn(fullUrl);
    final menuUrl = DiscourseImageUtils.getOriginalUrl(resolvedFullUrl);
    ImageContextMenu.show(
      context: context,
      imageUrl: menuUrl,
      post: post,
      topicId: topicId,
      onQuoteImage: liveQuoteHandler,
      position: position,
      heroTag: heroTag,
    );
  }

  /// 用 jovial_svg 把内容 svg 源串渲染成等比铺满列宽的 widget。
  ///
  /// 逐字对齐 legacy `_buildInlineSvg`(discourse_html_content_widget.dart):
  /// 解析失败 / viewport 非法 → SizedBox.shrink();否则 LayoutBuilder 取可用宽,
  /// 按 viewport 宽高比算高,SizedBox + ScalableImageWidget(fit: contain)。
  ///
  /// 含动画的 SVG(CSS @keyframes/SMIL,jovial 渲染会所有帧叠加糊成一团)
  /// 路由到 AnimatedSvgView(full_svg_flutter,首帧快照 + 点击播放,
  /// 组件自持 viewBox 宽高比)。
  ///
  /// prefers-color-scheme 媒询按当前主题预求值(引擎不认媒询,
  /// 不求值则暗色规则整块丢失,永远渲染亮色)。
  static Widget _buildInlineSvgFromSource(String svgSource) {
    if (svgSource.trim().isEmpty) return const SizedBox.shrink();

    return Builder(
      builder: (context) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final resolved = SvgUtils.resolveColorSchemeMedia(
          svgSource,
          dark: dark,
        );

        if (AnimatedSvgView.hasAnimations(resolved)) {
          return AnimatedSvgView(svgSource: resolved);
        }

        final ScalableImage si;
        try {
          si = ScalableImage.fromSvgString(resolved, warnF: (_) {});
        } catch (_) {
          return const SizedBox.shrink();
        }
        final viewport = si.viewport;
        if (viewport.width <= 0 || viewport.height <= 0) {
          return const SizedBox.shrink();
        }
        final aspectRatio = viewport.width / viewport.height;
        return LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.of(context).size.width - 32;
            final displayWidth = availableWidth;
            final displayHeight = displayWidth / aspectRatio;
            return SizedBox(
              width: displayWidth,
              height: displayHeight,
              child: ScalableImageWidget(si: si, fit: BoxFit.contain),
            );
          },
        );
      },
    );
  }

  static bool _isSvgUrl(String? url) {
    if (url == null) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.path.toLowerCase().endsWith('.svg');
  }
}

/// 全帖 lightbox 画廊数据(原图 URL / 缩略图 / heroTag 按 lightbox 出现顺序;
/// indexByImageIndex 把 ImageRun.indexInPost 映射到画廊序号)。
/// 由 forPost 的 resolveGallery 惰性构建,首次点图触发。
typedef _GalleryData = ({
  List<String> urls,
  List<String> thumbs,
  List<String> heroTags,
  Map<int, int> indexByImageIndex,
});

/// 异步高亮 widget:HighlighterService.highlightAsync 是 Future,
/// 期间用纯 monospace 占位,完成后用 RichText 渲染高亮 token。
class _AsyncHighlightedCode extends StatefulWidget {
  const _AsyncHighlightedCode({required this.code, required this.language});
  final String code;
  final String? language;

  @override
  State<_AsyncHighlightedCode> createState() => _AsyncHighlightedCodeState();
}

class _AsyncHighlightedCodeState extends State<_AsyncHighlightedCode> {
  List<HighlightToken>? _tokens;
  // memoize:span 树只在 tokens / 明暗切换时重建,普通 build 直接复用。
  // 大代码块 tokensToSpan 是主线程大头,不能每帧重算。
  TextSpan? _span;
  bool? _spanIsDark;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_AsyncHighlightedCode old) {
    super.didUpdateWidget(old);
    if (old.code != widget.code || old.language != widget.language) {
      _tokens = null;
      _span = null;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    // 网页端同款熔断:超大块 / lang-auto 大块保持纯 monospace,
    // 提前短路连 isolate 往返都省掉。
    if (HighlighterService.instance.shouldSkipHighlight(
      widget.code,
      widget.language,
    )) {
      return;
    }
    try {
      final tokens = await HighlighterService.instance.highlightAsync(
        widget.code,
        language: widget.language,
      );
      if (mounted) {
        setState(() {
          _tokens = tokens;
          _span = null;
        });
      }
    } catch (_) {
      // 高亮失败:保持 null,fallback 显示纯 monospace
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final baseStyle = TextStyle(
      fontFamily: 'FiraCode',
      fontFamilyFallback: const ['monospace', 'Menlo', 'Courier'],
      fontSize: 13,
      height: 1.4,
      color: theme.colorScheme.onSurface,
    );
    if (_tokens == null) {
      return Text(widget.code, style: baseStyle);
    }
    if (_span == null || _spanIsDark != isDark) {
      _span = HighlighterService.instance.tokensToSpan(
        _tokens!,
        isDark: isDark,
        baseStyle: baseStyle,
      );
      _spanIsDark = isDark;
    }
    return Text.rich(_span!);
  }
}

/// Mermaid 图表块(纯主项目侧,经子包 CodeBlockBuilder 整块接管,UI 照搬
/// legacy `code_block_builder.dart` 的 `_MermaidWidget`):
/// 灰底容器(282a36/f6f8fa)+ 顶栏「图表⇄代码」切换 + 复制按钮;
/// 图表态 mermaid.ink 服务端出图(懒加载 shimmer / 错误重试 / 点开高清
/// width=2000),代码态 HighlighterService 高亮源码。
///
/// 与 legacy 的差异:
/// 1. screenshotMode 不走构造参数,读子包 [ScreenshotMode] InheritedWidget
///    (离屏渲染时立即出图、代码态不限高)。
/// 2. **固定高度内容框**:对齐官方 mermaid 主题组件 `.mermaid-wrapper` 的
///    `aspect-ratio: 16/9` —— shimmer / 出图 / 错误 / 代码态都在同一个
///    16:9 框内(图 contain 缩放进框,代码框内滚动),加载完成或切换视图
///    都不改块高,页面不抖。
class _MermaidBlock extends StatefulWidget {
  const _MermaidBlock({required this.code});

  /// 原始 mermaid 源码(子包已剥掉 ```mermaid 包裹,等于 legacy 的 text)。
  final String code;

  @override
  State<_MermaidBlock> createState() => _MermaidBlockState();
}

class _MermaidBlockState extends State<_MermaidBlock> {
  bool _showCode = false;
  bool _shouldLoad = false;
  bool _initialized = false;
  int _retryCount = 0;

  /// 出图源:0 = kroki.io(主),1 = mermaid.ink(备)。
  /// 主源加载失败自动 +1 降级;手动重试归零从主源重来。
  int _sourceIndex = 0;
  final _vController = ScrollController();
  final _hController = ScrollController();

  // 缓存 key:对齐 legacy 'mermaid-${text.hashCode}',用于 LazyLoadScope。
  String get _cacheKey => 'mermaid-${widget.code.hashCode}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      // 已在本页 LazyLoadScope 里加载过则直接出图。
      // 截图模式(离屏渲染)下 VisibilityDetector 永不触发,读 ScreenshotMode
      // 直接立即出图,避免分享成图截到 shimmer 占位。
      if (LazyLoadScope.isLoaded(context, _cacheKey) ||
          ScreenshotMode.of(context)) {
        _shouldLoad = true;
      }
    }
  }

  @override
  void dispose() {
    _vController.dispose();
    _hController.dispose();
    super.dispose();
  }

  void _triggerLoad() {
    if (!_shouldLoad) {
      LazyLoadScope.markLoaded(context, _cacheKey);
      setState(() => _shouldLoad = true);
    }
  }

  void _retry() => setState(() {
    _retryCount++;
    _sourceIndex = 0; // 重试从主源(kroki)重来
  });

  /// kroki.io 出图 URL(主源):`GET /mermaid/{png|svg}/{zlib+base64url}?theme=`。
  ///
  /// 实测(2026-07-09)mermaid.ink 在国内网络已不可达(15s 超时),
  /// kroki.io 稳定 ~1s;PNG 透明背景(左上像素 alpha=0 实测),直接透出
  /// 容器灰底;`?theme=dark/default` 实测生效,对齐 legacy 两档。
  /// PNG 只有 1x(公共实例 scale/width 不生效),高清查看走 [svg] 矢量
  /// (含 foreignObject,只能 WebView 渲,见 MermaidViewerPage)。
  String _buildKrokiUrl(String code, bool isDark, {bool svg = false}) {
    final compressed = const ZLibEncoder().encodeBytes(
      utf8.encode(code),
      level: 9,
    );
    final encoded = base64Url.encode(compressed);
    final theme = isDark ? 'dark' : 'default';
    final format = svg ? 'svg' : 'png';
    return 'https://kroki.io/mermaid/$format/$encoded?theme=$theme';
  }

  /// mermaid.ink 出图 URL(备源 + 高清):逐字照搬 legacy
  /// _buildMermaidInkUrl:base64url(utf8) + theme(dark/default)+
  /// bgColor(282a36/f6f8fa)+ 可选 width。
  String _buildMermaidInkUrl(String code, bool isDark, {int? width}) {
    final encoded = base64Url.encode(utf8.encode(code));
    final theme = isDark ? 'dark' : 'default';
    final bgColor = isDark ? '282a36' : 'f6f8fa';
    var url = 'https://mermaid.ink/img/$encoded?theme=$theme&bgColor=$bgColor';
    if (width != null) url += '&width=$width';
    return url;
  }

  /// shimmer 占位(铺满固定内容框,1500ms 线性渐变,RepaintBoundary 隔离重绘)。
  /// controller 由 [_MermaidShimmer] 自持:占位被真图/代码态替换即随 State
  /// dispose,不会出图后继续空转产帧(旧版 controller 挂在块 State 上,
  /// 出图后无人 stop,每个已渲染 mermaid 块都是常驻帧生产者)。
  Widget _buildShimmer(ThemeData theme, {bool withMargin = true}) {
    return _MermaidShimmer(theme: theme, withMargin: withMargin);
  }

  /// 代码态:HighlighterService 高亮 mermaid 源码,在固定内容框内双向滚动。
  /// 截图模式不滚动、自动换行(块高仍由外层固定框决定)。
  Widget _buildCodeView(bool isDark, Color thumbColor, bool screenshotMode) {
    if (screenshotMode) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: HighlighterService.instance.buildHighlightView(
          widget.code,
          language: 'mermaid',
          isDark: isDark,
          backgroundColor: Colors.transparent,
          padding: EdgeInsets.zero,
        ),
      );
    }
    return Align(
      alignment: Alignment.topLeft,
      child: RawScrollbar(
        controller: _vController,
        thumbVisibility: false,
        thickness: 4,
        radius: const Radius.circular(2),
        thumbColor: thumbColor,
        child: SingleChildScrollView(
          controller: _vController,
          child: RawScrollbar(
            controller: _hController,
            thumbVisibility: false,
            thickness: 4,
            thumbColor: thumbColor,
            child: SingleChildScrollView(
              controller: _hController,
              scrollDirection: Axis.horizontal,
              child: HighlighterService.instance.buildHighlightView(
                widget.code,
                language: 'mermaid',
                isDark: isDark,
                backgroundColor: Colors.transparent,
                padding: const EdgeInsets.all(12),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 图表态:懒加载 → 服务端出图(contain 缩放进固定内容框,点开高清,
  /// 失败可重试)。占位 / 出图 / 错误共用同一个框,高度不变。
  ///
  /// 双源降级:kroki.io 主源(国内可达 ~1s)→ 失败自动切 mermaid.ink
  /// 备源 → 再失败出错误 UI(重试从主源重来)。点开高清按当前生效源:
  /// ink 支持 width=2000;kroki 公共实例无高清参数(scale/width 实测
  /// 不生效),开原图靠手势放大。
  Widget _buildChartView(ThemeData theme, bool isDark) {
    if (!_shouldLoad) {
      return VisibilityDetector(
        key: Key('mermaid-$_cacheKey'),
        onVisibilityChanged: (info) {
          if (!_shouldLoad && info.visibleFraction > 0.01) {
            _triggerLoad();
          }
        },
        child: _buildShimmer(theme),
      );
    }
    final onInk = _sourceIndex > 0;
    final imageUrl = onInk
        ? _buildMermaidInkUrl(widget.code, isDark)
        : _buildKrokiUrl(widget.code, isDark);
    return GestureDetector(
      onTap: () {
        // 点图 = 位图查看器(手势/保存/分享体验成熟)。高清:ink 可达时
        // width=2000;kroki 只有 1x(公共实例 scale/width 不生效),大图
        // 看细节走顶栏「放大」按钮的矢量查看页(SVG 缩放不糊)。
        final hdUrl = onInk
            ? _buildMermaidInkUrl(widget.code, isDark, width: 2000)
            : imageUrl;
        ImageViewerPage.open(context, hdUrl, enableShare: true);
      },
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Image(
          key: ValueKey('$imageUrl-$_retryCount'),
          image: BlobImageProvider(
            imageUrl,
            bucket: BlobImageCache.externalBucket,
          ),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSync) {
            if (wasSync || frame != null) return child;
            return _buildShimmer(theme, withMargin: false);
          },
          errorBuilder: (context, error, stack) {
            if (!onInk) {
              // 主源失败 → 下一帧切备源(build 内不能直接 setState)
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _sourceIndex == 0) {
                  setState(() => _sourceIndex = 1);
                }
              });
              return _buildShimmer(theme, withMargin: false);
            }
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Symbols.error_rounded, color: theme.colorScheme.error),
                  const SizedBox(height: 8),
                  Text(
                    S.current.codeBlock_chartLoadFailed,
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Symbols.refresh_rounded, size: 16),
                    label: Text(S.current.common_retry),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final screenshotMode = ScreenshotMode.of(context);
    final bgColor = isDark ? const Color(0xff282a36) : const Color(0xfff6f8fa);
    final borderColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.3);
    final thumbColor = (isDark ? Colors.white : Colors.black).withValues(
      alpha: 0.15,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: bgColor,
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 工具栏:「图表⇄代码」切换 + 复制(不参与选区)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: borderColor)),
            ),
            child: Row(
              children: [
                InkWell(
                  onTap: () => setState(() => _showCode = !_showCode),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _showCode
                              ? Symbols.auto_graph_rounded
                              : Symbols.code_rounded,
                          size: 16,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.7,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _showCode
                              ? S.current.codeBlock_chart
                              : S.current.codeBlock_code,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.7,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                // 矢量放大(仅图表态):kroki SVG + WebView,大图任意
                // 缩放不糊 —— kroki PNG 恒 1x,mindmap 等大图位图必糊。
                if (!_showCode)
                  InkWell(
                    onTap: () {
                      MermaidViewerPage.open(
                        context,
                        svgUrl: _buildKrokiUrl(widget.code, isDark, svg: true),
                        fallbackImageUrl: _sourceIndex > 0
                            ? _buildMermaidInkUrl(
                                widget.code,
                                isDark,
                                width: 2000,
                              )
                            : _buildKrokiUrl(widget.code, isDark),
                      );
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Symbols.pan_zoom_rounded,
                        size: 16,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: widget.code));
                    ToastService.showSuccess(S.current.common_codeCopied);
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Symbols.content_copy_rounded,
                      size: 16,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 内容区域:16:9 固定高度框(对齐官方 mermaid 主题组件
          // .mermaid-wrapper 的 aspect-ratio: 16/9)。shimmer / 出图 /
          // 错误 / 代码态共用同一个框 → 加载完成或切视图块高不变,页面不抖。
          ClipRRect(
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(8),
              bottomRight: Radius.circular(8),
            ),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: _showCode
                  ? _buildCodeView(isDark, thumbColor, screenshotMode)
                  : _buildChartView(theme, isDark),
            ),
          ),
        ],
      ),
    );
  }
}

/// mermaid shimmer 占位:controller 自持,占位从树上移除即 dispose,
/// 保证"占位在=动画在,占位走=帧调度停"。
class _MermaidShimmer extends StatefulWidget {
  const _MermaidShimmer({required this.theme, required this.withMargin});

  final ThemeData theme;
  final bool withMargin;

  @override
  State<_MermaidShimmer> createState() => _MermaidShimmerState();
}

class _MermaidShimmerState extends State<_MermaidShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Container(
            margin: widget.withMargin ? const EdgeInsets.all(12) : null,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: LinearGradient(
                begin: Alignment(-1.0 + 2.0 * _controller.value, 0),
                end: Alignment(-0.5 + 2.0 * _controller.value, 0),
                colors: [
                  theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.3,
                  ),
                  theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.6,
                  ),
                  theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.3,
                  ),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// HTML 字符串 → dom.Element 的最薄 helper。
///
/// 用 html 包 parseFragment 构 element,给 legacy build* 函数喂入参。
/// 每个 _xxxElementFrom 反构造的字符串精确还原 cooked 关键结构 +
/// data-* 属性 + 子节点;后续 legacy 函数只读这些(不依赖 fullHtml)。
dom.Element _elementFromHtml(String html) {
  final frag = html_parser.parseFragment(html);
  return frag.children.first;
}

/// 把 LazyVideoNode 反构造成 `<div class="lazy-video-container" ...>`。
dom.Element _lazyVideoElementFrom(LazyVideoNode node) {
  final providerName = node.provider == LazyVideoProvider.other
      ? ''
      : node.provider.name;
  final buf = StringBuffer()
    ..write('<div class="lazy-video-container"')
    ..write(' data-provider-name="${_attr(providerName)}"')
    ..write(' data-video-id="${_attr(node.videoId)}"')
    ..write(' data-video-title="${_attr(node.title)}"')
    ..write(' data-video-start-time="${_attr(node.startTime)}"')
    ..write('>');
  if (node.url.isNotEmpty) {
    buf.write('<a class="title-link" href="${_attr(node.url)}">');
  }
  if (node.thumbnailUrl.isNotEmpty) {
    buf.write('<img src="${_attr(node.thumbnailUrl)}">');
  }
  if (node.url.isNotEmpty) buf.write('</a>');
  buf.write('</div>');
  return _elementFromHtml(buf.toString());
}

/// 把 LocalDateRun 反构造成 `<span class="discourse-local-date" ...>`。
dom.Element _localDateElementFrom(LocalDateRun node) {
  final buf = StringBuffer('<span class="discourse-local-date"')
    ..write(' data-date="${_attr(node.date)}"');
  if (node.time != null) buf.write(' data-time="${_attr(node.time!)}"');
  if (node.timezone != null) {
    buf.write(' data-timezone="${_attr(node.timezone!)}"');
  }
  if (node.timezones.isNotEmpty) {
    buf.write(' data-timezones="${_attr(node.timezones.join('|'))}"');
  }
  if (node.format != null) {
    buf.write(' data-format="${_attr(node.format!)}"');
  }
  if (node.displayedTimezone != null) {
    buf.write(' data-displayed-timezone="${_attr(node.displayedTimezone!)}"');
  }
  if (node.countdown) buf.write(' data-countdown');
  if (node.range != null) buf.write(' data-range="${_attr(node.range!)}"');
  buf.write('>${_escape(node.fallbackText)}</span>');
  return _elementFromHtml(buf.toString());
}

/// 把 PolicyNode 反构造成 `<div class="policy" data-*>` + 子节点 HTML。
///
/// children 是 BlockNode 树,这里不还原 — 直接用 outerHtml 的"占位 body"
/// 让 legacy buildPolicy 通过 element.innerHtml 走 htmlBuilder。
/// htmlBuilder 接嵌套 FluxdoRender 渲染,所以 body html 必须是
/// **原始 cooked HTML 片段**。我们没法从 BlockNode 反向重建,所以这里
/// fallback 用 textContent 拼接(legacy 在 callback 内会 fallback 渲染)。
///
/// **代价**:cell 内富文本(链接/strong/em 等)会丢样式。
/// **改善方向**:子包 PolicyNode 应该存原始 bodyHtml(类似 OneboxNode.rawHtml),
/// 让主项目 builder 完整复用 legacy。当前先不要求 — 后续 dogfood 看实际效果。
dom.Element _policyElementFrom(PolicyNode node) {
  final buf = StringBuffer('<div class="policy"');
  if (node.version != null) {
    buf.write(' data-version="${_attr(node.version!)}"');
  }
  if (node.groups != null) {
    buf.write(' data-groups="${_attr(node.groups!)}"');
  }
  if (node.acceptLabel != null) {
    buf.write(' data-accept="${_attr(node.acceptLabel!)}"');
  }
  if (node.revokeLabel != null) {
    buf.write(' data-revoke="${_attr(node.revokeLabel!)}"');
  }
  if (node.renewalDays != null) {
    buf.write(' data-renewal-days="${_attr(node.renewalDays!)}"');
  }
  if (node.renewalStart != null) {
    buf.write(' data-renewal-start="${_attr(node.renewalStart!)}"');
  }
  if (node.reminder != null) {
    buf.write(' data-reminder="${_attr(node.reminder!)}"');
  }
  if (node.isPrivate) buf.write(' data-private="true"');
  buf.write('>');
  // body:遍历 children 输出 outerHtml(BlockNode 没有 outerHtml 概念,
  // 用 toString 兜底;legacy htmlBuilder 收到后嵌套 FluxdoRender
  // 走 fallback paragraph 渲染)
  for (final c in node.children) {
    buf.write('<p>${_escape(c.toString())}</p>');
  }
  buf.write('</div>');
  return _elementFromHtml(buf.toString());
}

/// 简单转义 attribute 值(只处理双引号 + < + >,够用于 attr 字符串)。
String _attr(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// 转义文本内容(用于 textContent)。
String _escape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// 注入 mention 状态 emoji(对齐 legacy discourse_html_content_widget
/// _preprocessHtml 第 243-264 行)。原始 cooked 的 mention 链接不含状态
/// emoji,这里按 mentionedUsers[].statusEmoji 在 `</a>` 前插入
/// `<img class="emoji mention-status">`。
String _injectMentionStatusEmoji(
  String html,
  List<MentionedUser>? mentionedUsers,
) {
  if (mentionedUsers == null || mentionedUsers.isEmpty) return html;
  var result = html;
  for (final user in mentionedUsers) {
    final emoji = user.statusEmoji;
    if (emoji == null || emoji.isEmpty) continue;
    final emojiUrl = EmojiHandler().getEmojiUrl(emoji);
    final escapedUsername = RegExp.escape(user.username);
    final pattern = RegExp(
      '(<a[^>]*class="[^"]*mention[^"]*"[^>]*href="[^"]*\\/u\\/$escapedUsername"[^>]*>)(@[^<]*)(</a>)',
      caseSensitive: false,
    );
    result = result.replaceAllMapped(pattern, (match) {
      final openTag = match.group(1)!;
      final content = match.group(2)!;
      final closeTag = match.group(3)!;
      return '$openTag$content'
          '<img src="$emojiUrl" class="emoji mention-status" '
          'style="width:14px;height:14px;vertical-align:middle;margin-left:2px">'
          '$closeTag';
    });
  }
  return result;
}

/// 注入链接点击数(对齐 legacy discourse_html_content_widget
/// _injectClickCounts 第 333-359 行)。按 linkCounts 在匹配 URL 的普通
/// `<a>` 后追加 `<span class="click-count">`,用 data-clicks 防重复。
String _injectClickCounts(String html, List<LinkCount>? linkCounts) {
  if (linkCounts == null || linkCounts.isEmpty) return html;
  var result = html;
  for (final lc in linkCounts) {
    if (lc.clicks <= 0) continue;
    final escapedUrl = RegExp.escape(lc.url);
    final pattern = RegExp(
      '(<a(?![^>]*data-clicks)[^>]*href="[^"]*$escapedUrl[^"]*"[^>]*>)'
      '(.*?)(</a>)(?!\\s*<span[^>]*class="[^"]*click-count)',
      caseSensitive: false,
    );
    final formatted = _formatClickCount(lc.clicks);
    result = result.replaceAllMapped(pattern, (match) {
      final openTag = match.group(1)!;
      final content = match.group(2)!;
      final closeTag = match.group(3)!;
      final newOpenTag = openTag.replaceFirst(
        '<a',
        '<a data-clicks="$formatted"',
      );
      return '$newOpenTag$content$closeTag'
          ' <span class="click-count"> $formatted </span>';
    });
  }
  return result;
}

/// 点击数格式化(对齐 legacy _formatClickCount):>=1000 显示 "N.Nk"。
String _formatClickCount(int count) {
  if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}k';
  return count.toString();
}

/// 视频初始化失败的降级卡:失败提示 + 点击用浏览器打开。
///
/// 此前失败路径是 SizedBox.shrink() —— 视频区域直接空白,用户既看
/// 不到视频也无从知道失败了(macOS 的 AVFoundation 对签名 URL/容器
/// 细节远比 Android ExoPlayer 挑剔,"桌面端看不到视频"多半落在这)。
/// 卡片外层由 DiscourseVideoPlayer 的 AspectRatio 约束,自动占位。
class _VideoErrorFallback extends StatelessWidget {
  const _VideoErrorFallback({required this.url, this.error});

  final String url;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => launchInExternalBrowser(url),
      child: Container(
        alignment: Alignment.center,
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Symbols.videocam_off_rounded,
              size: 32,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                S.current.post_videoLoadFailed,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
