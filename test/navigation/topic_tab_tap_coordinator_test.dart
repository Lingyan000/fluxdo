import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/navigation/nav_action_bus.dart';
import 'package:fluxdo/navigation/topic_tab_tap_coordinator.dart';

void main() {
  group('TopicTabTapCoordinator', () {
    testWidgets(
      'inactive first tap switches and second tap starts active single action',
      (tester) async {
        final actions = <NavAction>[];
        final coordinator = TopicTabTapCoordinator(initialActiveIndex: 0);
        addTearDown(coordinator.dispose);

        coordinator.handleTap(
          index: 1,
          singleAction: NavTapAction.scrollToTop,
          doubleAction: NavTapAction.refresh,
          dispatch: actions.add,
        );
        expect(actions, isEmpty);

        coordinator.handleTap(
          index: 1,
          singleAction: NavTapAction.scrollToTop,
          doubleAction: NavTapAction.refresh,
          dispatch: actions.add,
        );
        coordinator.syncActiveIndex(1);

        await tester.pump(const Duration(milliseconds: 299));
        expect(actions, isEmpty);
        await tester.pump(const Duration(milliseconds: 1));
        expect(actions, [NavAction.scrollToTop]);
      },
    );

    testWidgets('active double tap cancels pending single action', (
      tester,
    ) async {
      final actions = <NavAction>[];
      final coordinator = TopicTabTapCoordinator(initialActiveIndex: 0);
      addTearDown(coordinator.dispose);

      coordinator.handleTap(
        index: 0,
        singleAction: NavTapAction.scrollToTop,
        doubleAction: NavTapAction.refresh,
        dispatch: actions.add,
      );
      await tester.pump(const Duration(milliseconds: 100));
      coordinator.handleTap(
        index: 0,
        singleAction: NavTapAction.scrollToTop,
        doubleAction: NavTapAction.refresh,
        dispatch: actions.add,
      );

      expect(actions, [NavAction.refresh]);
      await tester.pump(const Duration(milliseconds: 300));
      expect(actions, [NavAction.refresh]);
    });

    testWidgets('single-only action dispatches immediately', (tester) async {
      final actions = <NavAction>[];
      final coordinator = TopicTabTapCoordinator(initialActiveIndex: 0);
      addTearDown(coordinator.dispose);

      coordinator.handleTap(
        index: 0,
        singleAction: NavTapAction.refresh,
        doubleAction: NavTapAction.none,
        dispatch: actions.add,
      );

      expect(actions, [NavAction.refresh]);
    });

    testWidgets('double-only action dispatches on the second active tap', (
      tester,
    ) async {
      final actions = <NavAction>[];
      final coordinator = TopicTabTapCoordinator(initialActiveIndex: 0);
      addTearDown(coordinator.dispose);

      coordinator.handleTap(
        index: 0,
        singleAction: NavTapAction.none,
        doubleAction: NavTapAction.refresh,
        dispatch: actions.add,
      );
      expect(actions, isEmpty);

      await tester.pump(const Duration(milliseconds: 100));
      coordinator.handleTap(
        index: 0,
        singleAction: NavTapAction.none,
        doubleAction: NavTapAction.refresh,
        dispatch: actions.add,
      );

      expect(actions, [NavAction.refresh]);
      await tester.pump(const Duration(milliseconds: 300));
      expect(actions, [NavAction.refresh]);
    });

    testWidgets('none actions never dispatch', (tester) async {
      final actions = <NavAction>[];
      final coordinator = TopicTabTapCoordinator(initialActiveIndex: 0);
      addTearDown(coordinator.dispose);

      coordinator.handleTap(
        index: 0,
        singleAction: NavTapAction.none,
        doubleAction: NavTapAction.none,
        dispatch: actions.add,
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(actions, isEmpty);
    });

    testWidgets('external tab switch cancels a pending single action', (
      tester,
    ) async {
      final actions = <NavAction>[];
      final coordinator = TopicTabTapCoordinator(initialActiveIndex: 0);
      addTearDown(coordinator.dispose);

      coordinator.handleTap(
        index: 0,
        singleAction: NavTapAction.scrollToTop,
        doubleAction: NavTapAction.refresh,
        dispatch: actions.add,
      );
      coordinator.syncActiveIndex(1);
      await tester.pump(const Duration(milliseconds: 300));

      expect(actions, isEmpty);
    });

    testWidgets('reset cancels pending action and replaces active index', (
      tester,
    ) async {
      final actions = <NavAction>[];
      final coordinator = TopicTabTapCoordinator(initialActiveIndex: 0);
      addTearDown(coordinator.dispose);

      coordinator.handleTap(
        index: 0,
        singleAction: NavTapAction.scrollToTop,
        doubleAction: NavTapAction.refresh,
        dispatch: actions.add,
      );
      coordinator.reset(activeIndex: 1);
      await tester.pump(const Duration(milliseconds: 300));
      expect(actions, isEmpty);

      coordinator.handleTap(
        index: 1,
        singleAction: NavTapAction.refresh,
        doubleAction: NavTapAction.none,
        dispatch: actions.add,
      );
      expect(actions, [NavAction.refresh]);

      actions.clear();
      coordinator.reset(activeIndex: 1);
      coordinator.handleTap(
        index: 0,
        singleAction: NavTapAction.refresh,
        doubleAction: NavTapAction.none,
        dispatch: actions.add,
      );
      expect(actions, isEmpty);
    });

    testWidgets('dispose cancels a pending single action', (tester) async {
      final actions = <NavAction>[];
      final coordinator = TopicTabTapCoordinator(initialActiveIndex: 0);

      coordinator.handleTap(
        index: 0,
        singleAction: NavTapAction.scrollToTop,
        doubleAction: NavTapAction.refresh,
        dispatch: actions.add,
      );
      coordinator.dispose();
      await tester.pump(const Duration(milliseconds: 300));

      expect(actions, isEmpty);
    });
  });
}
