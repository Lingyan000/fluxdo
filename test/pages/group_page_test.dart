import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/models/user_group.dart';
import 'package:fluxdo/pages/category_topics_page.dart';
import 'package:fluxdo/pages/group_page.dart';
import 'package:fluxdo/pages/groups/group_content.dart';
import 'package:fluxdo/pages/groups/group_identity.dart';
import 'package:fluxdo/pages/groups_page.dart';
import 'package:fluxdo/pages/profile_page.dart';
import 'package:fluxdo/pages/forum_preferences/forum_preferences_page.dart';
import 'package:fluxdo/pages/user_profile_page.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/deep_link_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/utils/category_navigation.dart';
import 'package:fluxdo/utils/dialog_utils.dart';
import 'package:fluxdo/utils/fluxdo_render_callbacks.dart';
import 'package:fluxdo/utils/link_launcher.dart';
import 'package:fluxdo/widgets/common/paged_list_footer.dart';
import 'package:fluxdo/widgets/common/category_selection_sheet.dart';
import 'package:fluxdo/widgets/common/relative_time_text.dart';
import 'package:fluxdo/widgets/topic/painted_topic_card.dart';
import 'package:fluxdo/widgets/topic/topic_card.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/preview_fonts.dart';

const _captureDir = String.fromEnvironment('GROUP_CAPTURE_DIR');

class _Service implements DiscourseService {
  final directoryRequests =
      <
        ({
          String filter,
          String? type,
          GroupDirectoryOrder? order,
          bool ascending,
          int page,
          String? username,
        })
      >[];
  bool failDirectory = false;
  bool paginateDirectory = false;
  Completer<GroupDirectoryResult>? delayedDirectory;

  @override
  Future<GroupDirectoryResult> getGroups({
    String filter = '',
    String? type,
    GroupDirectoryOrder? order,
    bool ascending = true,
    int page = 0,
    String? username,
  }) async {
    directoryRequests.add((
      filter: filter,
      type: type,
      order: order,
      ascending: ascending,
      page: page,
      username: username,
    ));
    if (failDirectory) throw StateError('测试目录加载失败');
    if (filter == 'old') {
      return (delayedDirectory = Completer<GroupDirectoryResult>()).future;
    }
    return GroupDirectoryResult(
      groups: filter == 'empty'
          ? []
          : [
              for (
                var i = page * 15;
                i < (paginateDirectory ? (page == 0 ? 15 : 16) : 3);
                i++
              )
                UserGroupDetail(
                  group: TopicGroup(
                    id: i + 1,
                    name: 'group_$i',
                    userCount: 42 + i,
                  ),
                  displayName: filter.isEmpty ? '开发交流 $i' : '$filter $i',
                  canSeeMembers: true,
                  isMember: i == 0,
                  publicAdmission: i == 1,
                  allowMembershipRequests: i == 2,
                  bioExcerpt: '<p>交流应用开发、开源项目与日常使用经验。</p>',
                ),
            ],
      total: filter == 'empty'
          ? 0
          : paginateDirectory
          ? 16
          : 3,
      moreUrl: '/groups?page=${page + 1}',
      typeFilters: ['my', 'public'],
    );
  }

  bool canSeeMembers = true;
  bool failMembers = false;
  bool failRefresh = false;
  bool isMember = true;
  bool publicAdmission = false;
  bool publicExit = true;
  bool failGroup = false;
  bool failGroupAfterWrite = false;
  bool failWrite = false;
  bool failRequest = false;
  bool paginatePosts = false;
  bool failPosts = false;
  int joins = 0;
  int leaves = 0;
  int permissionRequests = 0;
  int groupRequests = 0;
  final reasons = <String>[];
  final sorts = <(GroupMemberOrder?, bool)>[];
  final postRequests = <(bool, DateTime?, int?)>[];
  final topicRequests = <(int, int?)>[];
  List<Topic> topics = [];
  Completer<GroupPostsPage>? delayedPosts;
  Completer<GroupMembersPage>? nextMembers;

  final memberRequests = <(String, int)>[];
  Completer<GroupMembersPage>? delayedSearch;

  @override
  Future<UserGroupDetail> getGroup(String name) async {
    groupRequests++;
    if (failGroup) throw StateError('测试用户组刷新失败');
    return UserGroupDetail(
      group: TopicGroup(id: 7, name: name, fullName: '开发者交流', userCount: 55),
      displayName: '开发者交流',
      canSeeMembers: canSeeMembers,
      isMember: isMember,
      publicAdmission: publicAdmission,
      publicExit: publicExit,
      allowMembershipRequests: true,
      requestTemplate: '我希望加入',
      messageable: true,
      bio: '<p>一起交流开发经验。<a href="/g/another">相关用户组</a></p>',
    );
  }

  @override
  Future<GroupMembersPage> getGroupMembers(
    String name, {
    String filter = '',
    int offset = 0,
    GroupMemberOrder? order,
    bool ascending = true,
  }) async {
    memberRequests.add((filter, offset));
    sorts.add((order, ascending));
    if (nextMembers != null) {
      final pending = nextMembers!;
      nextMembers = null;
      return pending.future;
    }
    if (filter == 'old') {
      return (delayedSearch = Completer<GroupMembersPage>()).future;
    }
    if (failMembers || (failRefresh && offset == 0)) {
      throw StateError('测试成员加载失败');
    }
    return GroupMembersPage(
      members: filter.isEmpty
          ? [
              for (var i = offset; i < (offset == 0 ? 50 : 55); i++)
                User(
                  id: i + 1,
                  username: 'member_$i',
                  name: '成员 $i',
                  trustLevel: 1,
                  lastSeenAt: DateTime.utc(2026, 11, 11, 12),
                  lastPostedAt: DateTime.utc(2026, 11, 11, 10),
                ),
            ]
          : [User(id: 100, username: filter, trustLevel: 1)],
      ownerIds: {1},
      joinedAt: {1: DateTime.utc(2025, 6, 1)},
      offset: offset,
      limit: 50,
    );
  }

