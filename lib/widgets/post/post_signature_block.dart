import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/topic.dart';
import '../../providers/preferences_provider.dart';
import '../../services/preloaded_data_service.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../content/discourse_image.dart';
import '../content/signature_animation_scope.dart';

/// 帖子底部的用户签名区块（discourse-signatures 插件）。
///
/// 门禁与网页端 PostSignature.shouldRender 同构：
/// 服务端 signatures_enabled × 本地 showSignatures × 签名非空
/// × first_post_only × show_in_categories。
///
/// 渲染形态对齐网页端：
/// - advanced 模式（签名为 cooked HTML）→ FluxdoRender 完整富文本，不截断；
/// - 普通模式（签名为图片 URL）→ 单图，限高 signatures_max_image_height。
///
/// Stateful：callbacks 必须跨 rebuild 保持 identical——FluxdoRender 用
/// identical() 判定渲染配置变化，每 build 新建闭包会击穿其块缓存，
/// 造成全列表每帧重建（曾引发整页 jank）。
class PostSignatureBlock extends ConsumerStatefulWidget {
  final Post post;

  /// 话题分类 id，用于 signatures_show_in_categories 门禁；
  /// 调用方拿不到时传 null（跳过分类过滤）。
  final int? categoryId;

  /// 弱化文字字号（正文签名 12，嵌套卡 11）。
  final double fontSize;

  /// 分隔线上下留白。
  final double spacing;

  const PostSignatureBlock({
    super.key,
    required this.post,
    this.categoryId,
    this.fontSize = 12,
    this.spacing = 8,
  });

  /// 是否应渲染签名（供调用方在外层 if 中短路，避免空 Padding）。
  static bool shouldRender(WidgetRef ref, Post post, {int? categoryId}) {
    final preloaded = PreloadedDataService();
    if (!preloaded.signaturesEnabled) return false;
    if (!ref.watch(preferencesProvider).showSignatures) return false;
    final signature = post.effectiveSignature;
    if (signature == null) return false;
    // URL 模式:必须是合法绝对 http(s) URL。插件端同款校验只在
    // user_updated 时清理,历史脏数据(任意纯文本)会一直残留在
    // signature_url 里;网页 img 加载失败被浏览器折叠不可见,
    // app 端若照渲染就是一块裂图——直接不渲染。
    if (!preloaded.signaturesAdvancedMode && !_isValidImageUrl(signature)) {
      return false;
    }
    if (preloaded.signaturesFirstPostOnly && post.postNumber != 1) {
      return false;
    }
    final categories = preloaded.signaturesShowInCategories;
    if (categories.isNotEmpty &&
        (categoryId == null || !categories.contains(categoryId))) {
      // 与网页同语义:配置了分类白名单时,不在名单内(含拿不到分类)即隐藏
      return false;
    }
    return true;
  }

  static bool _isValidImageUrl(String s) {
    final uri = Uri.tryParse(s.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  @override
  ConsumerState<PostSignatureBlock> createState() => _PostSignatureBlockState();
}

class _PostSignatureBlockState extends ConsumerState<PostSignatureBlock> {
  FluxdoRenderCallbacks? _callbacks;
  int? _callbacksPostId;

  FluxdoRenderCallbacks _callbacksFor(Post post) {
    if (_callbacks == null || _callbacksPostId != post.id) {
      _callbacks = FluxdoRenderCallbacks.generic(
        heroTagNamespace: 'signature-${post.id}',
      );
      _callbacksPostId = post.id;
    }
    return _callbacks!;
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final signature = post.effectiveSignature;
    if (signature == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final preloaded = PreloadedDataService();
    final adaptiveFrameRate = ref.watch(
      preferencesProvider.select(
        (preferences) => preferences.adaptiveSignatureFrameRate,
      ),
    );

    // URL 模式:user_signature 是图片地址(advanced 关)。合法性已由
    // shouldRender 把关;此处兜底——非法地址(历史脏数据可为任意
    // 文本)直接不渲染,不给裂图机会。
    if (!preloaded.signaturesAdvancedMode) {
      if (!PostSignatureBlock._isValidImageUrl(signature)) {
        return const SizedBox.shrink();
      }
    }
    final isImageUrl =
        !preloaded.signaturesAdvancedMode && post.userSignature != null;

    final Widget content;
    if (isImageUrl) {
      // 网页 .signature-img 语义:max-height 是**上限**——矮图按自然
      // 高度贴内容,高图封顶在 signatures_max_image_height。稳定性由
      // 管线的会话缓存承担(DiscourseSvgView/嗅探 verdict 同步恢复,
      // 重挂载不跳);首次加载的一次性落位与浏览器行为一致。
      //
      // 加载失败静默折叠(对齐浏览器:img 加载失败无可见占位)——
      // 签名服务是第三方自建,离线/域名失效很常见,一块裂图占位
      // 比没有签名难受得多。
      content = Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: preloaded.signaturesMaxImageHeight,
          ),
          child: _SilentlyCollapsingImage(url: signature),
        ),
      );
    } else {
      content = _callbacksFor(post).render(
        cookedHtml: signature,
        baseTextStyle: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          fontSize: widget.fontSize,
          height: 1.4,
        ),
        selectionEnabled: false,
      );
    }

    return Padding(
      padding: EdgeInsets.only(top: widget.spacing),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.only(top: widget.spacing),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
              width: 0.5,
            ),
          ),
        ),
        child: SignatureAnimationScope(
          adaptiveFrameRate: adaptiveFrameRate,
          child: content,
        ),
      ),
    );
  }
}

/// 加载失败时静默折叠为零尺寸的签名图。
///
/// 对齐浏览器行为:无尺寸声明的 img 加载中不占空间、失败(服务离线、
/// 域名失效等)折叠为零——分隔线仍在(与网页一致,<hr> 不随图片失败
/// 消失),不出现裂图占位块。
///
/// 注:曾按"linux.do 下发 COEP: require-corp"做过跨域 CORP/CORS 预检
/// 闸门,后证伪——那个响应头取自 Cloudflare challenge 盾页而非真实
/// 页面(x-archive-orig-cf-mitigated: challenge),真实页面无 COEP,
/// 第三方签名图网页可正常显示。已撤销,勿再按盾页响应头归因站点配置。
class _SilentlyCollapsingImage extends StatefulWidget {
  final String url;

  const _SilentlyCollapsingImage({required this.url});

  @override
  State<_SilentlyCollapsingImage> createState() =>
      _SilentlyCollapsingImageState();
}

class _SilentlyCollapsingImageState extends State<_SilentlyCollapsingImage> {
  /// url → 已知失败(会话级;失败的签名服务不反复重试拉起占位)。
  static final Set<String> _knownBroken = <String>{};

  @override
  Widget build(BuildContext context) {
    if (_knownBroken.contains(widget.url)) return const SizedBox.shrink();
    return DiscourseImage(
      url: widget.url,
      fit: BoxFit.scaleDown,
      // 浏览器语义:无尺寸声明的 img 加载中不占空间、失败折叠为零。
      // 加载阶段没有占位 spinner,失败后仅剩分隔线:成功才发生落位。
      placeholderBuilder: (_) => const SizedBox.shrink(),
      errorBuilder: (_) {
        _knownBroken.add(widget.url);
        return const SizedBox.shrink();
      },
    );
  }
}
