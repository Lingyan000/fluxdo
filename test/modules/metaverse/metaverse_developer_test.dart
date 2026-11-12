import 'dart:typed_data';

import 'package:flutter/material.dart';
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
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == 'select {}',
      ),
      findsOneWidget,
    );
  });
}