  @override
  Future<List<Category>> getCategories() async => [await getCategory(42)];

  @override
  Future<GroupPostsPage> getGroupPosts(
    String name, {
    bool mentions = false,
    DateTime? before,
    int? categoryId,
  }) async {
    postRequests.add((mentions, before, categoryId));
    if (failPosts) throw StateError('测试活动分页失败');
    if (paginatePosts) {
      return GroupPostsPage(
        posts: [
          for (
            var i = before == null ? 0 : 20;
            i < (before == null ? 20 : 21);
            i++
          )
            GroupActivityPost(
              id: i + 1,
              topicId: 8,
              postNumber: i + 1,
              title: '帖子 $i',
              user: User(id: 1, username: 'alice', trustLevel: 1),
              createdAt: DateTime.utc(
                2026,
                11,
                11,
              ).subtract(Duration(minutes: i)),
            ),
        ],
      );
    }
    if (delayedPosts != null && !mentions) return delayedPosts!.future;
    return GroupPostsPage(
      posts: [
        GroupActivityPost(
          id: mentions ? 2 : 1,
          topicId: 8,
          postNumber: 4,
          title: mentions ? '提及用户组的讨论' : '用户组成员的帖子',
          user: User(id: 1, username: 'alice', trustLevel: 1),
          excerpt: '<p>讨论内容与开发经验</p>',
          createdAt: DateTime.utc(2026, 11, 11),
          categoryId: 42,
        ),
      ],
    );
  }

  @override
  Future<TopicListResponse> getGroupTopics(
    String name, {
    int page = 0,
    int? categoryId,
  }) async {
    topicRequests.add((page, categoryId));
    return TopicListResponse(topics: topics);
  }

  @override
  Future<List<GroupCategoryPermission>> getGroupPermissions(String name) async {
    permissionRequests++;
    return [GroupCategoryPermission(category: await getCategory(42), type: 1)];
  }

  @override
  Future<void> joinGroup(int id) async {
    joins++;
    if (failWrite) throw StateError('测试加入失败');
    isMember = true;
    if (failGroupAfterWrite) failGroup = true;
  }

  @override
  Future<void> leaveGroup(int id) async {
    leaves++;
    if (failWrite) throw StateError('测试离开失败');
    isMember = false;
    canSeeMembers = false;
    if (failGroupAfterWrite) failGroup = true;
  }

  @override
  Future<String?> requestGroupMembership(String name, String reason) async {
    reasons.add(reason);
    if (failRequest) throw StateError('测试申请失败');
    return null;
  }

