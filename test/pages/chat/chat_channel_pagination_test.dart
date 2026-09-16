import 'dart:async';

import 'package:m3e_ui/m3e_ui.dart';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/chat/chat_message.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/pages/chat/channel/chat_channel_page.dart';
import 'package:fluxdo/providers/chat/chat_channels_provider.dart';
import 'package:fluxdo/providers/chat/chat_messages_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

const _streamKey = (channelId: 1, threadId: 1, targetMessageId: null);
const _pastLoading = ValueKey('chat_loading_past');
const _futureLoading = ValueKey('chat_loading_future');

class _CurrentUser extends CurrentUserNotifier {
  @override
  Future<User?> build() async => null;
}

class _Channels extends ChatChannelsNotifier {
  @override
  Future<ChatChannelsState> build() async => const ChatChannelsState();
}

List<ChatMessage> _messages(
  int first,
  int last, {
  bool variedHeights = false,
}) => [
  for (var id = first; id <= last; id++)
    ChatMessage(
      id: id,
      channelId: 1,
      message: '消息 $id',
      cooked:
          '<p>${List.filled(variedHeights ? id % 5 + 1 : 1, '消息 $id').join('<br>')}</p>',
      createdAt: variedHeights
          ? DateTime.utc(2026, 9, 15).add(Duration(minutes: id * 8))
          : null,
    ),
];

class _Messages extends ChatMessagesNotifier {
  _Messages({
    int count = 40,
    this.variedHeights = false,
    bool canLoadMoreFuture = true,
  }) : initial = ChatMessagesState(
         messages: _messages(101, 100 + count, variedHeights: variedHeights),
         canLoadMorePast: true,
         canLoadMoreFuture: canLoadMoreFuture,
       ),
       super(_streamKey);

  final ChatMessagesState initial;
  final bool variedHeights;
  int pastCalls = 0;
  int futureCalls = 0;
  Completer<void>? _pastRequest;
  Completer<void>? _futureRequest;

  Completer<ChatMessagesState>? reloadRequest;
  @override
  Future<ChatMessagesState> build() async =>
      reloadRequest == null ? initial : await reloadRequest!.future;

  @override
  Future<void> loadPast() async {
    pastCalls++;
    state = AsyncData(state.requireValue.copyWith(loadingPast: true));
    _pastRequest = Completer<void>();
    await _pastRequest!.future;
  }

  @override
  Future<void> loadFuture() async {
    futureCalls++;
    state = AsyncData(state.requireValue.copyWith(loadingFuture: true));
    _futureRequest = Completer<void>();
    await _futureRequest!.future;
  }

  void finishPast({int count = 0, bool hasMore = true}) {
    final current = state.requireValue;
    final first = current.messages.first.id;
    state = AsyncData(
      current.copyWith(
        messages: [
          ..._messages(first - count, first - 1, variedHeights: variedHeights),
          ...current.messages,
        ],
        loadingPast: false,
        canLoadMorePast: hasMore,
      ),
    );
    _pastRequest?.complete();
    _pastRequest = null;
  }

  void finishFuture({int count = 0, bool hasMore = true}) {
    final current = state.requireValue;
    final last = current.messages.last.id;
    state = AsyncData(
      current.copyWith(
        messages: [
          ...current.messages,
          ..._messages(last + 1, last + count, variedHeights: variedHeights),
        ],
        loadingFuture: false,
        canLoadMoreFuture: hasMore,
      ),
    );
    _futureRequest?.complete();
    _futureRequest = null;
  }

  void receiveMessage() {
    final current = state.requireValue;
    final id = current.messages.last.id + 1;
    state = AsyncData(
      current.copyWith(
        messages: [
          ...current.messages,
          ..._messages(id, id, variedHeights: variedHeights),
        ],
      ),
    );
  }

