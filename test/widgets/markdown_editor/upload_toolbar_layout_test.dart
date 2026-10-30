import 'dart:async';

import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart';
import 'package:fluxdo/widgets/markdown_editor/uploads/upload_task_panel.dart';
import 'package:fluxdo/widgets/markdown_editor/uploads/task_controller.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_toolbar.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_desktop_layout.dart';

import 'composer_interaction_test.dart' show pumpApp;

void main() {
  for (final width in [320.0, 1000.0]) {
    testWidgets('源码任务面板单层玻璃且无清扫图标 width=$width', (tester) async {
      final controller = UploadTaskController();
      addTearDown(controller.dispose);
      final completer = Completer<UploadResult>();
      controller.add(
        UploadTaskRequest(
          path: '/unused/file.txt',
          name: '很长的文件名' * 20,
          execute: (_, _) => completer.future,
        ),
      );
      await pumpApp(
        tester,
        Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              child: SourceUploadPanel(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(GlassSurfaceFrame), findsOneWidget);
      expect(find.byType(Card), findsNothing);
      expect(find.byIcon(Icons.cleaning_services_outlined), findsNothing);
      final surface = find.byKey(const ValueKey('source-upload-glass'));
      expect(tester.getSize(surface).width, lessThanOrEqualTo(520));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
      await tester.pump();
      expect(tester.getSize(surface).height, lessThan(70));
      completer.complete(
        UploadResult(shortUrl: 'upload://done', originalFilename: 'file.txt'),
      );
      await tester.pumpAndSettle();
      expect(surface, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final width in [600.0, 1200.0]) {
    testWidgets('桌面上传工具栏维持有限高度 width=$width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = TextEditingController();
      await pumpApp(
        tester,
        Scaffold(
          body: ComposerDesktopViewport(
            size: Size(width, 800),
            topInset: 0,
            child: SizedBox.expand(
              child: MarkdownToolbar(
                controller: controller,
                visibleToolIds: const ['image'],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final workbench = find.byKey(
        const ValueKey('composer-desktop-workbench'),
      );
      expect(tester.getSize(workbench).height, 800);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }
}
