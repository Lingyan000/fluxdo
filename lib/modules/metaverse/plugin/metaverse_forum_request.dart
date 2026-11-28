import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

/// 只读资源与权限一一关联，不接收 URL、HTTP 方法或任意过滤编号。
enum MetaverseForumScope { profiles, activity, following }

enum MetaverseForumResource {
  user(MetaverseForumScope.profiles),
  actions(MetaverseForumScope.activity),
  reactions(MetaverseForumScope.activity),
  boosts(MetaverseForumScope.activity),
  following(MetaverseForumScope.following);

  const MetaverseForumResource(this.scope);
  final MetaverseForumScope scope;
}

enum MetaverseForumAction {
  likes(1),
  topics(4),
  replies(5);

  const MetaverseForumAction(this.code);
  final int code;
}

class MetaverseForumRequest {
  const MetaverseForumRequest({
    required this.resource,
    required this.username,
    this.offset = 0,
    this.before,
    this.actions = const [],
  });
  final MetaverseForumResource resource;
  final String username;
  final int offset;
  final int? before;
  final List<MetaverseForumAction> actions;

  static String usernameOf(Object? value) {
    // 用户名用于已有服务的路径；拒绝分隔符、转义及点段。
    if (value is! String ||
        !RegExp(r'^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,59}$').hasMatch(value)) {
      throw const MetaversePluginCallException('forum_invalid_username');
    }
    return value;
  }

  static int integer(Object? value, {int min = 0, int max = 10000}) {
    if (value is! int || value < min || value > max) {
      throw const MetaversePluginCallException('forum_invalid_arguments');
    }
    return value;
  }

  static MetaverseForumRequest parse(Map<String, Object?> params) {
    final resource = MetaverseForumResource.values
        .where((v) => v.name == params['resource'])
        .firstOrNull;
    if (resource == null) {
      throw const MetaversePluginCallException('forum_unknown_resource');
    }
    final allowed = {
      'resource',
      'username',
      if (resource == MetaverseForumResource.actions ||
          resource == MetaverseForumResource.following)
        'offset',
      if (resource == MetaverseForumResource.actions) 'actions',
      if (resource == MetaverseForumResource.reactions ||
          resource == MetaverseForumResource.boosts)
        'before',
    };
    if (params.keys.any((key) => !allowed.contains(key))) {
      throw const MetaversePluginCallException('forum_invalid_arguments');
    }
    final rawActions =
        params['actions'] ??
        MetaverseForumAction.values.map((v) => v.name).toList();
    if (rawActions is! List ||
        rawActions.isEmpty ||
        rawActions.length > MetaverseForumAction.values.length) {
      throw const MetaversePluginCallException('forum_invalid_arguments');
    }
    final actions = <MetaverseForumAction>[];
    for (final raw in rawActions) {
      final action = MetaverseForumAction.values
          .where((v) => v.name == raw)
          .firstOrNull;
      if (action == null) {
        throw const MetaversePluginCallException('forum_invalid_arguments');
      }
      actions.add(action);
    }
    return MetaverseForumRequest(
      resource: resource,
      username: usernameOf(params['username']),
      offset: integer(params['offset'] ?? 0),
      before: params['before'] == null
          ? null
          : integer(params['before'], min: 1, max: 2147483647),
      actions: List.unmodifiable(actions.toSet()),
    );
  }
}

class MetaverseForumDestination {
  const MetaverseForumDestination._({
    this.username,
    this.topicId,
    this.postNumber,
  });
  final String? username;
  final int? topicId, postNumber;
  static MetaverseForumDestination parse(Map<String, Object?> params) {
    if (params['type'] == 'user' &&
        params.keys.every((k) => k == 'type' || k == 'username')) {
      return MetaverseForumDestination._(
        username: MetaverseForumRequest.usernameOf(params['username']),
      );
    }
    if (params['type'] == 'topic' &&
        params.keys.every(
          (k) => k == 'type' || k == 'topicId' || k == 'postNumber',
        )) {
      return MetaverseForumDestination._(
        topicId: MetaverseForumRequest.integer(
          params['topicId'],
          min: 1,
          max: 2147483647,
        ),
        postNumber: params['postNumber'] == null
            ? null
            : MetaverseForumRequest.integer(
                params['postNumber'],
                min: 1,
                max: 2147483647,
              ),
      );
    }
    throw const MetaversePluginCallException('forum_invalid_destination');
  }
}
