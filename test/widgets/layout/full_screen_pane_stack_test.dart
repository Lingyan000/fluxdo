import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/selected_topic_provider.dart';
import 'package:fluxdo/widgets/layout/auto_restore_master_detail_route.dart';
import 'package:fluxdo/widgets/layout/full_screen_pane_stack.dart';

void main() {
  testWidgets('单栏返回逐层退出平行视界栈', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedSeekingProvider.notifier)
      ..select(topicId: 1, instanceId: 'topic-1')
      ..pushProfile('alice');
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('追觅主页')),
        ),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => _buildPaneStack()),
    );
    await tester.pumpAndSettle();

    expect(find.text('profile:alice'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('topic:1'), findsOneWidget);
    expect(container.read(selectedSeekingProvider).stack, hasLength(1));

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('追觅主页'), findsOneWidget);
    expect(container.read(selectedSeekingProvider).stack, isEmpty);
  });

  testWidgets('达到追觅双栏阈值后自动恢复且保留平行视界栈', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 800);
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedSeekingProvider.notifier)
      ..select(topicId: 1, instanceId: 'topic-1')
      ..pushProfile('alice');
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('追觅主页')),
        ),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => AutoRestoreMasterDetailRoute(
          masterWidth: 440,
          minDetailWidth: 480,
          child: _buildPaneStack(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('profile:alice'), findsOneWidget);

    tester.view.physicalSize = const Size(850, 800);
    await tester.pumpAndSettle();

    expect(find.text('profile:alice'), findsOneWidget);

    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();

    expect(find.text('追觅主页'), findsOneWidget);
    expect(container.read(selectedSeekingProvider).stack, hasLength(2));
  });
}

Widget _buildPaneStack() {
  return FullScreenPaneStack(
    stackProvider: selectedSeekingProvider,
    builder: (_, entry, onBack) => Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: onBack)),
      body: Text('${entry.kind.name}:${entry.username ?? entry.topicId}'),
    ),
  );
}
