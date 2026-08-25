import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/selected_topic_provider.dart';
import '../../services/toast_service.dart';
import '../../utils/share_utils.dart';
import '../common/radial_long_press_menu.dart';
import '../post/reply_sheet.dart';

/// 复制用户名到剪贴板并 toast + 轻触觉（长按菜单/用户卡片/用户主页共用）
void copyUsernameToClipboard(String username) {
  Clipboard.setData(ClipboardData(text: username));
  HapticFeedback.selectionClick();
  ToastService.showSuccess(S.current.common_copiedToClipboard);
}

/// 打开「给指定用户发私信」编辑器。
///
/// 带话题上下文（[topicId]/[postNumber]）时正文预填帖子链接、
/// 标题预填「回复:话题标题」（[topicTitle] 为空时回退话题会话状态）。
void composeMessageToUser({
  required BuildContext context,
  required String username,
  int? topicId,
  int? postNumber,
  String? topicTitle,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final prefs = container.read(preferencesProvider);
  final currentUsername = container.read(currentUserProvider).value?.username;

  String? body;
  if (topicId != null && postNumber != null) {
    body = ShareUtils.buildShareUrl(
      path: '/t/$topicId/$postNumber',
      username: currentUsername,
      anonymousShare: prefs.anonymousShare,
    );
  }
  // 标题优先用传入的 topicTitle，否则从话题会话状态读取（基于话题的私信预填「回复:标题」）
  final resolvedTitle =
      topicTitle ??
      (topicId != null
          ? container.read(topicSessionProvider(topicId)).topicTitle
          : null);
  final title = (resolvedTitle != null && resolvedTitle.isNotEmpty)
      ? S.current.userCard_referenceTopicTitle(resolvedTitle)
      : null;

  showReplySheet(
    context: context,
    targetUsername: username,
    initialContent: body,
    initialTitle: title,
  );
}

/// 构建头像长按径向菜单项（长按触发瞬间调用）。
///
/// - 进入主页 / 复制用户名：总是显示
/// - 私信：已登录且当前用户可发私信且非自己（目标用户级能力此时未知，
///   对方关闭私信时由发送阶段服务端报错 + ErrorInterceptor 兜底）
/// - @用户：[onMentionUser] 非 null（链路可回复）且非自己
/// - 只看此人：有话题上下文时显示(发帖数此时未知,不设官方 ≥2 帖门
///   槛;已在过滤该用户时变「取消只看」)
List<RadialMenuItem> buildAvatarMenuItems(
  BuildContext context, {
  required String username,
  int? topicId,
  int? postNumber,
  String? topicTitle,
  void Function(String username)? onMentionUser,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final currentUser = container.read(currentUserProvider).value;
  final isSelf = currentUser != null && currentUser.username == username;
  final canMessage =
      currentUser != null &&
      currentUser.canSendPrivateMessages != false &&
      !isSelf;

  // 话题内过滤状态:决定「只看此人/取消只看」形态
  bool isFilteringThisUser = false;
  bool canFilter = false;
  if (topicId != null) {
    final params = TopicDetailNotifier.activeParamsFor(topicId);
    if (params != null && container.exists(topicDetailProvider(params))) {
      canFilter = true;
      isFilteringThisUser =
          container.read(topicDetailProvider(params).notifier).usernameFilter ==
          username;
    }
  }

  return [
    RadialMenuItem(
      icon: Symbols.account_circle_rounded,
      label: S.current.avatarMenu_viewProfile,
      onSelected: () => EmbeddedStackScope.openProfile(context, username),
    ),
    if (canMessage)
      RadialMenuItem(
        icon: Symbols.mail_rounded,
        label: S.current.userProfile_message,
        onSelected: () => composeMessageToUser(
          context: context,
          username: username,
          topicId: topicId,
          postNumber: postNumber,
          topicTitle: topicTitle,
        ),
      ),
    if (onMentionUser != null && !isSelf)
      RadialMenuItem(
        icon: Symbols.alternate_email_rounded,
        label: S.current.avatarMenu_mention,
        onSelected: () => onMentionUser(username),
      ),
    if (canFilter)
      RadialMenuItem(
        icon: isFilteringThisUser
            ? Symbols.filter_list_off_rounded
            : Symbols.filter_list_rounded,
        label: isFilteringThisUser
            ? S.current.avatarMenu_cancelFilterPosts
            : S.current.avatarMenu_filterPosts,
        onSelected: () => container
            .read(topicUserFilterRequestProvider.notifier)
            .request(
              topicId: topicId!,
              username: isFilteringThisUser ? null : username,
            ),
      ),
    RadialMenuItem(
      icon: Symbols.content_copy_rounded,
      label: S.current.avatarMenu_copyUsername,
      onSelected: () => copyUsernameToClipboard(username),
    ),
  ];
}
