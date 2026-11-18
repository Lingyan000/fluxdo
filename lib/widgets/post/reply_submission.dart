import 'package:common_ui/common_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/s.dart';
import '../../models/pending_post.dart';
import '../../models/topic.dart';
import '../../pages/pending_posts_page.dart';
import '../../plugins/plugins.dart';
import '../../providers/category_provider.dart';
import '../../services/app_error_handler.dart';
import '../../services/composer_min_length_resolver.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/draft_controller.dart';
import '../../services/network/exceptions/api_exception.dart';
import '../../services/local_notification_service.dart' show navigatorKey;
import '../../services/toast_service.dart';
import '../markdown_editor/composer_draft_status.dart';

/// 一次回复发送的结果
@immutable
class ReplySubmitResult {
  const ReplySubmitResult._({this.post, this.enqueued = false});

  static const failed = ReplySubmitResult._();

  /// 发出的帖子（送审时为 null）
  final Post? post;

  /// 帖子进入了审核队列
  final bool enqueued;

  bool get succeeded => post != null || enqueued;
}

/// 回复发送的共用流程：完整编辑器、底栏快捷回复、宽屏停靠编辑器走同一套
/// 校验与发送，避免各写一份后规则逐渐对不上。
abstract final class ReplySubmission {
  /// 解析最小正文字数（含站点插件按分类的改写）
  static Future<int> resolveMinLength(
    WidgetRef ref, {
    int? categoryId,
    bool isFirstPost = false,
    bool isPrivateMessageContext = false,
    bool isPmWithNonHumanUser = false,
  }) {
    return ComposerMinLengthResolver.resolve(
      category: categoryId == null
          ? null
          : ref.read(categoryMapProvider).value?[categoryId],
      isFirstPost: isFirstPost,
      isPrivateMessage: isPrivateMessageContext,
      isPmWithNonHumanUser: isPmWithNonHumanUser,
    );
  }

  /// 发送前置检查：最小字数 → 站点插件发送前确认（对齐 Discourse
  /// `composerBeforeSave`，如回复扣积分的确认框）→ 草稿冲突确认。
  /// 任一不通过返回 false（提示已由本方法给出）。
  static Future<bool> preflight({
    required BuildContext context,
    required WidgetRef ref,
    required String content,
    required int? topicId,
    int? minLength,
    int? categoryId,
    bool isFirstPost = false,
    bool isPrivateMessageContext = false,
    bool isPmWithNonHumanUser = false,
    bool isEditing = false,
    bool isPrivateMessage = false,
    DraftController? draftController,
    Future<void> Function()? onReloadDraft,
  }) async {
    final min =
        minLength ??
        await resolveMinLength(
          ref,
          categoryId: categoryId,
          isFirstPost: isFirstPost,
          isPrivateMessageContext: isPrivateMessageContext,
          isPmWithNonHumanUser: isPmWithNonHumanUser,
        );
    if (content.length < min) {
      ToastService.showInfo(S.current.createTopic_minContentLength(min));
      return false;
    }

    // 放在校验之后：用户取消确认时不进入发送态
    if (!context.mounted) return false;
    final pluginAllowed = await PluginRegistry.runBeforeReplySubmit(
      ReplySubmitContext(
        context: context,
        topic: TopicPluginContext(
          topicId: topicId,
          topicJson: TopicPluginData.of(topicId),
        ),
        isEditing: isEditing,
        isPrivateMessage: isPrivateMessage,
      ),
    );
    if (!pluginAllowed || !context.mounted) return false;

    if (draftController?.hasConflict == true &&
        !await confirmComposerDraftOverwrite(
          context,
          onReload: onReloadDraft ?? () async {},
        )) {
      return false;
    }
    return context.mounted;
  }

  /// 帖子被送审后的提示。[recordReplyTarget] 为 true 时登记回复目标：
  /// enqueued 响应的 pending_post 只有 {id, raw, created_at},回复目标服务端
  /// payload 存了但本人可见接口都不吐;趁发送方还知道上下文记入注册表,
  /// 「撤回并重新编辑」才能恢复"回复某楼"而非退化为直接回复话题
  static void announceEnqueued(
    PendingPost? pending, {
    int? replyToPostNumber,
    bool recordReplyTarget = false,
    ValueChanged<PendingPost>? onEnqueued,
  }) {
    if (pending != null && recordReplyTarget) {
      PendingReplyTargetRegistry.record(pending.id, replyToPostNumber);
    }
    if (onEnqueued != null && pending != null) {
      // 宿主接管展示(如主题页底部待审块),轻提示即可
      onEnqueued(pending);
      ToastService.showInfo(S.current.post_pendingReview);
    } else {
      // 无宿主接管:toast 带「查看」入口跳待审列表页
      ToastService.show(
        S.current.post_pendingReview,
        type: ToastType.info,
        actionLabel: S.current.review_viewAction,
        onAction: () {
          navigatorKey.currentState?.push(
            InteractionPageRoute(builder: (_) => const PendingPostsPage()),
          );
        },
      );
    }
  }

  /// 发送回复。发送期间暂停草稿自动保存（对齐 Discourse 前端
  /// composer.set("disableDrafts", true)，避免与服务端推进的 draft_sequence
  /// 撞 409）；成功或送审后删除草稿，失败恢复自动保存。
  static Future<ReplySubmitResult> createReply({
    required int topicId,
    required String raw,
    int? replyToPostNumber,
    DraftController? draftController,
    ValueChanged<PendingPost>? onEnqueued,
  }) async {
    draftController?.disable();
    try {
      final post = await DiscourseService().createReply(
        topicId: topicId,
        raw: raw,
        replyToPostNumber: replyToPostNumber,
        draftKey: draftController?.draftKey,
        onDraftSequence: (seq) => draftController?.syncSequence(seq),
      );
      await draftController?.deleteDraft();
      return ReplySubmitResult._(post: post);
    } on PostEnqueuedException catch (e) {
      await draftController?.deleteDraft();
      announceEnqueued(
        e.pendingPost,
        replyToPostNumber: replyToPostNumber,
        recordReplyTarget: true,
        onEnqueued: onEnqueued,
      );
      return const ReplySubmitResult._(enqueued: true);
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理:发送失败,恢复草稿保存
      draftController?.enable();
      return ReplySubmitResult.failed;
    } catch (e, s) {
      draftController?.enable();
      AppErrorHandler.handleUnexpected(e, s);
      return ReplySubmitResult.failed;
    }
  }
}
