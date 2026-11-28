import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import '../../../models/topic.dart';
import '../../../services/discourse/discourse_service.dart';
import '../plugin/metaverse_forum_request.dart';

/// 所有插件（包括开发会话）共享预算，重建运行时不能重置限流。
class MetaverseForumBudget {
  MetaverseForumBudget({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  final _requests = <({String plugin, DateTime at})>[];
  final _active = <String, int>{};
  DateTime? _blockedUntil;
  void acquire(String plugin) {
    final now = _clock();
    _requests.removeWhere(
      (v) => now.difference(v.at) >= const Duration(minutes: 1),
    );
    if ((_blockedUntil?.isAfter(now) ?? false) ||
        _requests.length >= 240 ||
        _requests.where((v) => v.plugin == plugin).length >= 120 ||
        (_active[plugin] ?? 0) >= 2 ||
        _active.values.fold(0, (a, b) => a + b) >= 6) {
      throw const MetaversePluginCallException('forum_rate_limited');
    }
    _requests.add((plugin: plugin, at: now));
    _active[plugin] = (_active[plugin] ?? 0) + 1;
  }

  void release(String plugin) {
    final count = (_active[plugin] ?? 1) - 1;
    if (count <= 0) {
      _active.remove(plugin);
    } else {
      _active[plugin] = count;
    }
  }

  void backoff(int seconds) {
    final until = _clock().add(Duration(seconds: seconds.clamp(60, 3600)));
    if (_blockedUntil == null || until.isAfter(_blockedUntil!)) {
      _blockedUntil = until;
    }
  }
}

/// 论坛协议适配只留在应用层，插件得到指定字段，不能取得会话或任意 API 通道。
class MetaverseForumAdapter {
  MetaverseForumAdapter(this.service, this.budget);
  final DiscourseService service;
  final MetaverseForumBudget budget;

  Future<Object?> read(
    String pluginId,
    MetaverseForumRequest request, {
    required void Function() checkActive,
  }) async {
    checkActive();
    budget.acquire(pluginId);
    try {
      final result = await _read(request);
      checkActive();
      if (utf8.encode(jsonEncode(result)).length > 512 * 1024) {
        throw const MetaversePluginCallException('forum_response_too_large');
      }
      return result;
    } on DioException catch (error) {
      checkActive();
      final status = error.response?.statusCode;
      if (status == 429) {
        budget.backoff(
          int.tryParse(error.response?.headers.value('retry-after') ?? '') ??
              60,
        );
        throw const MetaversePluginCallException('forum_rate_limited');
      }
      if (status == 401) {
        throw const MetaversePluginCallException('forum_auth_required');
      }
      if (status == 403) {
        budget.backoff(60);
        throw const MetaversePluginCallException('forum_forbidden');
      }
      if (status == 404) {
        throw const MetaversePluginCallException('forum_not_found');
      }
      throw const MetaversePluginCallException('forum_network_error');
    } finally {
      budget.release(pluginId);
    }
  }

  Map<String, Object?>? _person(TopicUser? user) => user == null
      ? null
      : {
          'id': user.id,
          'username': user.username,
          'name': user.name,
          'avatarUrl': user.getAvatarUrl(),
        };
  Future<Object?> _read(MetaverseForumRequest r) async {
    switch (r.resource) {
      case MetaverseForumResource.user:
        final user = await service.getUser(r.username, isSilent: true);
        return {
          'id': user.id,
          'username': user.username,
          'name': user.name,
          'avatarUrl': user.getAvatarUrl(),
          'trustLevel': user.trustLevel,
          'lastSeenAt': user.lastSeenAt?.toIso8601String(),
          'lastPostedAt': user.lastPostedAt?.toIso8601String(),
        };
      case MetaverseForumResource.actions:
        final response = await service.getUserActions(
          r.username,
          filter: r.actions.map((v) => v.code).join(','),
          offset: r.offset,
          isSilent: true,
        );
        final items = response.actions
            .where((a) => r.actions.any((v) => v.code == a.actionType))
            .map(
              (a) => {
                'id': a.dedupeKey,
                'action': MetaverseForumAction.values
                    .firstWhere((v) => v.code == a.actionType)
                    .name,
                'topicId': a.topicId,
                'postNumber': a.postNumber,
                'title': a.title,
                'excerpt': a.excerpt,
                'createdAt': a.actingAt?.toIso8601String(),
                'categoryId': a.categoryId,
                'actor': _person(a.actor),
                'author': _person(a.author),
              },
            )
            .toList();
        return {
          'items': items,
          'nextOffset': response.actions.isEmpty
              ? null
              : r.offset + response.actions.length,
        };
      case MetaverseForumResource.reactions:
        final response = await service.getUserReactions(
          r.username,
          beforeReactionUserId: r.before,
          isSilent: true,
        );
        return {
          'items': response.reactions
              .map(
                (a) => {
                  'id': a.id,
                  'postId': a.postId,
                  'topicId': a.topicId,
                  'postNumber': a.postNumber,
                  'title': a.topicTitle,
                  'excerpt': a.excerpt,
                  'reaction': a.reactionValue,
                  'createdAt': a.createdAt?.toIso8601String(),
                  'categoryId': a.categoryId,
                  'actor': _person(a.actor),
                  'author': _person(a.author),
                },
              )
              .toList(),
          'nextBefore': response.reactions.lastOrNull?.id,
        };
      case MetaverseForumResource.boosts:
        final response = await service.getUserBoostsGiven(
          r.username,
          beforeBoostId: r.before,
          isSilent: true,
        );
        return {
          'items': response.boosts
              .map(
                (a) => {
                  'id': a.id,
                  'postId': a.postId,
                  'topicId': a.topicId,
                  'postNumber': a.postNumber,
                  'title': a.topicTitle,
                  'excerpt': a.excerpt,
                  'cooked': a.cooked,
                  'createdAt': a.createdAt?.toIso8601String(),
                  'categoryId': a.categoryId,
                  'actor': _person(a.booster),
                  'author': _person(a.author),
                },
              )
              .toList(),
          'nextBefore': response.boosts.lastOrNull?.id,
        };
      case MetaverseForumResource.following:
        final users = await service.getFollowing(r.username, isSilent: true);
        final page = users.skip(r.offset).take(100).toList();
        return {
          'items': page
              .map(
                (u) => {
                  'id': u.id,
                  'username': u.username,
                  'name': u.name,
                  'avatarUrl': u.getAvatarUrl(),
                },
              )
              .toList(),
          'nextOffset': r.offset + page.length < users.length
              ? r.offset + page.length
              : null,
        };
    }
  }
}
