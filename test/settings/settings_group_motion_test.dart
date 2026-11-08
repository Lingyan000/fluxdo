import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/settings/settings_model.dart';
import 'package:fluxdo/widgets/settings/settings_group_page.dart';
import 'package:m3e_ui/m3e_ui.dart';

class _Enabled extends Notifier<bool> {
  @override
  bool build() => true;
  void toggle() => state = !state;
}

final _enabled = NotifierProvider<_Enabled, bool>(_Enabled.new);

void main() {
  testWidgets('真实设置页关联项平滑收起，立即禁用交互，圆角/间距最终正确', (tester) async {
    var childCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: SettingsGroupPage(
            title: 'settings',
            groupsBuilder: (_) => [
              SettingsGroup(
                title: 'group',
                icon: Icons.settings,
                items: [
                  SwitchModel(
                    id: 'main',
                    title: 'main',
                    icon: Icons.toggle_on,
                    getValue: (ref) => ref.watch(_enabled),
                    onChanged: (ref, _) => ref.read(_enabled.notifier).toggle(),
                  ),
                  SwitchModel(
                    id: 'child',
                    title: 'child',
                    icon: Icons.auto_fix_high,
                    enabledWhen: (ref) => ref.watch(_enabled),
                    getValue: (_) => true,
                    onChanged: (_, _) => childCalls++,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    final fullHeight = tester.getSize(find.byType(SegmentedCardGroup)).height;
    await tester.tap(find.text('main'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final middleHeight = tester.getSize(find.byType(SegmentedCardGroup)).height;
    expect(middleHeight, lessThan(fullHeight));
    expect(find.text('child'), findsOneWidget, reason: '退场期间保留内容');
    await tester.tap(find.text('child'), warnIfMissed: false);
    expect(childCalls, 0);
    await tester.pumpAndSettle();
    expect(find.text('child'), findsNothing);
    expect(
      tester.getSize(find.byType(SegmentedCardGroup)).height,
      lessThan(middleHeight),
    );
    final card = tester.widget<SegmentedCardItem>(
      find.byType(SegmentedCardItem),
    );
    expect(card.index, 0);
    expect(card.count, 1);
    await tester.tap(find.text('main'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(SegmentedCardGroup)).height, fullHeight);
    expect(tester.takeException(), isNull);
  });
}
