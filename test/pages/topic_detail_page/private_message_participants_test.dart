import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/private_message_participants.dart';

TopicUser _user(int id, String username, {String? name}) {
  return TopicUser(id: id, username: username, name: name, avatarTemplate: '');
}

Widget _wrap(Widget child) {
  return TranslationProvider(
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocaleUtils.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

PrivateMessageParticipants _panel({
  required bool canRemoveAllowedUsers,
  int? removableSelfId = 1,
  int? removingParticipantId,
  String? removingGroupName,
  List<TopicGroup> groups = const [],
  bool canInvite = false,
  ValueChanged<TopicUser>? onRemoveParticipant,
  ValueChanged<TopicGroup>? onRemoveGroup,
  VoidCallback? onInvite,
}) {
  return PrivateMessageParticipants(
    location: PrivateMessageParticipantsLocation.firstPost,
    participants: [
      _user(1, 'me', name: '我'),
      _user(2, 'alice', name: 'Alice'),
      _user(3, 'bob'),
    ],
    groups: groups,
    canRemoveAllowedUsers: canRemoveAllowedUsers,
    removableSelfId: removableSelfId,
    canInvite: canInvite,
    removingParticipantId: removingParticipantId,
    removingGroupName: removingGroupName,
    onRemoveParticipant: onRemoveParticipant,
    onRemoveGroup: onRemoveGroup,
    onInvite: onInvite,
  );
}

/// 生产装配路径(fromDetail)用的私信详情;权限位直接照 details 下发。
TopicDetail _detail({
  bool canRemoveAllowedUsers = false,
  int? canRemoveSelfId = 1,
  int postsCount = 1,
  bool canInviteTo = false,
  List<Map<String, dynamic>> allowedGroups = const [],
  List<Map<String, dynamic>> allowedUsers = const [
    {'id': 1, 'username': 'me', 'name': '我', 'avatar_template': ''},
    {'id': 2, 'username': 'alice', 'name': 'Alice', 'avatar_template': ''},
  ],
}) {
  return TopicDetail.fromJson({
    'id': 42,
    'title': 'Private message',
    'slug': 'private-message',
    'posts_count': postsCount,
    'post_stream': {
      'posts': const <Map<String, dynamic>>[],
      'stream': const <int>[],
    },
    'category_id': 0,
    'archetype': 'private_message',
    'details': {
      'allowed_users': allowedUsers,
      'allowed_groups': allowedGroups,
      'can_remove_allowed_users': canRemoveAllowedUsers,
      'can_invite_to': canInviteTo,
      if (canRemoveSelfId != null) 'can_remove_self_id': canRemoveSelfId,
    },
  });
}

void main() {
  testWidgets('面板显示全部私信成员、用户名与人数', (tester) async {
    await tester.pumpWidget(
      _wrap(_panel(canRemoveAllowedUsers: false, onRemoveParticipant: (_) {})),
    );
    await tester.pump();

    expect(find.text('参与者'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('我'), findsOneWidget);
    expect(find.text('@me'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
  });

  testWidgets('普通成员只显示自己的退出按钮', (tester) async {
    await tester.pumpWidget(
      _wrap(_panel(canRemoveAllowedUsers: false, onRemoveParticipant: (_) {})),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('pm-participant-firstPost-remove-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('pm-participant-firstPost-remove-2')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('pm-participant-firstPost-remove-3')),
      findsNothing,
    );
  });

  testWidgets('服务端授权移除成员时可退出自己并移除其他成员', (tester) async {
    TopicUser? removed;
    await tester.pumpWidget(
      _wrap(
        _panel(
          canRemoveAllowedUsers: true,
          onRemoveParticipant: (participant) => removed = participant,
        ),
      ),
    );
    await tester.pump();

    for (final id in [1, 2, 3]) {
      expect(
        find.byKey(ValueKey('pm-participant-firstPost-remove-$id')),
        findsOneWidget,
      );
    }

    await tester.tap(
      find.byKey(const ValueKey('pm-participant-firstPost-remove-2')),
    );
    expect(removed?.username, 'alice');
  });

  testWidgets('后端未授予退出权限时不显示自己的按钮', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _panel(
          canRemoveAllowedUsers: false,
          removableSelfId: null,
          onRemoveParticipant: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('pm-participant-firstPost-remove-1')),
      findsNothing,
    );
  });

  // 回归防线:can_remove_allowed_users 已含「staff 或房主(TL2+)」判定,
  // 装配层不得再叠加 admin 门槛,否则版主与非管理员房主看不到按钮。
  testWidgets('fromDetail 只认服务端权限位，不叠加管理员门槛', (tester) async {
    await tester.pumpWidget(
      _wrap(
        PrivateMessageParticipants.fromDetail(
          location: PrivateMessageParticipantsLocation.firstPost,
          detail: _detail(canRemoveAllowedUsers: true),
          removingParticipantId: null,
          removingGroupName: null,
          onRemoveParticipant: (_) {},
          onRemoveGroup: (_) {},
          onInvite: () {},
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('pm-participant-firstPost-remove-2')),
      findsOneWidget,
    );
  });

  test('底部面板对短私信不重复展示', () {
    // 首楼已有一块,楼层数不过 Discourse MIN_POSTS_COUNT(=3) 时底部不再堆一块。
    expect(PrivateMessageParticipants.shouldShow(_detail(postsCount: 1)), isTrue);
    expect(
      PrivateMessageParticipants.shouldShowAtBottom(_detail(postsCount: 1)),
      isFalse,
    );
    expect(
      PrivateMessageParticipants.shouldShowAtBottom(_detail(postsCount: 4)),
      isTrue,
    );
  });

  testWidgets('群组排在用户之前并计入人数，可移除', (tester) async {
    TopicGroup? removed;
    await tester.pumpWidget(
      _wrap(
        _panel(
          canRemoveAllowedUsers: true,
          groups: const [TopicGroup(id: 9, name: 'staff', fullName: '管理组')],
          onRemoveParticipant: (_) {},
          onRemoveGroup: (group) => removed = group,
        ),
      ),
    );
    await tester.pump();

    // 3 个用户 + 1 个群组
    expect(find.text('4'), findsOneWidget);
    expect(find.text('staff'), findsOneWidget);
    expect(find.text('管理组'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('pm-group-firstPost-remove-staff')),
    );
    expect(removed?.name, 'staff');
  });

  testWidgets('无移除权限时群组不显示移除按钮', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _panel(
          canRemoveAllowedUsers: false,
          groups: const [TopicGroup(id: 9, name: 'staff')],
          onRemoveParticipant: (_) {},
          onRemoveGroup: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('pm-group-firstPost-remove-staff')),
      findsNothing,
    );
  });

  testWidgets('邀请入口只在 can_invite_to 为真时出现', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _panel(
          canRemoveAllowedUsers: false,
          canInvite: false,
          onRemoveParticipant: (_) {},
          onInvite: () {},
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('pm-participants-firstPost-invite')),
      findsNothing,
    );

    var invited = false;
    await tester.pumpWidget(
      _wrap(
        _panel(
          canRemoveAllowedUsers: false,
          canInvite: true,
          onRemoveParticipant: (_) {},
          onInvite: () => invited = true,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('pm-participants-firstPost-invite')),
    );
    expect(invited, isTrue);
  });

  testWidgets('移除进行中锁掉全部控件', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _panel(
          canRemoveAllowedUsers: true,
          canInvite: true,
          removingGroupName: 'staff',
          groups: const [TopicGroup(id: 9, name: 'staff')],
          onRemoveParticipant: (_) {},
          onRemoveGroup: (_) {},
          onInvite: () {},
        ),
      ),
    );
    await tester.pump();

    // 正在移除的群组换成进度指示，其余按钮全部禁用
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final invite = tester.widget<IconButton>(
      find.byKey(const ValueKey('pm-participants-firstPost-invite')),
    );
    expect(invite.onPressed, isNull);
    final removeUser = tester.widget<IconButton>(
      find.byKey(const ValueKey('pm-participant-firstPost-remove-2')),
    );
    expect(removeUser.onPressed, isNull);
  });

  test('只有群组、没有用户的私信也要显示面板', () {
    final detail = _detail(
      allowedUsers: const [],
      allowedGroups: const [
        {'id': 9, 'name': 'staff'},
      ],
    );
    expect(PrivateMessageParticipants.shouldShow(detail), isTrue);
  });

  test('成员名单为空时两处都不展示', () {
    final detail = _detail(postsCount: 10, allowedUsers: const []);
    expect(PrivateMessageParticipants.shouldShow(detail), isFalse);
    expect(PrivateMessageParticipants.shouldShowAtBottom(detail), isFalse);
  });
}
