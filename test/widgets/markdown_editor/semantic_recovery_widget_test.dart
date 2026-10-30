import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/emoji.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/emoji_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/composer_import_pipeline.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_recovery_store.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/semantic_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double height = 760,
  double scale = 1,
  bool dark = false,
  bool desktop = false,
  bool disableAnimations = false,
}) async {
  PlatformUtils.debugDesktopOverride = desktop;
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  // 本文件手动回报 IME 帧；原生拖拽通道在专门的交接测试中覆盖。
  const keyboardChannel = MethodChannel('com.fluxdo/interactive_keyboard');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    keyboardChannel,
    (call) async => call.method == 'begin' ? {'supported': false} : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      keyboardChannel,
      null,
    ),
  );

  final prefs = await SharedPreferences.getInstance();
  await tester.runAsync(() async {
    if (!PreloadedDataService().isLoaded) {
      await PreloadedDataService().hydrateFromHtml(
        '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">${jsonEncode({
          'currentUser': {'id': 1, 'username': 'tester'},
          'siteSettings': {'min_post_length': 1, 'max_post_length': 10000},
          'site': {'categories': [], 'top_tags': []},
        })}</script>',
      );
      await DiscourseCookService().ensureInitialized();
    }
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWith(_RecoveryUser.new),
        emojiGroupsProvider.overrideWith(
          (ref) => Stream.value(<String, List<Emoji>>{}),
        ),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          navigatorKey: navigatorKey,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          theme: ThemeData(
            platform: desktop ? TargetPlatform.macOS : TargetPlatform.android,
            brightness: dark ? Brightness.dark : Brightness.light,
            colorSchemeSeed: const Color(0xff315fe7),
          ),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: Size(width, height),
                textScaler: TextScaler.linear(scale),
                disableAnimations: disableAnimations,
              ),
              child: RepaintBoundary(
                key: const ValueKey('capture-workbench'),
                child: Scaffold(
                  resizeToAvoidBottomInset: false,
                  appBar: AppBar(title: const Text('新话题')),
                  body: child,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _RecoveryUser extends CurrentUserNotifier {
  static int userId = 1;
  @override
  Future<User?> build() async =>
      User(id: userId, username: 'tester', trustLevel: 1);
}

class _Codec extends SemanticComposerCodec {
  bool fail = false;
  @override
  Future<ComposerImportResult<SemanticNode>> import(
    String raw, {
    Duration timeout = const Duration(seconds: 10),
    bool guarded = true,
  }) async => ComposerImportResult.success(
    SemanticNode(
      'doc',
      content: [
        SemanticNode('paragraph', content: [SemanticNode('text', text: raw)]),
      ],
    ),
  );
  @override
  String export(SemanticNode tree) {
    if (fail) throw StateError('模拟导出失败');
    return super.export(tree);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _RecoveryUser.userId = 1;
  });
  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  for (final action in [
    'restore',
    'discard',
    'wrongScope',
    'malformed',
    'exportFailure',
  ]) {
    testWidgets('紧急快照卸载重开：$action', (tester) async {
      final store = SemanticRecoveryStore();
      final codec = _Codec();
      final controller = TextEditingController(text: '旧正文');
      final key = GlobalKey<RichComposerEditorState>();
      await _pump(
        tester,
        RichComposerEditor(
          key: key,
          controller: controller,
          semanticCodec: codec,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final editor = tester
          .widget<FluxdoEditor>(find.byType(FluxdoEditor))
          .state;
      editor.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: editor.blocks.first.id, offset: 0),
        ),
      );
      editor.insertText('未同步');
      codec.fail = true;
      expect(key.currentState!.flushToController(), isFalse);
      expect(controller.text, '旧正文');
      await tester.pumpWidget(const SizedBox());
      final prefs = await SharedPreferences.getInstance();
      // 串行读是 dispose 异步保存完成的屏障。
      await store.read(const SemanticRecoveryScope(site: '屏障', userId: 1));
      expect(prefs.getStringList(SemanticRecoveryStore.storageKey), isNotEmpty);
      if (action == 'wrongScope') _RecoveryUser.userId = 2;
      if (action == 'malformed') {
        await prefs.setStringList(SemanticRecoveryStore.storageKey, ['{坏数据']);
      }
      final reopened = TextEditingController(text: '旧正文');
      final nextCodec = _Codec();
      await _pump(
        tester,
        RichComposerEditor(controller: reopened, semanticCodec: nextCodec),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (action == 'wrongScope' || action == 'malformed') {
        expect(find.byType(MaterialBanner), findsNothing);
      } else {
        expect(find.byType(MaterialBanner), findsOneWidget);
        expect(reopened.text, '旧正文');
        if (action == 'discard') {
          await tester.tap(find.text(S.current.common_discard));
        } else {
          await tester.tap(find.text(S.current.common_restore));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          expect(reopened.text, '旧正文');
          nextCodec.fail = action == 'exportFailure';
          await tester.tap(find.text(S.current.common_confirm));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        if (action == 'restore') expect(reopened.text, contains('未同步'));
        if (action == 'discard' || action == 'exportFailure')
          expect(reopened.text, '旧正文');
        expect(
          prefs.getStringList(SemanticRecoveryStore.storageKey),
          action == 'exportFailure' ? isNotEmpty : isEmpty,
        );
      }
      await tester.pumpWidget(const SizedBox());
      await store.read(const SemanticRecoveryScope(site: '屏障', userId: 1));
      controller.dispose();
      reopened.dispose();
    });
  }
}