  void addReplyReference(int messageId, int targetId) {
    final current = state.requireValue;
    state = AsyncData(
      current.copyWith(
        messages: [
          for (final message in current.messages)
            if (message.id == messageId)
              ChatMessage(
                id: message.id,
                channelId: message.channelId,
                message: message.message,
                cooked: message.cooked,
                inReplyTo: ChatMessageReplyRef(
                  id: targetId,
                  excerpt: '定位到消息 $targetId',
                ),
              )
            else
              message,
        ],
      ),
    );
  }

  Completer<void>? windowRequest;
  int olderWindowCount = 25;

  @override
  Future<bool> loadWindowAround(int messageId) async {
    if (state.requireValue.messages.any((m) => m.id == messageId)) {
      return true;
    }
    windowRequest = Completer<void>();
    await windowRequest!.future;
    state = AsyncData(
      ChatMessagesState(
        messages: _messages(
          messageId - olderWindowCount,
          messageId + 25,
          variedHeights: true,
        ),
        canLoadMorePast: true,
        canLoadMoreFuture: true,
      ),
    );
    return true;
  }

  void removeMessage(int id) {
    state = AsyncData(
      state.requireValue.copyWith(
        messages: state.requireValue.messages.where((m) => m.id != id).toList(),
      ),
    );
  }
}

