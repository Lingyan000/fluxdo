import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../models/topic.dart';
import '../../providers/export_history_provider.dart';
import '../../providers/notion_config_provider.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/toast_service.dart';
import '../../storage/export_history_dao.dart';
import 'notion_client.dart';
import 'notion_config.dart';
import 'notion_sync_service.dart';

/// 收藏后的「自动同步到 Notion」触发器。
///
/// 区分两种语义,严格按用户的收藏意图触发:
/// - [tryTriggerTopic]:用户「收藏话题」时调用,按 NotionConfig.syncScope 同步
///   (仅主帖 / 全部回复)
/// - [tryTriggerPost]:用户「收藏单条 post」时调用,永远只同步那一条,
///   生成独立 page,不受 syncScope 影响,即便那条 post 是 1 楼主帖
///
/// 两种触发都遵守 NotionConfig.autoSyncOnBookmark 开关。
/// fire-and-forget,失败用 toast 但不抛。
class NotionBookmarkAutoSync {
  NotionBookmarkAutoSync._();

  /// 「收藏话题」入口。
  static Future<void> tryTriggerTopic({
    required WidgetRef ref,
    required int topicId,
  }) async {
    debugPrint('[NotionAutoSync] tryTriggerTopic topicId=$topicId');
    final cfg = await _resolveActiveConfig(ref);
    if (cfg == null) return;
    unawaited(_runTopic(ref: ref, topicId: topicId, cfg: cfg));
  }

  /// 「收藏单条 post」入口。
  static Future<void> tryTriggerPost({
    required WidgetRef ref,
    required int topicId,
    required int postId,
  }) async {
    debugPrint(
      '[NotionAutoSync] tryTriggerPost topicId=$topicId postId=$postId',
    );
    final cfg = await _resolveActiveConfig(ref);
    if (cfg == null) return;
    unawaited(
      _runPost(ref: ref, topicId: topicId, postId: postId, cfg: cfg),
    );
  }

  /// 共用的"配置可用性"检查。返回 null 表示不触发同步。
  static Future<NotionConfig?> _resolveActiveConfig(WidgetRef ref) async {
    await ref.read(notionConfigProvider.notifier).ensureLoaded();
    final cfg = ref.read(notionConfigProvider);
    debugPrint(
      '[NotionAutoSync] cfg autoSync=${cfg.autoSyncOnBookmark} complete=${cfg.isComplete}',
    );
    if (!cfg.autoSyncOnBookmark) {
      debugPrint('[NotionAutoSync] skip: autoSyncOnBookmark is off');
      return null;
    }
    if (!cfg.isComplete) {
      debugPrint('[NotionAutoSync] skip: config not complete');
      return null;
    }
    return cfg;
  }

  static Future<void> _runTopic({
    required WidgetRef ref,
    required int topicId,
    required NotionConfig cfg,
  }) async {
    final handle = ToastService.showDownload(S.current.notion_syncing);
    handle.updateProgress(-1);
    try {
      final detail = await DiscourseService().getTopicDetail(topicId);
      handle.updateFileName(detail.title);
      final svc = NotionSyncService(config: cfg);
      final result = await svc.syncTopic(
        detail: detail,
        scope: cfg.syncScope,
        onDuplicate: DuplicateAction.skip,
        onProgress: (p) {
          handle.updateFileName(_progressLabel(detail.title, p));
          if (p.total > 0) {
            handle.updateProgress(p.current / p.total);
          } else {
            handle.updateProgress(-1);
          }
        },
      );
      await _writeHistory(
        ref: ref,
        topicId: topicId,
        title: detail.title,
        pageUrl: result.pageUrl,
        postCount: result.postCount,
      );
      handle.complete(S.current.notion_syncSucceed);
    } on NotionApiException catch (e) {
      handle.complete(
        S.current.notion_syncFailed(e.message),
        type: ToastType.error,
      );
    } catch (e, st) {
      debugPrint('[NotionAutoSync] topic unexpected: $e\n$st');
      handle.complete(
        S.current.notion_syncFailed(e.toString()),
        type: ToastType.error,
      );
    }
  }

  static Future<void> _runPost({
    required WidgetRef ref,
    required int topicId,
    required int postId,
    required NotionConfig cfg,
  }) async {
    final handle = ToastService.showDownload(S.current.notion_syncing);
    handle.updateProgress(-1);
    try {
      final detail = await DiscourseService().getTopicDetail(topicId);
      final post = _findPost(detail, postId);
      if (post == null) {
        // 列表里没拉到这条,试着按这条 post 定位一次详情
        // 简化处理:直接报错
        throw NotionApiException(
          'post #$postId not found in topic detail',
        );
      }
      final headline = '${detail.title} · @${post.username} #${post.postNumber}';
      handle.updateFileName(headline);
      final svc = NotionSyncService(config: cfg);
      final result = await svc.syncPost(
        detail: detail,
        post: post,
        onDuplicate: DuplicateAction.skip,
        onProgress: (p) {
          handle.updateFileName(_progressLabel(headline, p));
          if (p.total > 0) {
            handle.updateProgress(p.current / p.total);
          } else {
            handle.updateProgress(-1);
          }
        },
      );
      await _writeHistory(
        ref: ref,
        topicId: topicId,
        title: headline,
        pageUrl: result.pageUrl,
        postCount: 1,
      );
      handle.complete(S.current.notion_syncSucceed);
    } on NotionApiException catch (e) {
      handle.complete(
        S.current.notion_syncFailed(e.message),
        type: ToastType.error,
      );
    } catch (e, st) {
      debugPrint('[NotionAutoSync] post unexpected: $e\n$st');
      handle.complete(
        S.current.notion_syncFailed(e.toString()),
        type: ToastType.error,
      );
    }
  }

  static Post? _findPost(TopicDetail detail, int postId) {
    for (final p in detail.postStream.posts) {
      if (p.id == postId) return p;
    }
    return null;
  }

  static Future<void> _writeHistory({
    required WidgetRef ref,
    required int topicId,
    required String title,
    required String pageUrl,
    required int postCount,
  }) {
    return ref.read(exportHistoryProvider.notifier).add(
      ExportHistoryEntry(
        id: const Uuid().v4(),
        sourceType: ExportHistorySource.topic,
        sourceTopicId: topicId,
        sourceTitle: title,
        format: ExportHistoryFormat.notion,
        targetType: ExportHistoryTarget.notion,
        targetRef: pageUrl,
        status: ExportHistoryStatus.success,
        createdAt: DateTime.now(),
        postCount: postCount,
      ),
    );
  }

  static String _progressLabel(String title, NotionSyncProgress p) {
    final base = title.length > 30 ? '${title.substring(0, 30)}…' : title;
    switch (p.phase) {
      case SyncPhase.fetch:
        if (p.total > 0) {
          return '$base · ${S.current.notion_syncingFetch(p.current, p.total)}';
        }
        return '$base · ${S.current.notion_syncing}';
      case SyncPhase.convert:
        return '$base · ${S.current.notion_syncingConvert}';
      case SyncPhase.create:
        return '$base · ${S.current.notion_syncingCreate}';
      case SyncPhase.append:
        return '$base · ${S.current.notion_syncingAppend(p.current, p.total)}';
      case SyncPhase.done:
        return '$base · ${S.current.notion_syncing}';
    }
  }
}
