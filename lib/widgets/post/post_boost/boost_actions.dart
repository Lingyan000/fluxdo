import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../pages/user_profile_page.dart';
import '../../../providers/discourse_providers.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../services/app_error_handler.dart';
import '../../../services/toast_service.dart';
import '../../../utils/dialog_utils.dart';
import '../../user/user_card.dart';
import '../post_item/widgets/boost_flag_sheet.dart';
import 'boost_author_popover.dart';

/// Boost 点击后的完整操作流(作者预览/主页/举报/删除),从帖脚抽出的
/// 独立版本 —— 弹幕层挂在正文上(短帖 PostItem / 长帖首 chunk),
/// 长帖 chunk 与 footer 是不同 sliver item(footer 可能都没挂载),
/// 不能再经 GlobalKey 借用帖脚的实现。
///
/// 数据落地统一走 topicDetailProvider(经活跃实例注册表),帖脚等
/// 持有本地 state 的调用方可传 [onBoostChanged]/[onBoostDeleted]
/// 钩子在落 provider 之外同步自己的 setState。
class BoostActions {
  BoostActions._();

  static final DiscourseService _service = DiscourseService();

  /// boost 变更落回 provider(无活跃实例时静默跳过)。
  static void _syncToProvider(
    WidgetRef ref,
    int topicId,
    void Function(TopicDetailNotifier notifier) apply,
  ) {
    final params = TopicDetailNotifier.activeParamsFor(topicId);
    if (params == null) return;
    try {
      apply(ref.read(topicDetailProvider(params).notifier));
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  static bool _shouldFetchActionState({
    required Boost boost,
    required String currentUsername,
  }) {
    final isOwnBoost = currentUsername == boost.user.username;
    if (isOwnBoost) {
      return false;
    }
    if (boost.canFlag && boost.availableFlags == null) {
      return true;
    }
    return !boost.canDelete &&
        !boost.canFlag &&
        boost.availableFlags == null &&
        boost.userFlagStatus == null;
  }

  /// 展示 boost 操作弹层。[post] 是 boost 所在帖子。
  static Future<void> show({
    required BuildContext context,
    required WidgetRef ref,
    required Post post,
    required int topicId,
    required Boost boost,
    Rect? anchorRect,
    String? topicTitle,
    void Function(Boost boost)? onBoostChanged,
    void Function(Boost boost, {required bool restoreCanBoost})?
        onBoostDeleted,
  }) async {
    void applyChanged(Boost updated) {
      onBoostChanged?.call(updated);
      _syncToProvider(
        ref,
        topicId,
        (n) => n.applyLocalBoostChanged(post.id, updated),
      );
    }

    final currentUsername = ref.read(currentUserProvider).value?.username;
    Boost resolvedBoost = boost;
    var actionStateLoadFailed = false;
    if (currentUsername != null &&
        currentUsername.isNotEmpty &&
        _shouldFetchActionState(
          boost: boost,
          currentUsername: currentUsername,
        )) {
      try {
        resolvedBoost = await _service.getBoost(boost.id);
        applyChanged(resolvedBoost);
      } catch (_) {
        actionStateLoadFailed = true;
      }
    }
    if (!context.mounted) return;

    final canPreviewAuthor =
        canViewBoostAuthor(boost: resolvedBoost) &&
        canShowUserCardPreview(context);
    final canDelete =
        actionStateLoadFailed ||
            currentUsername == null ||
            currentUsername.isEmpty
        ? false
        : canDeleteBoostAction(
            boost: resolvedBoost,
            currentUsername: currentUsername,
          );
    final canFlag =
        actionStateLoadFailed ||
            currentUsername == null ||
            currentUsername.isEmpty
        ? false
        : canFlagBoostAction(
            boost: resolvedBoost,
            currentUsername: currentUsername,
          );
    final alreadyReported = currentUsername == null || currentUsername.isEmpty
        ? false
        : boostAlreadyReportedByCurrentUser(
            boost: resolvedBoost,
            currentUsername: currentUsername,
          );
    final canShowSheet = canPreviewAuthor || canFlag || canDelete;
    if (actionStateLoadFailed) {
      ToastService.showError(S.current.common_loadFailed);
    }
    if (!canShowSheet) {
      return;
    }
    if (alreadyReported && !canDelete) {
      ToastService.showInfo(S.current.boost_flagAlreadyReported);
    }

    final resolvedAnchor = anchorRect ?? _fallbackAnchorRect(context);
    final action = await showBoostAuthorPopover(
      context: context,
      anchorRect: resolvedAnchor,
      boost: resolvedBoost,
      canViewAuthor: canPreviewAuthor,
      canFlag: canFlag,
      canDelete: canDelete,
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case BoostAuthorPopoverAction.authorCard:
        _showAuthorCard(
          context: context,
          boost: resolvedBoost,
          anchorRect: resolvedAnchor,
          topicId: topicId,
          topicTitle: topicTitle,
          postNumber: post.postNumber,
        );
      case BoostAuthorPopoverAction.profile:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                UserProfilePage(username: resolvedBoost.user.username),
          ),
        );
      case BoostAuthorPopoverAction.flag:
        _showFlagSheet(
          context: context,
          boost: resolvedBoost,
          onChanged: applyChanged,
        );
      case BoostAuthorPopoverAction.delete:
        await _deleteBoost(
          context: context,
          ref: ref,
          post: post,
          topicId: topicId,
          boost: resolvedBoost,
          onBoostDeleted: onBoostDeleted,
        );
    }
  }