Future<ScrollController> _pumpPage(
  WidgetTester tester,
  _Messages messages, {
  TargetPlatform platform = TargetPlatform.android,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserProvider.overrideWith(_CurrentUser.new),
        chatChannelsProvider.overrideWith(_Channels.new),
        chatMessagesProvider(_streamKey).overrideWith(() => messages),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: ThemeData(platform: platform),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: const ChatChannelPage(channelId: 1, threadId: 1),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester
      .widget<CustomScrollView>(find.byType(CustomScrollView))
      .controller!;
}

Future<void> _disposePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _nearHistory(
  WidgetTester tester,
  ScrollController controller,
) async {
  // 先布局最老的行，让变高列表的预估范围收敛到实际范围。
  controller.jumpTo(controller.position.maxScrollExtent);
  await tester.pumpAndSettle();
  controller.jumpTo(controller.position.maxScrollExtent - 320);
  await tester.pumpAndSettle();
}

Finder _visibleMessage(WidgetTester tester) {
  final viewport = tester.getRect(find.byType(CustomScrollView));
  final bottom = tester.getTopLeft(find.byType(TextField)).dy;
  final visible = find.byType(AutoScrollTag).evaluate().firstWhere((element) {
    final rect = tester.getRect(find.byKey(element.widget.key!));
    return rect.top >= viewport.top && rect.bottom <= bottom;
  });
  return find.byKey(visible.widget.key!);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlatformUtils.debugDesktopOverride = false;
  });

  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  testWidgets('首屏布局和程序定位不触发分页', (tester) async {
    final messages = _Messages();
    final controller = await _pumpPage(tester, messages);

    expect(messages.pastCalls, 0);
    expect(messages.futureCalls, 0);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    controller.jumpTo(0);
    await tester.pumpAndSettle();

    expect(messages.pastCalls, 0);
    expect(messages.futureCalls, 0);
    await _disposePage(tester);
  });

  testWidgets('提前加载历史时提示可见，慢请求内不重复加载', (tester) async {
    final messages = _Messages();
    final controller = await _pumpPage(tester, messages);
    await _nearHistory(tester, controller);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();

    expect(messages.pastCalls, 1);
    expect(messages.futureCalls, 0);
    expect(find.byKey(_pastLoading), findsOneWidget);
    final viewport = tester.getRect(find.byType(CustomScrollView));
    expect(
      viewport.contains(tester.getCenter(find.byKey(_pastLoading))),
      isTrue,
    );

    await gesture.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(seconds: 1));
    expect(messages.pastCalls, 1);

    messages.finishPast(count: 20);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_pastLoading), findsNothing);
    expect(messages.pastCalls, 1);
    await gesture.up();
    await _disposePage(tester);
  });

  testWidgets('短页保持在边缘时一轮拖动只加载一次，新手势可以重试', (tester) async {
    final messages = _Messages(count: 2);
    await _pumpPage(tester, messages);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(messages.pastCalls, 1);
    messages.finishPast();
    await tester.pump();
    await tester.pump();

    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(messages.pastCalls, 1);
    expect(messages.futureCalls, 0);
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 80));
    await tester.pump();
    expect(messages.pastCalls, 2);
    messages.finishPast(hasMore: false);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(messages.pastCalls, 2);
    await _disposePage(tester);
  });

  testWidgets('向最新消息滚动只加载未来页，并在输入条上方显示提示', (tester) async {
    final messages = _Messages(count: 2);
    await _pumpPage(tester, messages);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -80));
    await tester.pump();
    expect(messages.futureCalls, 1);
    expect(messages.pastCalls, 0);
    expect(find.byKey(_futureLoading), findsOneWidget);
    expect(find.byKey(_pastLoading), findsNothing);
    expect(
      tester.getBottomLeft(find.byKey(_futureLoading)).dy,
      lessThan(tester.getTopLeft(find.byType(TextField)).dy),
    );

    messages.finishFuture();
    await tester.pumpAndSettle();
    await _disposePage(tester);
  });

  testWidgets('历史页落地及 loading 显隐不挪动当前消息', (tester) async {
    final messages = _Messages();
    final controller = await _pumpPage(tester, messages);
    await _nearHistory(tester, controller);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(messages.pastCalls, 1);
    final visibleMessage = find.byKey(const ValueKey('chat_msg_110'));
    expect(visibleMessage, findsOneWidget);
    final before = tester.getTopLeft(visibleMessage);
    final offset = controller.offset;

    messages.finishPast(count: 20);
    await tester.pump();
    await tester.pump();
    expect(tester.getTopLeft(visibleMessage), before);
    expect(controller.offset, offset);
    expect(messages.pastCalls, 1);
    await gesture.up();
    await _disposePage(tester);
  });

  testWidgets('较新消息分页后仍停留在原消息，不跳到最新一页', (tester) async {
    final messages = _Messages();
    final controller = await _pumpPage(tester, messages);
    controller.jumpTo(250);
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(const Offset(0, -20));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(messages.futureCalls, 1);

    final visibleMessage = find.byKey(const ValueKey('chat_msg_136'));
    expect(visibleMessage, findsOneWidget);
    final before = tester.getTopLeft(visibleMessage);

    messages.finishFuture(count: 50);
    await tester.pump();
    await tester.pump();
    expect(visibleMessage, findsOneWidget);
    expect(tester.getTopLeft(visibleMessage), before);
    expect(messages.futureCalls, 1);
    await gesture.up();
    await _disposePage(tester);
  });

  testWidgets('长短消息混排时，分页保留响应到达时的位置并允许继续翻页', (tester) async {
    final messages = _Messages(variedHeights: true);
    final controller = await _pumpPage(tester, messages);

    for (var page = 1; page <= 2; page++) {
      controller.jumpTo(controller.position.minScrollExtent + 250);
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CustomScrollView)),
      );
      await gesture.moveBy(const Offset(0, -20));
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      expect(messages.futureCalls, page);

      // 网络等待期间继续滑动，不能恢复成请求发出时的旧位置。
      await gesture.moveBy(const Offset(0, -50));
      await tester.pump();
      final message = _visibleMessage(tester);
      final before = tester.getTopLeft(message);
      final offset = controller.offset;
      messages.finishFuture(count: 50);
      await tester.pump();
      await tester.pump();

      expect(message, findsOneWidget);
      expect(tester.getTopLeft(message), before);
      expect(controller.offset, offset);
      expect(messages.futureCalls, page);
      await gesture.up();
      await tester.pumpAndSettle();
    }
    await _disposePage(tester);
  });

  testWidgets('向旧翻页同时收到实时新消息，不会把阅读位置拉到底部', (tester) async {
    final messages = _Messages(variedHeights: true, canLoadMoreFuture: false);
    final controller = await _pumpPage(tester, messages);
    await _nearHistory(tester, controller);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(messages.pastCalls, 1);

    final message = _visibleMessage(tester);
    final before = tester.getTopLeft(message);
    messages.receiveMessage();
    await tester.pump();
    expect(tester.getTopLeft(message), before);

    messages.finishPast(count: 50);
    await tester.pump();
    await tester.pump();
    expect(tester.getTopLeft(message), before);
    expect(messages.pastCalls, 1);
    await gesture.up();
    await _disposePage(tester);
  });

  testWidgets('分页到最新后，回到底部按钮使用实际下边界', (tester) async {
    final messages = _Messages(variedHeights: true);
    final controller = await _pumpPage(tester, messages);
    controller.jumpTo(250);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -120));
    await tester.pump();
    expect(messages.futureCalls, 1);

    messages.finishFuture(count: 50, hasMore: false);
    await tester.pumpAndSettle();
    expect(controller.position.minScrollExtent, lessThan(0));
    expect(controller.position.extentBefore, greaterThan(600));
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(controller.position.extentBefore, closeTo(0, 1));
    expect(find.byKey(const ValueKey('chat_msg_190')), findsOneWidget);
    expect(messages.futureCalls, 1);
    await _disposePage(tester);
  });

  testWidgets('实时消息仅在贴底时跟随，阅读历史时保持原位', (tester) async {
    final messages = _Messages(variedHeights: true, canLoadMoreFuture: false);
    final controller = await _pumpPage(tester, messages);
    controller.jumpTo(800);
    await tester.pumpAndSettle();
    final message = _visibleMessage(tester);
    final before = tester.getTopLeft(message);
    messages.receiveMessage();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(message), before);

    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pumpAndSettle();
    messages.receiveMessage();
    await tester.pumpAndSettle();
    expect(controller.position.extentBefore, closeTo(0, 1));
    expect(find.byKey(const ValueKey('chat_msg_142')), findsOneWidget);
    await _disposePage(tester);
  });

  testWidgets('分页接缝没有输入条占位造成的空白', (tester) async {
    final messages = _Messages();
    final controller = await _pumpPage(tester, messages);
    controller.jumpTo(250);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -120));
    await tester.pump();
    messages.finishFuture(count: 2);
    await tester.pumpAndSettle();
    controller.jumpTo(-100);
    await tester.pumpAndSettle();

    final older = tester.getRect(find.byKey(const ValueKey('chat_msg_140')));
    final newer = tester.getRect(find.byKey(const ValueKey('chat_msg_141')));
    expect(older.bottom, closeTo(newer.top, 0.01));
    await _disposePage(tester);
  });

  testWidgets('分页后点击引用仍能定位到新页中尚未渲染的消息', (tester) async {
    final messages = _Messages();
    final controller = await _pumpPage(tester, messages);
    controller.jumpTo(250);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -120));
    await tester.pump();
    messages.finishFuture(count: 50);
    await tester.pumpAndSettle();
    messages.addReplyReference(136, 185);
    await tester.pumpAndSettle();
    final target = find.byKey(const ValueKey('chat_msg_185'));
    expect(target, findsNothing);

    await tester.tap(find.text('定位到消息 185'));
    await tester.pumpAndSettle();
    expect(target, findsOneWidget);
    final viewport = tester.getRect(find.byType(CustomScrollView));
    expect(viewport.contains(tester.getCenter(target)), isTrue);
    expect(messages.futureCalls, 1);
    await _disposePage(tester);
  });

  testWidgets('回到底部需要重载时显示 loading，完成后显示最新窗口', (tester) async {
    final messages = _Messages();
    final controller = await _pumpPage(tester, messages);
    controller.jumpTo(1000);
    await tester.pumpAndSettle();
    messages.reloadRequest = Completer<ChatMessagesState>();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CustomScrollView), findsNothing);
    expect(find.byType(LoadingSpinner), findsOneWidget);

    messages.reloadRequest!.complete(
      ChatMessagesState(messages: _messages(201, 240), canLoadMorePast: true),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(LoadingSpinner), findsNothing);
    expect(find.byKey(const ValueKey('chat_msg_240')), findsOneWidget);
    expect(controller.position.extentBefore, closeTo(0, 1));
    await _disposePage(tester);
  });

  testWidgets('定位加载期间回底不重入，定位完成后回底能结束 loading', (tester) async {
    final messages = _Messages(variedHeights: true);
    final controller = await _pumpPage(tester, messages);
    controller.jumpTo(1800);
    await tester.pumpAndSettle();
    final visible = tester.widget<AutoScrollTag>(_visibleMessage(tester));
    messages.addReplyReference(visible.index, 50);
    await tester.pumpAndSettle();
    await tester.tap(find.text('定位到消息 50'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(CustomScrollView), findsNothing);
    // 定位尚未结束时回底不能重建 provider 或启动第二个窗口请求。
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(messages.windowRequest!.isCompleted, isFalse);
    messages.windowRequest!.complete();
    await tester.pump();
    await tester.pumpAndSettle();
    final target = find.byKey(const ValueKey('chat_msg_50'));
    expect(target, findsOneWidget);
    final viewport = tester.getRect(find.byType(CustomScrollView));
    expect(viewport.contains(tester.getCenter(target)), isTrue);
    expect(messages.pastCalls, 0);
    expect(messages.futureCalls, 0);

    messages.reloadRequest = Completer<ChatMessagesState>();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(find.byType(LoadingSpinner), findsOneWidget);
    messages.reloadRequest!.complete(
      ChatMessagesState(messages: _messages(201, 240), canLoadMorePast: true),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(LoadingSpinner), findsNothing);
    expect(find.byKey(const ValueKey('chat_msg_240')), findsOneWidget);
    await _disposePage(tester);
  });

  testWidgets('定位接近历史起点后，上边界没有整屏空白', (tester) async {
    final messages = _Messages()..olderWindowCount = 0;
    final controller = await _pumpPage(tester, messages);
    messages.addReplyReference(140, 50);
    await tester.pumpAndSettle();
    await tester.tap(find.text('定位到消息 50'));
    await tester.pump();
    messages.windowRequest!.complete();
    await tester.pump();
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    final first = find.byKey(const ValueKey('chat_msg_50'));
    expect(first, findsOneWidget);
    final viewport = tester.getRect(find.byType(CustomScrollView));
    expect(tester.getTopLeft(first).dy - viewport.top, closeTo(8, 1));
    await _disposePage(tester);
  });

  testWidgets('固定原点消息被删除后仍留在相邻历史消息', (tester) async {
    final messages = _Messages();
    final controller = await _pumpPage(tester, messages);
    controller.jumpTo(250);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -120));
    await tester.pump();
    messages.finishFuture(count: 50);
    await tester.pumpAndSettle();
    final message = _visibleMessage(tester);
    final before = tester.getTopLeft(message);

    messages.removeMessage(140);
    await tester.pumpAndSettle();
    expect(message, findsOneWidget);
    expect((tester.getTopLeft(message).dy - before.dy).abs(), lessThan(100));
    expect(find.byKey(const ValueKey('chat_msg_190')), findsNothing);
    await _disposePage(tester);
  });

  testWidgets('短列表回弹不触发相反方向分页', (tester) async {
    final messages = _Messages(count: 2);
    await _pumpPage(tester, messages, platform: TargetPlatform.iOS);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 120));
    await tester.pump();
    expect(messages.pastCalls, 1);
    messages.finishPast();
    await tester.pumpAndSettle();
    expect(messages.pastCalls, 1);
    expect(messages.futureCalls, 0);
    await _disposePage(tester);
  });

  testWidgets('鼠标滚轮接近历史边缘也能分页', (tester) async {
    final messages = _Messages();
    final controller = await _pumpPage(
      tester,
      messages,
      platform: TargetPlatform.windows,
    );
    await _nearHistory(tester, controller);

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(CustomScrollView)),
        scrollDelta: const Offset(0, -100),
      ),
    );
    await tester.pump();
    expect(messages.pastCalls, 1);
    expect(messages.futureCalls, 0);
    messages.finishPast(count: 20);
    await tester.pumpAndSettle();
    await _disposePage(tester);
  });
}
