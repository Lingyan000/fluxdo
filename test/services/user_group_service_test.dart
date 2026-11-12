import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/models/user_group.dart';
import 'package:fluxdo/services/network/flux_request_spec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = DiscourseService();
  late Object? reply;
  late RequestOptions request;
  late InterceptorsWrapper mock;
  setUp(() {
    mock = InterceptorsWrapper(
      onRequest: (options, handler) {
        request = options;
        handler.resolve(Response(requestOptions: options, data: reply));
      },
    );
    service.dio.interceptors.insert(0, mock);
  });
  tearDown(() => service.dio.interceptors.remove(mock));

  test('用户组目录传递搜索、类型、排序和分页，解析服务端可用筛选', () async {
    reply = {
      'groups': [
        {
          'id': 7,
          'name': 'dev',
          'full_name': '开发组',
          'user_count': 42,
          'is_group_user': true,
          'is_group_owner': true,
          'bio_excerpt': '开发交流',
          'flair_url': 'code',
          'flair_color': 'FFFFFF',
          'flair_bg_color': '123456',
        },
      ],
      'total_rows_groups': 31,
      'load_more_groups': '/groups?page=2',
      'extras': {
        'type_filters': ['public', 'close'],
      },
    };
    final result = await service.getGroups(
      filter: 'dev',
      type: 'public',
      order: GroupDirectoryOrder.members,
      ascending: false,
      page: 1,
      username: 'alice',
    );
    expect(request.path, '/groups.json');
    expect(request.queryParameters, {
      'filter': 'dev',
      'type': 'public',
      'order': 'user_count',
      'asc': 'false',
      'page': 1,
      'username': 'alice',
    });
    expect(result.total, 31);
    expect(result.moreUrl, '/groups?page=2');
    expect(result.typeFilters, ['public', 'close']);
    final group = result.groups.single.withMembership(false);
    expect(group.displayName, '开发组');
    expect(group.isOwner, true);
    expect(group.bioExcerpt, '开发交流');
    expect(group.flairUrl, 'code');
    expect(group.flairBackground, '123456');
    await service.getGroups();
    expect(request.queryParameters, {'page': 0});
  });

  test('原生用户组读取名称、简介和服务端成员权限', () async {
    reply = {
      'group': {
        'id': 7,
        'name': '开发',
        'display_name': '开发组',
        'user_count': 100,
        'bio_cooked': '<p>介绍</p>',
        'can_see_members': false,
      },
    };
    final group = await service.getGroup('开发');
    expect(request.path, '/g/%E5%BC%80%E5%8F%91.json');
    expect(group.displayName, '开发组');
    expect(group.bio, '<p>介绍</p>');
    expect(group.canSeeMembers, false);
  });

  test('成员搜索携带过滤与偏移，以返回数量结束分页', () async {
    reply = {
      'members': [
        {'id': 1, 'username': 'alice'},
      ],
      'owners': [
        {'id': 1, 'username': 'alice'},
      ],
      'meta': {'total': 1000, 'offset': 50, 'limit': 50},
    };
    final page = await service.getGroupMembers(
      'team',
      filter: 'ali',
      offset: 50,
    );
    expect(request.path, '/g/team/members.json');
    expect(request.queryParameters, {
      'offset': 50,
      'limit': 50,
      'filter': 'ali',
    });
    expect(page.members.single.username, 'alice');
    expect(page.ownerIds, {1});
    expect(page.offset, 50);
    expect(page.hasMore, false);
  });

  test('分类独立页使用完整分类响应', () async {
    reply = {
      'category': {
        'id': 42,
        'name': '开发',
        'slug': 'develop',
        'parent_category_id': 9,
        'permission': 1,
      },
    };
    final category = await service.getCategory(42);
    expect(request.path, '/c/42/show.json');
    expect(category.parentCategoryId, 9);
    expect(category.canCreateTopic, true);
  });
  test('用户组操作能力来自服务端', () async {
    reply = {
      'group': {
        'id': 7,
        'name': 'team',
        'can_see_members': false,
        'is_group_user': true,
        'public_exit': true,
        'public_admission': false,
        'allow_membership_requests': true,
        'membership_request_template': '介绍自己',
        'messageable': true,
      },
    };
    final group = await service.getGroup('team');
    expect(group.isMember, true);
    expect(group.publicExit, true);
    expect(group.publicAdmission, false);
    expect(group.allowMembershipRequests, true);
    expect(group.requestTemplate, '介绍自己');
    expect(group.messageable, true);
  });

  test('成员排序参数和加入时间', () async {
    reply = {
      'members': [
        {'id': 1, 'username': 'alice', 'added_at': '2026-11-11T10:00:00Z'},
      ],
      'owners': [],
      'meta': {'offset': 0, 'limit': 50},
    };
    final page = await service.getGroupMembers(
      'team',
      order: GroupMemberOrder.joined,
      ascending: false,
    );
    expect(request.queryParameters['order'], 'added_at');
    expect(request.queryParameters['asc'], 'false');
    expect(page.joinedAt[1]?.toUtc(), DateTime.utc(2026, 11, 11, 10));
  });

  test('活动帖子和提及保留分页游标、分类与原生话题定位', () async {
    reply = {
      'posts': [
        {
          'id': 23,
          'topic_id': 8,
          'post_number': 4,
          'topic_title': '讨论',
          'user_id': 1,
          'username': 'alice',
          'excerpt': '<p>正文</p>',
          'created_at': '2026-11-11T10:00:00Z',
          'category_id': 42,
        },
      ],
      'categories': [
        {'id': 42, 'name': '开发'},
      ],
    };
    final before = DateTime.utc(2026, 11, 12);
    final page = await service.getGroupPosts(
      'team',
      mentions: true,
      before: before,
      categoryId: 42,
    );
    expect(request.path, '/groups/team/mentions.json');
    expect(request.queryParameters, {
      'before': '2026-11-12T00:00:00.000Z',
      'category_id': 42,
    });
    expect(page.posts.single.postNumber, 4);
    expect(page.posts.single.topicId, 8);
    expect(page.posts.single.user.username, 'alice');
    expect(
      page.posts.single.createdAt?.toUtc(),
      DateTime.utc(2026, 11, 11, 10),
    );
    expect(page.categories.single.id, 42);
    expect(page.hasMore, false);
    await service.getGroupPosts('team');
    expect(request.path, '/groups/team/posts.json');
  });

  test('组话题分页与权限响应', () async {
    reply = {
      'topic_list': {'topics': [], 'more_topics_url': '/next'},
    };
    final topics = await service.getGroupTopics(
      'team',
      page: 2,
      categoryId: 42,
    );
    expect(request.path, '/topics/groups/team.json');
    expect(request.queryParameters, {'page': 2, 'category_id': 42});
    expect(topics.moreTopicsUrl, '/next');
    reply = [
      {
        'category': {'id': 42, 'name': '开发'},
        'permission_type': 1,
      },
      {
        'category': {'id': 43, 'name': '阅读'},
        'permission_type': 3,
      },
    ];
    final permissions = await service.getGroupPermissions('team');
    expect(request.path, '/g/team/permissions.json');
    expect(permissions.map((item) => item.type), [1, 3]);
  });

  test('加入、退出和申请使用正确方法且禁止自动重放写入', () async {
    reply = {'success': 'OK'};
    await service.joinGroup(7);
    expect(request.method, 'PUT');
    expect(request.path, '/groups/7/join.json');
    expect(request.extra[FluxRequestKeys.noRecovery], true);
    reply = null;
    await service.leaveGroup(7);
    expect(request.method, 'DELETE');
    expect(request.path, '/groups/7/leave.json');
    reply = {'success': 'OK', 'relative_url': '/t/request/123'};
    expect(
      await service.requestGroupMembership('team', '申请理由'),
      '/t/request/123',
    );
    expect(request.method, 'POST');
    expect(request.path, '/groups/team/request_membership.json');
    expect(request.data, {'reason': '申请理由'});
    expect(request.extra[FluxRequestKeys.noRecovery], true);
  });

  testWidgets('HTTP 200 的失败或网页响应不能被当作加入成功', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      ),
    );
    await tester.runAsync(() async {
      for (final failure in [
        {'success': false},
        {
          'errors': ['失败'],
        },
        '<html>登录</html>',
      ]) {
        reply = failure;
        await expectLater(
          service.joinGroup(7),
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
        );
      }
    });
  });
}
