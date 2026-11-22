import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:ai_model_manager/widgets/model_detail_sheet.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('模型表单在键盘上方保存新模型，取消编辑不修改原模型', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 740);
    addTearDown(tester.view.reset);

    AiModel? saved;
    AiModel? lastResult;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  final model = saved;
                  lastResult = model == null
                      ? await showCreateModelSheet(context)
                      : await showModelDetailSheet(context, model: model);
                  saved = lastResult ?? saved;
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    final fields = find.descendant(
      of: find.byType(AppSheetScaffold),
      matching: find.byType(TextField),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(AppSheetScaffold), findsOneWidget);
    await tester.enterText(fields.first, 'test-model');
    expect(
        tester.widget<TextField>(fields.last).controller!.text, 'test-model');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    final save = find.text(AiL10n.current.modelDetailAddTitle).last;
    expect(tester.getBottomLeft(save).dy, lessThan(740 - 280));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved?.id, 'test-model');

    tester.view.resetViewInsets();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(fields.first).readOnly, isTrue);
    await tester.enterText(fields.last, '未保存的修改');
    final shellContext = tester.element(find.byType(AppSheetScaffold));
    await tester.tap(find.byTooltip(
        MaterialLocalizations.of(shellContext).modalBarrierDismissLabel));
    await tester.pumpAndSettle();
    expect(lastResult, isNull);
    expect(saved?.name, 'test-model');
    expect(find.byType(AppSheetScaffold), findsNothing);
  });
}
