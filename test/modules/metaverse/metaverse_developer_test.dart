import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/modules/metaverse/developer/metaverse_component_examples.dart';
import 'package:fluxdo/modules/metaverse/developer/metaverse_developer_page.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'package:rfw/formats.dart';

void main() {
  testWidgets('每个文档示例引用已注册原生组件并可在窄屏渲染', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      ),
    );
    final examples = metaverseComponentExamples(S.current);
    final library = createMetaverseWidgetLibrary(
      loadImage: (_) async => Uint8List(0),
    );
    expect(examples.map((e) => e.name).toSet(), metaverseHostWidgetNames);
    for (final example in examples) {
      expect(
        library.widgets.containsKey(example.name),
        isTrue,
        reason: example.name,
      );
      expect(
        parseLibraryFile('import fluxdo; widget Preview = ${example.source};'),
        isA<RemoteWidgetLibrary>(),
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: MetaverseComponentPreviewPage(
              key: ValueKey(example.name),
              example: example,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull, reason: example.name);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('预览开关回传事件并更新真实组件状态', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      ),
    );
    final example = metaverseComponentExamples(S.current)
        .firstWhere((e) => e.name == 'Choice');
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: MetaverseComponentPreviewPage(example: example),
        ),
      ),
    );
    await tester.tap(find.byType(ChoiceChip));
    await tester.pump();
    expect(tester.widget<ChoiceChip>(find.byType(ChoiceChip)).selected, isTrue);
    final recorded = find.byWidgetPredicate(
      (widget) => widget is SelectableText && widget.data == 'select {}',
    );
    await tester.scrollUntilVisible(recorded, 250, scrollable: find.byType(Scrollable).first);
    expect(recorded, findsOneWidget);
  });

  testWidgets('时间线示例可切换短内容对齐并恢复默认位置', (tester) async {
    tester.view.physicalSize = const Size(360, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      ),
    );
    final example = metaverseComponentExamples(S.current)
        .firstWhere((e) => e.name == 'TimelinePage');
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: MetaverseComponentPreviewPage(example: example),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final viewport = find.byWidgetPredicate(
      (widget) => widget is CustomScrollView,
    );
    final message = find.descendant(
      of: viewport,
      matching: find.text(example.parameters['message']! as String),
    );
    double messageOffset() =>
        tester.getTopLeft(message).dy - tester.getTopLeft(viewport).dy;
    final endOffset = messageOffset();
    final start = find.widgetWithText(ChoiceChip, 'start');
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(start).selected, isTrue);
    expect(messageOffset(), lessThan(endOffset));
    expect(
      tester
              .getTopLeft(find.descendant(
                of: viewport,
                matching: find.byType(TextButton),
              ))
              .dy -
          tester.getTopLeft(viewport).dy,
      closeTo(16, 1),
    );
    await tester.tap(find.byTooltip(S.current.metaverse_developerReset));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'end')).selected,
      isTrue,
    );
    expect(messageOffset(), closeTo(endOffset, 1));
    expect(tester.takeException(), isNull);
  });
}
