import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/selected_topic_provider.dart';
import 'package:fluxdo/widgets/layout/master_detail_layout.dart';
import 'package:fluxdo/widgets/layout/pane_projection_back_scope.dart';
import 'package:fluxdo/widgets/layout/pane_filmstrip.dart';

/// 窄屏投影态(projectDetailWhenNarrow)的核心契约:
/// - 窄屏栈非空 = detail 全宽投影,master 保留在树中(State 不丢);
/// - 系统返回逐层退栈,基础层清空回列表;
/// - 变宽 = 同树重排回双栏,栈原样保留。
void main() {
  Future<void> sendBack(
    WidgetTester tester,
    String method, [
    double progress = 0,
  ]) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, {
        'touchOffset': <double>[0, 300],
        'progress': progress,
        'swipeEdge': 0,
      }),
    ),
    (_) {},
  );

  testWidgets('投影返回可连续打断回弹，确认后立即退栈并滚动列表', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 800);
    addTearDown(tester.view.reset);
    addTearDown(() => PaneProjectionBack.progress.value = 0);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final scroll = ScrollController(initialScrollOffset: 400);
    addTearDown(scroll.dispose);
    container
        .read(selectedSeekingProvider.notifier)
        .select(topicId: 1, instanceId: 'topic-1');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              final selected = ref.watch(selectedSeekingProvider);
              return PaneProjectionBackScope(
                stackProvider: selectedSeekingProvider,
                child: MasterDetailLayout(
                  projectDetailWhenNarrow: true,
                  master: ListView.builder(
                    controller: scroll,
                    itemExtent: 60,
                    itemCount: 100,
                    itemBuilder: (_, i) => Text('row $i'),
                  ),
                  detail: selected.hasSelection
                      ? const ColoredBox(color: Colors.blue)
                      : null,
                  emptyDetail: const SizedBox.shrink(),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final progress in [.5, .3]) {
      await sendBack(tester, 'startBackGesture');
      await sendBack(tester, 'updateBackGestureProgress', progress);
      await tester.pump();
      await sendBack(tester, 'cancelBackGesture');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(PaneProjectionBack.progress.value, inExclusiveRange(0, progress));
    }
    await sendBack(tester, 'startBackGesture');
    await sendBack(tester, 'updateBackGestureProgress', .4);
    await tester.pump(const Duration(milliseconds: 250));
    expect(PaneProjectionBack.progress.value, .4, reason: '旧回弹不得覆盖新手势');
    await sendBack(tester, 'commitBackGesture');
    expect(
      container.read(selectedSeekingProvider).hasSelection,
      isFalse,
      reason: '逻辑退栈不等待退出动画',
    );
    await tester.pump();
    final before = scroll.offset;
    await tester.dragFrom(const Offset(300, 400), const Offset(3, -150));
    expect(scroll.offset - before, greaterThan(80));
    await tester.pumpAndSettle();
    expect(PaneProjectionBack.progress.value, 0);
    expect(tester.takeException(), isNull);
  });

  Widget buildHost(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            final selected = ref.watch(selectedSeekingProvider);
            return PaneProjectionBackScope(
              stackProvider: selectedSeekingProvider,
              child: MasterDetailLayout(
                projectDetailWhenNarrow: true,
                master: const Scaffold(body: Text('列表页')),
                // 默认空态组件要查 l10n(TranslationProvider),测试环境
                // 没有翻译树,给显式空态绕开。
                emptyDetail: const SizedBox.shrink(),
                detail: selected.hasSelection
                    ? Scaffold(
                        body: Text(
                          '${selected.kind?.name}:'
                          '${selected.username ?? selected.topicId}',
                        ),
                      )
                    : null,
              ),
            );
          },
        ),
      ),
    );
  }

  testWidgets('窄屏栈非空=投影全宽,返回逐层退栈到清空', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 800);
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedSeekingProvider.notifier)
      ..select(topicId: 1, instanceId: 'topic-1')
      ..pushProfile('alice');

    await tester.pumpWidget(buildHost(container));
    await tester.pumpAndSettle();

    // 投影态:栈顶全宽可见,列表被盖住但仍在树中(State 保留)
    expect(find.text('profile:alice'), findsOneWidget);
    expect(find.text('列表页', skipOffstage: false), findsOneWidget);

    // 系统返回:退一层
    final dynamic widgetsAppState = tester.state(find.byType(WidgetsApp));
    await widgetsAppState.didPopRoute();
    await tester.pumpAndSettle();
    expect(find.text('topic:1'), findsOneWidget);
    expect(container.read(selectedSeekingProvider).stack, hasLength(1));

    // 再返回:基础层清空,回列表
    await widgetsAppState.didPopRoute();
    await tester.pumpAndSettle();
    expect(find.text('列表页'), findsOneWidget);
    expect(container.read(selectedSeekingProvider).stack, isEmpty);
  });

  testWidgets('宽窄往返=同树重排,栈原样保留', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedSeekingProvider.notifier)
      ..select(topicId: 1, instanceId: 'topic-1')
      ..pushProfile('alice');

    await tester.pumpWidget(buildHost(container));
    await tester.pumpAndSettle();

    // 宽屏双栏:列表+详情同时可见
    expect(find.text('列表页'), findsOneWidget);
    expect(find.text('profile:alice'), findsOneWidget);

    // 缩窄:投影态,栈不动
    tester.view.physicalSize = const Size(500, 800);
    await tester.pumpAndSettle();
    expect(find.text('profile:alice'), findsOneWidget);
    expect(container.read(selectedSeekingProvider).stack, hasLength(2));

    // 变宽:还原双栏,栈仍原样(不再有合成路由/didUpdateWidget 重放)
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    expect(find.text('列表页'), findsOneWidget);
    expect(find.text('profile:alice'), findsOneWidget);
    expect(container.read(selectedSeekingProvider).stack, hasLength(2));
  });
}
