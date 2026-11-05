import 'package:fluxdo/utils/avatar_url.dart';
import 'package:flutter/material.dart';
import '../../models/topic.dart';
import '../../utils/url_helper.dart';
import '../common/radial_long_press_menu.dart';
import '../common/smart_avatar.dart';
import '../user/avatar_action_menu.dart';
import '../user/user_card.dart';

/// 嵌套帖子左侧头像（点击弹出用户卡片，长按弹出径向操作菜单）
class NestedPostAvatar extends StatefulWidget {
  final String avatarTemplate;
  final String username;
  final Post? post;
  final int? topicId;

  /// 长按菜单「@用户」回调（null = 不可回复，菜单不显示该项）
  final void Function(String username)? onMentionUser;
  static const double size = 24.0;

  static String resolveUrl(String avatarTemplate) {
    return UrlHelper.resolveUrlWithCdn(
      AvatarUrl.resolve(avatarTemplate, size: 48),
    );
  }

  const NestedPostAvatar({
    super.key,
    required this.avatarTemplate,
    required this.username,
    this.post,
    this.topicId,
    this.onMentionUser,
  });

  @override
  State<NestedPostAvatar> createState() => _NestedPostAvatarState();
}

class _NestedPostAvatarState extends State<NestedPostAvatar> {
  final LayerLink _link = LayerLink();

  void _openUserCard() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final anchorRect = box.localToGlobal(Offset.zero) & box.size;
    showUserCard(
      context: context,
      anchorRect: anchorRect,
      layerLink: _link,
      username: widget.username,
      topicId: widget.topicId,
      postNumber: widget.post?.postNumber,
      avatarFallbackUrl:
          widget.post?.getAvatarUrl(size: 144) ??
          NestedPostAvatar.resolveUrl(widget.avatarTemplate),
      nameFallback: widget.post?.name,
      flairUrl: widget.post?.flairUrl,
      flairName: widget.post?.flairName,
      flairBgColor: widget.post?.flairBgColor,
      flairColor: widget.post?.flairColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = widget.avatarTemplate.isNotEmpty
        ? UrlHelper.resolveUrlWithCdn(
            AvatarUrl.resolve(widget.avatarTemplate, size: 48),
          )
        : null;
    return RadialLongPressMenu(
      onTap: _openUserCard,
      itemsBuilder: () => buildAvatarMenuItems(
        context,
        username: widget.username,
        topicId: widget.topicId,
        postNumber: widget.post?.postNumber,
        onMentionUser: widget.onMentionUser,
      ),
      pressAreaIndicatorBuilder: (ctx, rect, opacity) => Opacity(
        opacity: opacity,
        child: SmartAvatar(
          imageUrl: imageUrl,
          radius: rect.shortestSide / 2,
          fallbackText: widget.username,
          border: Border.all(color: Theme.of(ctx).colorScheme.primary, width: 2),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: SmartAvatar(
          imageUrl: imageUrl,
          radius: NestedPostAvatar.size / 2,
          fallbackText: widget.username,
        ),
      ),
    );
  }
}
