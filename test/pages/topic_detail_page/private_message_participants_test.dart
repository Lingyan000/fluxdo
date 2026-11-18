import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/mention_user.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/invite_private_message_dialog.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/private_message_participants.dart';
import 'package:fluxdo/providers/discourse_providers.dart';
import 'package:fluxdo/utils/dialog_utils.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

const _params = TopicDetailParams(42);

TopicDetail _detail({
  bool groups = false,
  bool manage = false,
  bool invite = false,
  bool leave = false,
}) => TopicDetail.fromJson({
  'id': 42,
  'title': '私信',
  'slug': 'pm',
  'archetype': 'private_message',
  'posts_count': 4,
  'category_id': 0,
  'post_stream': {'posts': [], 'stream': []},
  'details': {
    'allowed_users': [
      {'id': 1, 'username': 'me'},
      {'id': 2, 'username': 'alice', 'name': 'Alice'},
    ],
    'allowed_groups': [
      if (groups) {'name': 'staff', 'full_name': '管理组'},
    ],
    'can_remove_allowed_users': manage,
    'can_invite_to': invite,
    if (leave) 'can_remove_self_id': 1,
  },
});

class _Detail extends TopicDetailNotifier {
  _Detail(this.detail) : super(_params);
  final TopicDetail detail;
  @override
  Future<TopicDetail> build() async => detail;
}

class _Service extends Fake implements DiscourseService {
  final calls = <String>[];

  @override
  Future<MentionSearchResult> searchUsers({
    required String term,
    int? topicId,
    int? categoryId,
    bool includeGroups = true,
    bool includeMessageableGroups = false,
    bool throwOnError = false,
    int limit = 6,
  }) async {
    expect(includeGroups, isFalse);
    expect(includeMessageableGroups, isTrue);
    return const MentionSearchResult(
      users: [MentionUser(id: 7, username: 'bob')],
      groups: [MentionGroup(name: 'team', fullName: '团队')],
    );
  }

  @override
  Future<TopicUser?> invitePrivateMessageUser(
    int topicId,
    String username,
  ) async {
    calls.add('user/$topicId/$username');
    return null;
  }

  @override
  Future<void> invitePrivateMessageGroup(int topicId, String groupName) async {
    calls.add('group/$topicId/$groupName');
  }
}

class _CurrentUser extends CurrentUserNotifier {
  @override
  User build() => User(id: 1, username: 'me', trustLevel: 1);
}

Widget _app(Widget child) => TranslationProvider(
  child: MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: AppLocaleUtils.supportedLocales,
    home: Scaffold(body: child),
  ),
);

Widget _members(
  TopicDetail detail, {
  DiscourseService? service,
  Widget child = const PrivateMessageMembersSheet(params: _params),
}) =>
    ProviderScope(
      overrides: [
        if (service != null)
          discourseServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWith(_CurrentUser.new),
        topicDetailProvider(_params).overrideWith(() => _Detail(detail)),
      ],
      child: _app(child),
    );

