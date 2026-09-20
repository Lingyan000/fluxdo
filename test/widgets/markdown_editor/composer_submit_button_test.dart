import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_submit_button.dart';

void main() {
  for (final compact in [false, true]) {
    testWidgets('紧凑按钮只缩小外观，保留48px点击范围 compact=$compact', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ComposerSubmitButton(
                label: '发送',
                compact: compact,
                busy: false,
                onPressed: () => calls++,
              ),
            ),
          ),
        ),
      );
      final button = find.byType(ComposerSubmitButton);
      expect(tester.getSize(button), const Size.square(48));
      expect(
        tester.getSize(
          find.descendant(of: button, matching: find.byType(Material)),
        ),
        Size.square(compact ? 36 : 40),
      );
      // 圆形表面外、触控区域内仍可点击，不能用透明但不可点击的外框补齐尺寸。
      await tester.tapAt(tester.getCenter(button) + const Offset(22, 0));
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final reduced in [false, true]) {
    testWidgets('发送起飞不阻塞提交，失败恢复后可重试 reduced=$reduced', (tester) async {
      var busy = false;
      var calls = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reduced),
                child: Scaffold(
                  body: Center(
                    child: ComposerSubmitButton(
                      label: '发送',
                      busy: busy,
                      onPressed: () => setState(() {
                        calls++;
                        busy = true;
                      }),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      final button = find.byKey(const ValueKey('composer-header-submit'));
      final bounds = tester.getRect(button);
      final flight = find.byKey(const ValueKey('composer-submit-flight'));
      expect(
        tester.getSize(
          find.descendant(of: button, matching: find.byType(Material)),
        ),
        const Size.square(40),
      );
      await tester.tap(button);
      expect(calls, 1, reason: '请求立即开始，不等待起飞动画');
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(tester.getRect(button), bounds);
      if (reduced) {
        expect(flight, findsNothing);
      } else {
        final glyph = find.byWidgetPredicate(
          (w) => w is AppIcon && w.icon == AppIcons.paperPlane,
        );
        final start = tester.getRect(glyph);
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getRect(glyph).left, greaterThan(start.left));
        expect(tester.getRect(glyph).top, lessThan(start.top));
      }
      await tester.tap(button);
      expect(calls, 1);
      await tester.pump(const Duration(milliseconds: 300));
      expect(flight, findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      update(() => busy = false);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is AppIcon && w.icon == AppIcons.paperPlane,
        ),
        findsOneWidget,
      );
      expect(tester.getRect(button), bounds);
      await tester.tap(button);
      await tester.pump();
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('附件上传等待不播放发送起飞', (tester) async {
    late StateSetter update;
    var busy = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return ComposerSubmitButton(
              label: '发送',
              onPressed: () {},
              busy: busy,
              animateFlight: false,
            );
          },
        ),
      ),
    );
    update(() => busy = true);
    await tester.pump();
    expect(find.byKey(const ValueKey('composer-submit-flight')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('没有进入提交状态时不播放起飞', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ComposerSubmitButton(
              label: '发送',
              busy: false,
              onPressed: () => calls++,
            ),
          ),
        ),
      ),
    );
    final flight = find.byKey(const ValueKey('composer-submit-flight'));
    final before = tester.getRect(flight);
    await tester.tap(find.byType(FilledButton));
    await tester.pump(const Duration(milliseconds: 140));
    expect(calls, 1);
    expect(tester.getRect(flight), before);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
