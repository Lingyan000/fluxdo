import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/local_date_edit_dialog.dart';

void main() {
  testWidgets('日期编辑保留周期、显式 false、秒和范围终点', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    LocalDateRun? result;
    const initial = LocalDateRun(date: '2027-03-12', time: '10:20:30', fallbackText: '日期', recurring: '1.months', countdownRaw: 'false', endDate: '2027-03-15', endTime: '12:34:56');
    await tester.pumpWidget(ProviderScope(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)], child: MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(onPressed: () async { result = await showLocalDateEditDialog(context, initial: initial); }, child: const Text('打开')))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '2027-03-15'), '2027-03-16');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(result?.recurring, '1.months');
    expect(result?.countdownRaw, 'false');
    expect(result?.countdown, false);
    expect(result?.time, '10:20:30');
    expect(result?.endDate, '2027-03-16');
    expect(result?.endTime, '12:34:56');
    expect(result?.timezone, isNull);
  });
}
