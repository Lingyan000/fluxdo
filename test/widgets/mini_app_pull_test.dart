import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  testWidgets('external reveal carries the physical release velocity', (
    tester,
  ) async {
    double velocity = 0;
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationListener<RefreshRevealNotification>(
            onNotification: (event) {
              if (event.armed && event.dragging) velocity = event.velocity;
              return true;
            },
            child: M3eRefreshIndicator(
              externalReveal: true,
              onRefresh: () async {},
              onSecondaryAction: () async {
                opened = true;
              },
              child: ListView(
                physics: const ClampingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                children: const [SizedBox(height: 1200)],
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(200, 100));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveBy(
        const Offset(0, 42),
        timeStamp: Duration(milliseconds: i * 16),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up(timeStamp: const Duration(milliseconds: 176));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(velocity, greaterThan(500));
  });

  for (final bouncing in [false, true]) {
    testWidgets(
      'two-stage pull: refresh, deep open, retract, cancel (${bouncing ? 'bounce' : 'clamp'})',
      (tester) async {
        var refreshes = 0, opens = 0;
        final key = GlobalKey<M3eRefreshIndicatorState>();
        final listKey = GlobalKey();
        final scroll = ScrollController();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: M3eRefreshIndicator(
                key: key,
                onRefresh: () async {
                  refreshes++;
                },
                onSecondaryAction: () async {
                  opens++;
                },
                secondaryActionBuilder: (_, progress, armed, refreshing) =>
                    Text(armed ? 'open' : 'refresh'),
                child: ListView.builder(
                  key: listKey,
                  controller: scroll,
                  physics: bouncing
                      ? const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        )
                      : const ClampingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                  itemCount: 100,
                  itemBuilder: (_, i) =>
                      SizedBox(height: 40, child: Text('$i')),
                ),
              ),
            ),
          ),
        );
        final original = listKey.currentContext;
        Future<void> pull(
          double distance, {
          double retract = 0,
          bool cancel = false,
        }) async {
          final gesture = await tester.startGesture(const Offset(300, 150));
          // First motion exceeds touch slop; subsequent steps are measured by the list.
          await gesture.moveBy(const Offset(0, 25));
          await tester.pump();
          for (var i = 0; i < 10; i++) {
            await gesture.moveBy(Offset(0, distance / 10));
            await tester.pump(const Duration(milliseconds: 30));
          }
          if (retract != 0) {
            await gesture.moveBy(Offset(0, -retract));
            await tester.pump();
          }
          if (cancel) {
            await gesture.cancel();
          } else {
            await gesture.up();
          }
          await tester.pumpAndSettle();
        }

        await pull(95);
        expect(refreshes, 1);
        expect(opens, 0);
        await pull(230);
        expect(refreshes, 1);
        expect(opens, 1);
        await pull(230, retract: 180);
        expect(
          opens,
          1,
          reason: 'retracting below threshold cancels the deep action',
        );
        final countBeforeCancel = refreshes;
        await pull(230, cancel: true);
        expect(refreshes, countBeforeCancel);
        expect(opens, 1);
        expect(listKey.currentContext, same(original));

        // Desktop shortcut/programmatic refresh always refreshes.
        final refresh = key.currentState!.show();
        await tester.pumpAndSettle();
        await refresh;
        expect(refreshes, countBeforeCancel + 1);
        expect(opens, 1);

        scroll.jumpTo(500);
        await tester.pump();
        await pull(100);
        expect(
          opens,
          1,
          reason: 'pulling while away from the top must not open apps',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
      },
    );
  }
}
