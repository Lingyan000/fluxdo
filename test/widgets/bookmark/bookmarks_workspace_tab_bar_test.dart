import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/pages/bookmarks/bookmarks_models.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/bookmark/bookmarks_workspace_tab_bar.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

void main() {
  testWidgets('鼠标滚轮会横向滚动工作区标签且不切换当前标签', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    await tester.pumpWidget(const _WorkspaceTabBarTestHost());
    await tester.pumpAndSettle();

    final state = tester.state<_WorkspaceTabBarTestHostState>(
      find.byType(_WorkspaceTabBarTestHost),
    );
    final scrollable = tester.state<ScrollableState>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.right,
      ),
    );
    expect(scrollable.position.pixels, 0);
    expect(state._state.activeTabId, BookmarksWorkspaceState.bookmarksTabId);

    final region = find.byKey(
      const ValueKey('bookmark-workspace-tabs-wheel-region'),
    );
    final center = tester.getCenter(region);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: center);
    await tester.pump();

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: center,
        scrollDelta: const Offset(0, 20),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pumpAndSettle();

    expect(scrollable.position.pixels, greaterThan(0));
    expect(state._state.activeTabId, BookmarksWorkspaceState.bookmarksTabId);
  });

  testWidgets('点击搜索按钮会触发工作区搜索', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    await tester.pumpWidget(const _WorkspaceTabBarTestHost());
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('bookmark-workspace-search-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('search:true'), findsOneWidget);
  });
}

class _WorkspaceTabBarTestHost extends StatefulWidget {
  const _WorkspaceTabBarTestHost();

  @override
  State<_WorkspaceTabBarTestHost> createState() =>
      _WorkspaceTabBarTestHostState();
}

class _WorkspaceTabBarTestHostState extends State<_WorkspaceTabBarTestHost> {
  BookmarksWorkspaceState _state = const BookmarksWorkspaceState()
      .openTopicTab(topicId: 1, title: 'Topic A')
      .openTopicTab(topicId: 2, title: 'Topic B')
      .openTopicTab(topicId: 3, title: 'Topic C')
      .openTopicTab(topicId: 4, title: 'Topic D')
      .openTopicTab(topicId: 5, title: 'Topic E')
      .openTopicTab(topicId: 6, title: 'Topic F')
      .activateBookmarksTab();
  bool _searchPressed = false;

  @override
  Widget build(BuildContext context) {
    return TranslationProvider(
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                width: 320,
                child: BookmarksWorkspaceTabBar(
                  activeTabId: _state.activeTabId,
                  topicTabs: _state.topicTabs,
                  bookmarksLabel: '我的书签',
                  onSearchTap: () {
                    setState(() {
                      _searchPressed = true;
                    });
                  },
                  onBookmarksTap: () {
                    setState(() {
                      _state = _state.activateBookmarksTab();
                    });
                  },
                  onTopicTap: (topicId) {
                    setState(() {
                      _state = _state.activateTopicTab(topicId);
                    });
                  },
                  onTopicClose: (topicId) {
                    setState(() {
                      _state = _state.closeTopicTab(topicId);
                    });
                  },
                ),
              ),
              Text('active:${_state.activeTabId}'),
              Text('search:$_searchPressed'),
            ],
          ),
        ),
      ),
    );
  }
}