  static Rect _fallbackAnchorRect(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    final size = media?.size ?? const Size(1, 1);
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.35),
      width: 1,
      height: 1,
    );
  }

  static void _showAuthorCard({
    required BuildContext context,
    required Boost boost,
    required Rect anchorRect,
    required int topicId,
    required String? topicTitle,
    required int postNumber,
  }) {
    showUserCard(
      context: context,
      anchorRect: anchorRect,
      username: boost.user.username,
      topicId: topicId,
      topicTitle: topicTitle,
      postNumber: postNumber,
      avatarFallbackUrl: boost.user.avatarTemplate.isEmpty
          ? null
          : boost.user.getAvatarUrl(size: 144),
      nameFallback: boost.user.name,
      flairUrl: null,
      flairName: null,
      flairBgColor: null,
      flairColor: null,
    );
  }

  static void _showFlagSheet({
    required BuildContext context,
    required Boost boost,
    required void Function(Boost boost) onChanged,
  }) {
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      enableDrag: false, // 举报表单(card):禁止下滑误关
      builder: (context) => BoostFlagSheet(
        boost: boost,
        submitFlag: (flagTypeId, message) async {
          await _service.flagBoost(
            boost.id,
            flagTypeId: flagTypeId,
            message: message,
          );
          // 举报后补拉最新状态(失败则本地兜底标记已举报)
          try {
            onChanged(await _service.getBoost(boost.id));
          } catch (_) {
            onChanged(
              boost.copyWith(
                canFlag: false,
                userFlagStatus: boost.userFlagStatus ?? 1,
              ),
            );
          }
        },
        onSuccess: () =>
            ToastService.showSuccess(S.current.boost_flagSubmitted),
      ),
    );
  }

  static Future<void> _deleteBoost({
    required BuildContext context,
    required WidgetRef ref,
    required Post post,
    required int topicId,
    required Boost boost,
    required void Function(Boost boost, {required bool restoreCanBoost})?
        onBoostDeleted,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(S.current.boost_deleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(S.current.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              S.current.common_delete,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await _service.deleteBoost(boost.id);
    } catch (_) {
      ToastService.showError(S.current.boost_deleteFailed);
      return;
    }
    final currentUser = ref.read(currentUserProvider).value;
    final restoreCanBoost =
        currentUser != null && boost.user.username == currentUser.username;
    onBoostDeleted?.call(boost, restoreCanBoost: restoreCanBoost);
    _syncToProvider(
      ref,
      topicId,
      (n) => n.applyLocalBoostDeleted(
        post.id,
        boost.id,
        restoreCanBoost: restoreCanBoost,
      ),
    );
    ToastService.showSuccess(S.current.boost_deleted);
  }
}