  @override
  Future<Category> getCategory(int id) async => Category(
    id: id,
    name: '开发调优',
    color: '0088cc',
    textColor: 'ffffff',
    slug: 'develop',
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CurrentUser extends CurrentUserNotifier {
  _CurrentUser({required this.signedIn});
  final bool signedIn;
  final refreshes = <bool>[];
  @override
  Future<void> refreshSilently({bool force = false}) async =>
      refreshes.add(force);
  @override
  Future<User?> build() async =>
      signedIn ? User(id: 99, username: 'viewer', trustLevel: 1) : null;
  void signIn() =>
      state = AsyncData(User(id: 99, username: 'viewer', trustLevel: 1));
}

class _Summary extends UserSummaryNotifier {
  int refreshes = 0;
  @override
  Future<UserSummary?> build() async => null;
  @override
  Future<void> refresh() async => refreshes++;
}

class _Observer extends NavigatorObserver {
  Route<dynamic>? latest;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      latest = route;
}

Future<(BuildContext, _Observer)> _pump(
  WidgetTester tester,
  _Service service, {
  Widget? home,
  double width = 390,
  double textScale = 1,
  bool signedIn = true,
  String themeId = 'material',
  bool? dark,
}) async {
  tester.view.physicalSize = Size(width, 850);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final themeState = ThemeState(
    mode: ThemeMode.system,
    seedColor: Colors.blue,
    themeId: themeId,
  );
  final isDark = dark ?? width == 390;
  final resolved = ThemeResolver.resolve(
    spec: themeState.themeSpec,
    mode: ThemeMode.system,
    black: false,
    seed: themeState.seedColor,
    variant: themeState.schemeVariant,
  );
  final theme = buildAppTheme(
    isDark ? resolved.dark : resolved.light,
    isDark ? resolved.darkColors : resolved.lightColors,
    themeState.effectiveShapes,
    themeState,
    fullscreenSwipeBack: false,
    pageBackground: false,
    style: themeState.effectiveStyle,
  );
  final previewPrimaryFont = Platform.environment['GROUP_PREVIEW_PRIMARY_FONT'];
  if (_captureDir.isNotEmpty) {
    await tester.runAsync(() async {
      await loadPreviewCjkFont(family: 'GroupPreviewCjk');
      if (previewPrimaryFont != null) {
        final loader = FontLoader(theme.textTheme.bodyLarge!.fontFamily!);
        loader.addFont(
          Future.value(
            ByteData.sublistView(File(previewPrimaryFont).readAsBytesSync()),
          ),
        );
        await loader.load();
      }
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final entry in manifest) {
        final family = entry['family'] as String;
        if (!family.contains('Material')) continue;
        final loader = FontLoader(family);
        for (final font in entry['fonts'] as List) {
          loader.addFont(rootBundle.load(font['asset'] as String));
        }
        await loader.load();
      }
    });
  }
  final observer = _Observer();
  late BuildContext context;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWith(
          () => _CurrentUser(signedIn: signedIn),
        ),
        discourseServiceProvider.overrideWithValue(service),
        userSummaryProvider.overrideWith(_Summary.new),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [observer],
          theme: _captureDir.isEmpty
              ? theme
              : theme.copyWith(
                  textTheme: theme.textTheme.apply(
                    fontFamily: previewPrimaryFont == null
                        ? 'GroupPreviewCjk'
                        : null,
                    fontFamilyFallback: const ['GroupPreviewCjk'],
                  ),
                ),
          locale: const Locale('zh'),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: RepaintBoundary(
              key: const ValueKey('group-capture'),
              child: child!,
            ),
          ),
          home: Builder(
            builder: (value) {
              context = value;
              return home ?? const Scaffold();
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (context, observer);
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (_captureDir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('group-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(_captureDir).createSync(recursive: true);
    File('$_captureDir/$name.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void _expectSearchAlignment(WidgetTester tester, Finder field) {
  final shell = find.ancestor(
    of: field,
    matching: find.byType(InputFieldShell),
  );
  final center = tester.getCenter(shell).dy;
  final searchIcon = find.descendant(
    of: field,
    matching: find.byIcon(Symbols.search_rounded),
  );
  final input = find.descendant(of: field, matching: find.byType(EditableText));
  final hint = tester.widget<TextField>(field).decoration!.hintText!;
  expect(tester.getCenter(searchIcon).dy, closeTo(center, 0.5));
  final clearIcon = find.descendant(
    of: field,
    matching: find.byIcon(Symbols.close_rounded),
  );
  if (clearIcon.evaluate().isNotEmpty) {
    expect(tester.getCenter(clearIcon).dy, closeTo(center, 0.5));
  }
  expect(tester.getCenter(input).dy, closeTo(center, 0.5));
  expect(
    tester.getCenter(find.descendant(of: field, matching: find.text(hint))).dy,
    closeTo(center, 0.5),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ThemeRegistry.loadBuiltins);
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('用户组搜索适配 ${platform.name} 的桌面密度', (tester) async {
      await _pump(
        tester,
        _Service(),
        home: const GroupsPage(),
        width: 1000,
        dark: true,
      );
      _expectSearchAlignment(tester, find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Flutter 用户组');
      await tester.pumpAndSettle(const Duration(milliseconds: 350));
      _expectSearchAlignment(tester, find.byType(TextField));
      await tester.tap(find.byTooltip('清除'));
      await tester.pumpAndSettle(const Duration(milliseconds: 350));
      _expectSearchAlignment(tester, find.byType(TextField));
      await _capture(tester, 'directory-${platform.name}');

      await tester.tap(find.text('开发交流 0'));
      await tester.pumpAndSettle();
      _expectSearchAlignment(tester, find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'alice');
      await tester.pumpAndSettle(const Duration(milliseconds: 350));
      _expectSearchAlignment(tester, find.byType(TextField));
      await _capture(tester, 'group-${platform.name}');

      await tester.tap(find.text('活动'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '全部分类'));
      await tester.pumpAndSettle();
      _expectSearchAlignment(tester, find.byType(TextField).last);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }

  for (final (id, dark, width) in [
    ('paper', false, 1000.0),
    ('minimal', true, 390.0),
    ('nord', false, 390.0),
  ]) {
    testWidgets('用户组目录与详情适配 $id 主题', (tester) async {
      final service = _Service();
      await _pump(
        tester,
        service,
        home: const GroupsPage(),
        themeId: id,
        dark: dark,
        width: width,
      );
      _expectSearchAlignment(tester, find.byType(TextField));
      await _capture(tester, 'directory-$id');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('开发交流 0'));
      await tester.pumpAndSettle();
      _expectSearchAlignment(tester, find.byType(TextField));
      await _capture(tester, 'group-$id');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('活动'));
      await tester.pumpAndSettle();
      await _capture(tester, 'activity-$id');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('权限'));
      await tester.pumpAndSettle();
      await _capture(tester, 'permissions-$id');
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 390.0, 1000.0]) {
    testWidgets('用户组目录 $width 布局与原生详情入口', (tester) async {
      final service = _Service();
      final (context, observer) = await _pump(
        tester,
        service,
        home: const GroupsPage(),
        width: width,
        textScale: width == 320 ? 2 : 1,
      );
      expect(find.text('共 3 个用户组'), findsOneWidget);
      expect(find.text('开发交流 0'), findsOneWidget);
      expect(find.text('已加入'), findsOneWidget);
      if (width == 1000) {
        expect(
          tester.getTopLeft(find.text('开发交流 0')).dy,
          tester.getTopLeft(find.text('开发交流 1')).dy,
        );
      } else {
        expect(
          tester.getTopLeft(find.text('开发交流 0')).dy,
          lessThan(tester.getTopLeft(find.text('开发交流 1')).dy),
        );
      }
      _expectSearchAlignment(tester, find.byType(TextField));
      await _capture(tester, 'directory-$width');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('开发交流 0'));
      final page = (observer.latest! as InteractionPageRoute).builder(
        context,
      ) as GroupPage;
      expect(page.name, 'group_0');
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(service.directoryRequests.length, 2);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [390.0, 1000.0]) {
    testWidgets('我的 $width 原生编辑资料并刷新、进入用户组目录', (tester) async {
      final (context, observer) = await _pump(
        tester,
        _Service(),
        home: const ProfilePage(),
        width: width,
      );
      final container = ProviderScope.containerOf(context);
      final currentUser =
          container.read(currentUserProvider.notifier) as _CurrentUser;
      final summary = container.read(userSummaryProvider.notifier) as _Summary;
      await tester.tap(find.byTooltip('编辑资料'));
      final edit = (observer.latest! as InteractionPageRoute).builder(
        context,
      ) as ForumPreferencesPage;
      expect(edit.username, 'viewer');
      expect(edit.initialSection, ForumPreferenceSection.profile);
      Navigator.of(context).pop('viewer');
      await tester.pumpAndSettle();
      expect(currentUser.refreshes, [true]);
      expect(summary.refreshes, 1);
      await tester.tap(find.byTooltip('编辑资料'));
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(currentUser.refreshes, [true]);
      // 宽屏选项在右栏，窄屏复用同一社区入口。
      await tester.ensureVisible(find.text('用户组'));
      await tester.tap(find.text('用户组'));
      expect(
        (observer.latest! as InteractionPageRoute).builder(context),
        isA<GroupsPage>(),
      );
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('目录搜索忽略过期响应，筛选与排序刷新保持一致', (tester) async {
    final service = _Service();
    await _pump(tester, service, home: const GroupsPage(username: 'alice'));
    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    service.delayedDirectory!.complete(
      const GroupDirectoryResult(groups: [], total: 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('new 0'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选用户组'));
    await tester.pumpAndSettle();
    expect(find.text('我管理的'), findsNothing);
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '我加入的'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('用户组排序'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(
        CheckedPopupMenuItem<({GroupDirectoryOrder? order})>,
        '成员数量',
      ),
    );
    await tester.pumpAndSettle();
    expect(service.directoryRequests.last.order, GroupDirectoryOrder.members);
    expect(service.directoryRequests.last.ascending, false);
    await tester.tap(find.byTooltip('降序'));
    await tester.pumpAndSettle();
    await tester
        .widget<M3eRefreshIndicator>(find.byType(M3eRefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(service.directoryRequests.last, (
      filter: 'new',
      type: 'my',
      order: GroupDirectoryOrder.members,
      ascending: true,
      page: 0,
      username: 'alice',
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('目录按服务端分页，失败重试与刷新保留已有内容', (tester) async {
    final service = _Service()..paginateDirectory = true;
    await _pump(tester, service, home: const GroupsPage());
    final scrollable = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );
    service.failDirectory = true;
    await tester.scrollUntilVisible(
      find.byType(PagedListFooter),
      400,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(service.directoryRequests.last.page, 1);
    expect(
      tester
          .widget<PagedListFooter>(find.byType(PagedListFooter))
          .isLoadMoreFailed,
      true,
    );
    service.failDirectory = false;
    tester.widget<PagedListFooter>(find.byType(PagedListFooter)).onRetry();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(PagedListFooter),
      400,
      scrollable: scrollable,
    );
    expect(
      tester.widget<PagedListFooter>(find.byType(PagedListFooter)).hasMore,
      false,
    );
    expect(service.directoryRequests.map((request) => request.page), [0, 1, 1]);
    service.failDirectory = true;
    await tester
        .widget<M3eRefreshIndicator>(find.byType(M3eRefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    service.failDirectory = false;
    tester.widget<PagedListFooter>(find.byType(PagedListFooter)).onRetry();
    await tester.pumpAndSettle();
    expect(service.directoryRequests.last.page, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('目录空态、错误重试与详情页目录入口', (tester) async {
    final service = _Service()..failDirectory = true;
    final (context, observer) = await _pump(
      tester,
      service,
      home: const GroupsPage(),
    );
    expect(find.text('重试'), findsOneWidget);
    service.failDirectory = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'empty');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('没有找到用户组'), findsOneWidget);
    await launchContentLink(context, '/g/team');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全部用户组'));
    expect(
      (observer.latest! as InteractionPageRoute).builder(context),
      isA<GroupsPage>(),
    );
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('正文目录链接与深链保留搜索和筛选参数', (tester) async {
    final service = _Service();
    final (context, observer) = await _pump(tester, service);
    const url =
        '/groups?filter=dev&type=my&order=user_count&asc=false&username=alice';
    await launchContentLink(context, url);
    final page = (observer.latest! as InteractionPageRoute).builder(
      context,
    ) as GroupsPage;
    expect(page.initialFilter, 'dev');
    expect(page.initialType, 'my');
    expect(page.initialOrder, GroupDirectoryOrder.members);
    expect(page.initialAscending, false);
    expect(page.username, 'alice');
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    DeepLinkService.instance.updateContext(context);
    DeepLinkService.instance.handleUri(Uri.parse('https://linux.do$url'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupsPage), findsOneWidget);
    expect(service.directoryRequests.last.username, 'alice');
    expect(service.directoryRequests.last.filter, 'dev');
    DeepLinkService.instance.dispose();
  });

  for (final width in [390.0, 759.0, 760.0, 1000.0, 1440.0]) {
    testWidgets('详情 $width 各区域共用边界，表头与成员列对齐', (tester) async {
      final service = _Service()
        ..topics = TopicListResponse.fromJson({
          'users': [
            {
              'id': 1,
              'username': 'alice',
              'avatar_template': '/user_avatar/linux.do/alice/{size}/1.png',
            },
          ],
          'topic_list': {
            'topics': [
              {
                'id': 1101,
                'title': '分享一个开源工具，交流跨平台应用的开发经验',
                'slug': 'development',
                'category_id': 42,
                'posts_count': 19,
                'reply_count': 18,
                'views': 320,
                'like_count': 27,
                'created_at': '2026-11-11T08:00:00Z',
                'last_posted_at': '2026-11-11T09:00:00Z',
                'tags': ['开源'],
                'posters': [
                  {'user_id': 1, 'extras': 'latest'},
                ],
              },
            ],
          },
        }).topics;
      await _pump(
        tester,
        service,
        width: width,
        dark: width == 1440 ? true : null,
        home: const GroupPage(name: 'team'),
      );
      final frameWidth = width > 1080 ? 1080.0 : width;
      final frameLeft = (width - frameWidth) / 2;
      final contentLeft = frameLeft + 24;
      final contentRight = frameLeft + frameWidth - 24;
      void expectContentEdges(Finder finder) {
        final rect = tester.getRect(finder);
        expect(rect.left, closeTo(contentLeft, 0.01));
        expect(rect.right, closeTo(contentRight, 0.01));
      }

      expect(tester.getRect(find.byType(AppBar)).left, frameLeft);
      expect(tester.getSize(find.byType(AppBar)).width, frameWidth);
      expectContentEdges(find.byType(CustomScrollView));
      expectContentEdges(find.byType(TabBar));
      expectContentEdges(find.byType(GroupMemberTile).first);
      expect(tester.getRect(find.byType(GroupAvatar)).left, contentLeft);
      expect(tester.getRect(find.byType(InputFieldShell)).left, contentLeft);
      expect(
        tester
            .getRect(
              find.byType(
                SwipeDismissiblePopupMenuButton<({GroupMemberOrder? order})>,
              ),
            )
            .right,
        contentRight,
      );
      expect(find.byTooltip('切换用户组'), findsNothing);

      final table = find.byType(GroupMemberColumns);
      if (width >= 760) {
        final headers = find.descendant(
          of: table.first,
          matching: find.byType(TextButton),
        );
        expect(headers, findsNWidgets(4));
        final dates = find.descendant(
          of: find.byType(GroupMemberTile).first,
          matching: find.byType(RelativeTimeText),
        );
        expect(dates, findsNWidgets(3));
        for (var index = 1; index < 4; index++) {
          final heading = headers.at(index);
          final headingText = find.descendant(
            of: heading,
            matching: find.byType(Text),
          );
          expect(
            tester.getRect(headingText).left,
            closeTo(tester.getRect(dates.at(index - 1)).left, 0.01),
          );
          expect(
            tester.getRect(heading).left -
                tester.getRect(headers.at(index - 1)).right,
            greaterThanOrEqualTo(15.99),
          );
          expect(
            tester.getRect(headingText).left - tester.getRect(heading).left,
            greaterThanOrEqualTo(7.99),
          );
        }
        await tester.tap(headers.at(1));
        await tester.pumpAndSettle();
        expect(service.sorts.last, (GroupMemberOrder.joined, false));
        expect(
          tester
              .getRect(
                find.ancestor(
                  of: find.byTooltip('降序'),
                  matching: find.byType(IconButton),
                ),
              )
              .right,
          contentRight,
        );
        final mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: tester.getCenter(headers.at(1)));
        await tester.pumpAndSettle();
        await _capture(tester, 'aligned-members-hover-$width');
        await mouse.removePointer();
        await tester.pumpAndSettle();
      } else {
        expect(table, findsNothing);
      }
      await _capture(tester, 'aligned-members-$width');

      await tester.tap(find.text('活动'));
      await tester.pumpAndSettle();
      expectContentEdges(find.byType(GroupPostTile));
      expect(
        tester.getRect(find.byType(M3eButtonGroup<GroupActivityFilter>)).left,
        contentLeft,
      );
      await _capture(tester, 'aligned-activity-$width');

      await tester.tap(find.text('话题'));
      await tester.pumpAndSettle();
      final topicCard = find.byType(PaintedTopicCard);
      expectContentEdges(topicCard);
      expect(find.byType(CompactTopicCard), findsNothing);
      final card = tester.widget<PaintedTopicCard>(topicCard);
      expect(card.layout.layoutWidth, contentRight - contentLeft);
      expect(card.layout.semanticsLabel, contains(service.topics.single.title));
      expect(card.layout.semanticsLabel, contains('alice'));
      expect(card.layout.avatarRect.isEmpty, isFalse);
      expect(card.layout.author, isNotNull);
      expect(card.layout.time, isNotNull);
      expect(card.layout.catTags, isNotNull);
      expect(card.layout.statsIcons.length, width >= 759 ? 3 : 1);
      expect(card.onTap, isNotNull);
      expect(card.onLongPress, isNotNull);
      await _capture(tester, 'aligned-topics-$width');

      await tester.tap(find.text('权限'));
      await tester.pumpAndSettle();
      expectContentEdges(find.byType(GroupPermissionTile));
      await _capture(tester, 'aligned-permissions-$width');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('详情顶栏保留状态栏安全区和返回操作', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final (context, _) = await _pump(tester, _Service());
    unawaited(
      Navigator.of(context).push(
        InteractionPageRoute(builder: (_) => const GroupPage(name: 'team')),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AppBar)).height, kToolbarHeight + 24);
    expect(
      tester.getRect(find.byType(BackButton)).top,
      greaterThanOrEqualTo(24),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(GroupPage), findsNothing);
  });

  for (final width in [320.0, 390.0, 1000.0]) {
    testWidgets('用户组 $width 搜索、成员权限和原生资料跳转', (tester) async {
      final service = _Service();
      final (context, observer) = await _pump(
        tester,
        service,
        home: const GroupPage(name: 'team'),
        width: width,
        textScale: width == 320 ? 2 : 1,
      );
      expect(find.text('开发者交流'), findsOneWidget);
      expect(find.byTooltip('组管理员'), findsOneWidget);
      expect(tester.takeException(), isNull);
      _expectSearchAlignment(tester, find.byType(TextField));
      await _capture(tester, 'group-$width');

      await tester.enterText(find.byType(TextField), 'old');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.enterText(find.byType(TextField), 'alice');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      service.delayedSearch!.complete(
        const GroupMembersPage(members: [], ownerIds: {}, offset: 0, limit: 50),
      );
      await tester.pumpAndSettle();
      expect(find.text('@alice'), findsOneWidget);
      _expectSearchAlignment(tester, find.byType(TextField));
      expect(service.memberRequests, [('', 0), ('old', 0), ('alice', 0)]);
      await tester.ensureVisible(find.text('@alice'));
      await tester.tap(find.text('@alice'));
      final route = observer.latest! as InteractionPageRoute;
      expect((route.builder(context) as UserProfilePage).username, 'alice');
      Navigator.of(context).pop();
      await tester.pumpAndSettle();

      service.canSeeMembers = false;
      await tester
          .widget<M3eRefreshIndicator>(find.byType(M3eRefreshIndicator))
          .onRefresh();
      await tester.pumpAndSettle();
      expect(find.text('此用户组的成员列表不可见'), findsOneWidget);
      expect(service.memberRequests.length, 3);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 390.0, 1000.0]) {
    testWidgets('活动与权限 $width 布局', (tester) async {
      await _pump(
        tester,
        _Service(),
        width: width,
        textScale: width == 320 ? 2 : 1,
        home: const GroupPage(
          name: 'team',
          initialSection: GroupSection.activity,
        ),
      );
      await _capture(tester, 'activity-$width');
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('权限'));
      await tester.tap(find.text('权限'));
      await tester.pumpAndSettle();
      await _capture(tester, 'permissions-$width');
      expect(find.text('查看、回复和创建话题'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('活动分页失败重试保留游标，刷新从第一页开始', (tester) async {
    final service = _Service()..paginatePosts = true;
    await _pump(
      tester,
      service,
      home: const GroupPage(
        name: 'team',
        initialSection: GroupSection.activity,
      ),
    );
    service.failPosts = true;
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pumpAndSettle();
    final expectedCursor = DateTime.utc(
      2026,
      11,
      11,
    ).subtract(const Duration(minutes: 19));
    expect(service.postRequests.last.$2, expectedCursor);
    expect(
      tester
          .widget<PagedListFooter>(find.byType(PagedListFooter))
          .isLoadMoreFailed,
      true,
    );
    service.failPosts = false;
    tester.widget<PagedListFooter>(find.byType(PagedListFooter)).onRetry();
    await tester.pumpAndSettle();
    expect(service.postRequests.last.$2, expectedCursor);
    await tester.scrollUntilVisible(
      find.byType(PagedListFooter),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<PagedListFooter>(find.byType(PagedListFooter)).hasMore,
      false,
    );
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    await tester
        .widget<M3eRefreshIndicator>(find.byType(M3eRefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(service.postRequests.last.$2, isNull);
    expect(service.memberRequests, isEmpty);
  });

  testWidgets('成员不可见仍可离开和查看分类权限', (tester) async {
    final service = _Service()..canSeeMembers = false;
    final (context, observer) = await _pump(
      tester,
      service,
      home: const GroupPage(name: 'team'),
    );
    expect(find.text('离开用户组'), findsOneWidget);
    expect(find.text('此用户组的成员列表不可见'), findsOneWidget);
    expect(service.memberRequests, isEmpty);
    await _capture(tester, 'members-hidden');
    await tester.tap(find.text('活动'));
    await tester.pumpAndSettle();
    expect(find.text('您无权查看这个用户组的活动'), findsOneWidget);
    expect(service.postRequests, isEmpty);
    await tester.tap(find.text('权限'));
    await tester.pumpAndSettle();
    expect(find.text('查看、回复和创建话题'), findsOneWidget);
    expect(service.permissionRequests, 1);
    await tester
        .widget<M3eRefreshIndicator>(find.byType(M3eRefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(service.permissionRequests, 2);
    await tester.tap(find.text('开发调优'));
    await tester.idle();
    expect(
      ((observer.latest! as InteractionPageRoute).builder(
        context,
      ) as CategoryTopicsPage).category.id,
      42,
    );
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('活动筛选、当前标签刷新和分类筛选', (tester) async {
    final service = _Service();
    await _pump(
      tester,
      service,
      home: const GroupPage(
        name: 'team',
        initialSection: GroupSection.activity,
      ),
    );
    expect(service.memberRequests, isEmpty);
    expect(find.text('用户组成员的帖子'), findsOneWidget);
    await tester.tap(find.text('提及'));
    await tester.pumpAndSettle();
    expect(find.text('提及用户组的讨论'), findsOneWidget);
    await tester
        .widget<M3eRefreshIndicator>(find.byType(M3eRefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(service.postRequests.map((item) => item.$1), [false, true, true]);
    expect(service.memberRequests, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, '全部分类'));
    await tester.pumpAndSettle();
    final picker = find.byType(CategorySelectionSheet);
    expect(picker, findsOneWidget);
    _expectSearchAlignment(tester, find.byType(TextField).last);
    await _capture(tester, 'category-filter');
    // 浏览筛选包含服务端返回的可读分类，无需具备发帖权限。
    expect((await service.getCategory(42)).canCreateTopic, false);
    await tester.enterText(find.byType(TextField).last, '开发');
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: picker, matching: find.text('开发调优')));
    await tester.pumpAndSettle();
    expect(service.postRequests.last.$3, 42);
    await tester.tap(find.text('话题'));
    await tester.pumpAndSettle();
    expect(service.topicRequests, [(0, 42)]);
    expect(find.text('暂无活动'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '开发调优'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CategorySelectionSheet>(picker).selectedCategory?.id,
      42,
    );
    await tester.tap(find.descendant(of: picker, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(service.topicRequests, [(0, 42)]);

    await tester.tap(find.widgetWithText(TextButton, '开发调优'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: picker, matching: find.text('全部分类')));
    await tester.pumpAndSettle();
    expect(service.topicRequests, [(0, 42), (0, null)]);
    expect(find.widgetWithText(TextButton, '全部分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('公共发帖分类选择保留权限过滤与 Category 返回值', (tester) async {
    final service = _Service();
    final readOnly = await service.getCategory(42);
    final child = Category(
      id: 43,
      name: '可发帖子分类',
      color: '0088cc',
      textColor: 'ffffff',
      slug: 'child',
      parentCategoryId: readOnly.id,
      permission: 1,
    );
    final (context, _) = await _pump(tester, service);
    final selected = showAppBottomSheet<Category>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CategorySelectionSheet(categories: [readOnly, child]),
    );
    await tester.pumpAndSettle();
    expect(find.text('开发调优'), findsNothing);
    expect(find.text('全部分类'), findsNothing);
    expect(find.text('可发帖子分类'), findsOneWidget);
    await tester.tap(find.text('可发帖子分类'));
    await tester.pumpAndSettle();
    expect(await selected, same(child));
    expect(tester.takeException(), isNull);
  });

  testWidgets('迟到的帖子响应不会覆盖已选择的提及', (tester) async {
    final pending = Completer<GroupPostsPage>();
    final service = _Service()..delayedPosts = pending;
    await _pump(tester, service, home: const GroupPage(name: 'team'));
    await tester.tap(find.text('活动'));
    await tester.pump();
    await tester.tap(find.text('提及'));
    await tester.pumpAndSettle();
    pending.complete(const GroupPostsPage(posts: []));
    await tester.pumpAndSettle();
    expect(find.text('提及用户组的讨论'), findsOneWidget);
  });

  testWidgets('刷新期间切换标签仍会加载所选内容', (tester) async {
    final service = _Service();
    await _pump(tester, service, home: const GroupPage(name: 'team'));
    final pending = Completer<GroupMembersPage>();
    service.nextMembers = pending;
    final refreshing = tester
        .widget<M3eRefreshIndicator>(find.byType(M3eRefreshIndicator))
        .onRefresh();
    await tester.pump();
    await tester.tap(find.text('权限'));
    await tester.pump();
    pending.complete(
      const GroupMembersPage(members: [], ownerIds: {}, offset: 0, limit: 50),
    );
    await refreshing;
    await tester.pumpAndSettle();
    expect(service.permissionRequests, 1);
    expect(find.text('查看、回复和创建话题'), findsOneWidget);
  });

  testWidgets('离开确认可取消，成功后即使刷新失败也更新成员状态', (tester) async {
    final service = _Service()..failGroupAfterWrite = true;
    await _pump(tester, service, home: const GroupPage(name: 'team'));
    await tester.tap(find.text('离开用户组'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.leaves, 0);
    await tester.tap(find.text('离开用户组'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '离开用户组'),
      ),
    );
    await tester.pumpAndSettle();
    expect(service.leaves, 1);
    expect(find.text('离开用户组'), findsNothing);
    expect(find.text('申请加入'), findsOneWidget);
    expect(find.text('@member_0'), findsNothing);
  });

  testWidgets('登录前点击加入，登录后已是成员时不反向离开', (tester) async {
    final service = _Service()
      ..isMember = false
      ..publicAdmission = true;
    final (context, _) = await _pump(
      tester,
      service,
      signedIn: false,
      home: const GroupPage(name: 'team'),
    );
    await tester.tap(find.text('加入用户组'));
    service.isMember = true;
    (ProviderScope.containerOf(
      context,
    ).read(currentUserProvider.notifier) as _CurrentUser).signIn();
    Navigator.of(context).pop(true);
    await tester.pumpAndSettle();
    expect(service.joins, 0);
    expect(service.leaves, 0);
    expect(find.text('已加入'), findsOneWidget);
    expect(find.text('离开用户组'), findsOneWidget);
  });

  testWidgets('加入失败保留操作，成功后提供退出', (tester) async {
    final service = _Service()
      ..isMember = false
      ..publicAdmission = true
      ..failWrite = true;
    await _pump(tester, service, home: const GroupPage(name: 'team'));
    await tester.tap(find.text('加入用户组'));
    await tester.pumpAndSettle();
    expect(find.text('加入用户组'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    service.failWrite = false;
    await tester.tap(find.text('加入用户组'));
    await tester.pumpAndSettle();
    expect(service.joins, 2);
    expect(find.text('离开用户组'), findsOneWidget);
  });

  testWidgets('申请模板、失败保留输入与成功禁用重复提交', (tester) async {
    final service = _Service()
      ..isMember = false
      ..failRequest = true;
    await _pump(tester, service, home: const GroupPage(name: 'team'));
    await tester.tap(find.text('申请加入'));
    await tester.pumpAndSettle();
    final input = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(input).controller!.text, '我希望加入');
    await tester.enterText(input, '希望交流 Flutter 开发经验');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(input).controller!.text,
      '希望交流 Flutter 开发经验',
    );
    service.failRequest = false;
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(service.reasons, ['希望交流 Flutter 开发经验', '希望交流 Flutter 开发经验']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '申请已发送'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('成员排序与升降序切换', (tester) async {
    final service = _Service();
    await _pump(tester, service, home: const GroupPage(name: 'team'));
    await tester.ensureVisible(find.byTooltip('成员排序'));
    await tester.tap(find.byTooltip('成员排序'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(
        CheckedPopupMenuItem<({GroupMemberOrder? order})>,
        '加入时间',
      ),
    );
    await tester.pumpAndSettle();
    expect(service.sorts.last, (GroupMemberOrder.joined, false));
    await tester.tap(find.byTooltip('降序'));
    await tester.pumpAndSettle();
    expect(service.sorts.last, (GroupMemberOrder.joined, true));
    expect(find.byTooltip('切换用户组'), findsNothing);
  });

  testWidgets('分页失败可重试，末页刷新失败会重试第一页', (tester) async {
    final service = _Service();
    await _pump(tester, service, home: const GroupPage(name: 'team'));
    final scrollable = find.byType(Scrollable).first;
    final scrollState = tester.state<ScrollableState>(scrollable);
    service.failMembers = true;
    scrollState.position.jumpTo(scrollState.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(service.memberRequests.last, ('', 50));
    expect(
      tester
          .widget<PagedListFooter>(find.byType(PagedListFooter))
          .isLoadMoreFailed,
      true,
    );
    service.failMembers = false;
    tester.widget<PagedListFooter>(find.byType(PagedListFooter)).onRetry();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(PagedListFooter),
      300,
      scrollable: scrollable,
    );
    expect(
      tester.widget<PagedListFooter>(find.byType(PagedListFooter)).hasMore,
      false,
    );
    service.failRefresh = true;
    await tester
        .widget<M3eRefreshIndicator>(find.byType(M3eRefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    service.failRefresh = false;
    final requestsBeforeRetry = service.memberRequests.length;
    tester.widget<PagedListFooter>(find.byType(PagedListFooter)).onRetry();
    await tester.pumpAndSettle();
    expect(service.memberRequests[requestsBeforeRetry], ('', 0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('正文用户组链接与提及、外部深链都进入原生页面', (tester) async {
    final service = _Service();
    final (context, observer) = await _pump(tester, service);
    for (final url in [
      '/g/team',
      'https://linux.do/groups/team/members',
      '//linux.do/g/team',
      '/g/team/activity/mentions?category_id=42',
      '/groups/team/permissions',
    ]) {
      await launchContentLink(context, url);
      final page = (observer.latest! as InteractionPageRoute).builder(
        context,
      ) as GroupPage;
      if (url.contains('/activity/')) {
        expect(page.initialSection, GroupSection.activity);
        expect(page.initialActivityFilter, GroupActivityFilter.mentions);
        expect(page.initialCategoryId, 42);
      }
      if (url.endsWith('/permissions')) {
        expect(page.initialSection, GroupSection.permissions);
      }
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
    }
    FluxdoRenderCallbacks.generic(heroTagNamespace: 'test')
        .mentionTapHandler(context, 'team', '/g/team');
    await tester.pumpAndSettle();
    expect(find.byType(GroupPage), findsOneWidget);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    DeepLinkService.instance.updateContext(context);
    DeepLinkService.instance.handleUri(
      Uri.parse('https://linux.do/g/team/activity/topics?category_id=42'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GroupPage), findsOneWidget);
    final deepPage = tester.widget<GroupPage>(find.byType(GroupPage));
    expect(deepPage.initialSection, GroupSection.activity);
    expect(deepPage.initialActivityFilter, GroupActivityFilter.topics);
    expect(service.topicRequests.last.$2, 42);
    DeepLinkService.instance.dispose();
    expect(isInternalUrlString('//example.com/g/team'), false);
  });

  testWidgets('概览与独立正文的分类链接均可打开现有分类页', (tester) async {
    final (context, observer) = await _pump(tester, _Service());
    await openCategoryPage(context, 42, useWorkspace: false);
    expect(
      ((observer.latest! as InteractionPageRoute).builder(
        context,
      ) as CategoryTopicsPage).category.id,
      42,
    );
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await launchContentLink(context, '/c/parent/develop/42');
    expect(
      ((observer.latest! as InteractionPageRoute).builder(
        context,
      ) as CategoryTopicsPage).category.slug,
      'develop',
    );
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  });
}