void main() {
  testWidgets('私信页头显示成员名字和群组，点按打开名单', (tester) async {
    var opened = false;
    Future<void> show(TopicDetail detail) => tester.pumpWidget(
      _app(
        PrivateMessageMemberSummary(detail: detail, onTap: () => opened = true),
      ),
    );
    await show(_detail());
    final names = _detail().allowedUsers
        .map((user) => user.displayName)
        .join('、');
    expect(find.text(names), findsOneWidget);
    await tester.tap(find.text(names));
    expect(opened, isTrue);
    await show(_detail(groups: true));
    expect(find.text('$names、管理组'), findsOneWidget);
    await show(
      _detail(groups: true).copyWith(
        allowedGroups: const [
          TopicGroup(name: 'staff'),
          TopicGroup(name: 'mods'),
        ],
      ),
    );
    expect(find.text('+1'), findsOneWidget);
    await show(_detail(groups: true).copyWith(allowedUsers: []));
    expect(find.text('管理组'), findsOneWidget);
  });

  testWidgets('群组在前，普通成员只看到自己的退出操作', (tester) async {
    await tester.pumpWidget(_members(_detail(groups: true, leave: true)));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('管理组')).dy,
      lessThan(tester.getTopLeft(find.text('@me')).dy),
    );
    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('退出会话'), findsOneWidget);
    expect(find.byTooltip('更多'), findsNothing);
    expect(find.text('邀请成员'), findsNothing);
  });

  testWidgets('按服务端授权展示邀请和移除入口', (tester) async {
    await tester.pumpWidget(
      _members(_detail(groups: true, manage: true, invite: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('退出会话'), findsNothing);
    expect(find.byTooltip('更多'), findsNWidgets(2));
    await tester.tap(find.byTooltip('更多').last);
    await tester.pumpAndSettle();
    expect(find.text('移除'), findsOneWidget);
  });

  testWidgets('邀请排除自己，标记已加入，部分失败只重试失败项', (tester) async {
    final sent = <String>[];
    var returned = false;
    await tester.pumpWidget(
      _app(
        PrivateMessageInviteSheet(
          detail: _detail(),
          currentUsername: 'me',
          search: (_) async => const MentionSearchResult(
            users: [
              MentionUser(username: 'ME'),
              MentionUser(username: 'ALICE'),
              MentionUser(username: 'bob'),
            ],
            groups: [MentionGroup(name: 'staff')],
          ),
          onInvite: (item) async {
            sent.add(item.mentionName);
            if (item.isGroup && sent.length == 2) throw StateError('失败');
          },
          onBack: () => returned = true,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump(const Duration(milliseconds: 310));
    await tester.pump();
    expect(find.text('@ME'), findsNothing);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '@ALICE')).enabled,
      isFalse,
    );
    expect(find.text('已加入'), findsOneWidget);
    await tester.tap(find.text('@bob'));
    await tester.pump();
    await tester.tap(find.text('群组 · staff'));
    await tester.pump();
    await tester.tap(find.text('邀请 2 项'));
    await tester.pumpAndSettle();
    expect(sent, ['bob', 'staff']);
    expect(returned, isFalse);
    expect(find.widgetWithText(InputChip, 'staff'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'bob'), findsNothing);
    await tester.tap(find.text('邀请 1 项'));
    await tester.pump();
    expect(sent, ['bob', 'staff', 'staff']);
    expect(returned, isTrue);
  });

  testWidgets('从名单进入邀请，用户和群组分别提交并直接展示', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.viewPadding = const FakeViewPadding(top: 44);
    tester.view.padding = const FakeViewPadding(top: 44);
    addTearDown(tester.view.reset);

    final service = _Service();
    await tester.pumpWidget(
      _members(
        _detail(invite: true),
        service: service,
        child: const SizedBox.shrink(),
      ),
    );
    unawaited(
      showAppBottomSheet<void>(
        context: tester.element(find.byType(Scaffold)),
        isScrollControlled: true,
        useSafeArea: true,
        enableDrag: false,
        backgroundColor: Colors.transparent,
        blur: false,
        builder: (_) => const PrivateMessageMembersSheet(params: _params),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('邀请成员'));
    await tester.pumpAndSettle();

    final sheet = find.byType(AppSheetScaffold);
    expect(tester.widget<AppSheetScaffold>(sheet).showDragHandle, isTrue);
    final searchIcon = find.byIcon(Icons.search_rounded);
    final iconCenter = tester.getCenter(searchIcon).dy;
    final hint = find.text('搜索用户或群组');
    expect(tester.getCenter(hint).dy, closeTo(iconCenter, 1));

    tester.view.viewInsets = const FakeViewPadding(bottom: 340);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(sheet).dy, closeTo(44, 1));
    expect(tester.getBottomLeft(find.byType(FilledButton)).dy, lessThan(460));

    await tester.enterText(find.byType(TextField), 'b');
    await tester.pump(const Duration(milliseconds: 310));
    await tester.pump();
    expect(
      tester.getCenter(find.byType(EditableText)).dy,
      closeTo(tester.getCenter(searchIcon).dy, 1),
    );
    await tester.tap(find.text('@bob'));
    await tester.pump();
    await tester.tap(find.text('群组 · team'));
    await tester.pump();
    await tester.tap(find.text('邀请 2 项'));
    await tester.pumpAndSettle();
    expect(service.calls, ['user/42/bob', 'group/42/team']);
    expect(find.text('会话成员'), findsOneWidget);
    expect(find.text('团队'), findsOneWidget);
    expect(find.text('@bob'), findsOneWidget);
  });

  testWidgets('慢响应不会覆盖新查询或恢复清空的候选', (tester) async {
    final requests = <String, Completer<MentionSearchResult>>{};
    await tester.pumpWidget(
      _app(
        PrivateMessageInviteSheet(
          detail: _detail(),
          currentUsername: 'me',
          search: (term) => (requests[term] = Completer()).future,
          onInvite: (_) async {},
          onBack: () {},
        ),
      ),
    );
    for (final term in ['a', 'ab', '']) {
      await tester.enterText(find.byType(TextField), term);
      await tester.pump(const Duration(milliseconds: 310));
    }
    for (final pending in requests.values.toList().reversed) {
      pending.complete(
        const MentionSearchResult(
          users: [MentionUser(username: 'old')],
          groups: [],
        ),
      );
    }
    await tester.pump();
    expect(find.text('@old'), findsNothing);
    expect(find.byType(ListTile), findsNothing);
  });
}
