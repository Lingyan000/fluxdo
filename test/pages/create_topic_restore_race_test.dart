import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/pages/create_topic_page.dart';
import 'package:fluxdo/providers/discourse_providers.dart';
import 'package:fluxdo/providers/draft_store_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/editor/widget/editor_caret.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/memory_draft_store.dart';

// 可复现的时序压力测试：完整页面、真实草稿恢复弹窗与进入动画，
// 仅网络/平台通道受控。恢复移动端原先的聚焦时机，不靠取消聚焦过测。
void main() {
  const cases = int.fromEnvironment('RESTORE_RACE_CASES', defaultValue: 24);
  for (var seed = 0; seed < cases; seed++) {
    testWidgets('创建页媒体恢复时序 seed=$seed', (tester) async {
      final random = Random(seed);
      final restore = seed.isOdd;
      final width = [360.0, 400.0, 430.0][seed % 3];
      final height = [780.0, 870.0, 940.0][seed % 3];
      final keyboard = height * (0.34 + random.nextDouble() * 0.1);
      final focusDelay = random.nextInt(8);
      final imageDelay = random.nextInt(35);
      PlatformUtils.debugDesktopOverride = false;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, height);
      tester.view.padding = const FakeViewPadding(top: 47);
      tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 24);
      addTearDown(() {
        PlatformUtils.debugDesktopOverride = null;
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
        tester.view.resetPadding();
        tester.view.resetViewPadding();
        tester.view.resetViewInsets();
      });
      const channel = MethodChannel('com.fluxdo/interactive_keyboard');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'begin' ? {'supported': false} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      SharedPreferences.setMockInitialValues({
        'pref_use_rich_composer': true,
        'pref_composer_live_render': seed % 4 < 2,
      });
      final prefs = await SharedPreferences.getInstance();
      final raw = File('test/fixtures/composer_mixed_media_draft.md')
          .readAsStringSync()
          .replaceAll('upload://', 'upload://race${seed}');
      final pending = <(RequestOptions, RequestInterceptorHandler)>[];
      final mock = InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/uploads/lookup-urls') {
            pending.add((options, handler));
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              data: {
                'draft': restore && options.method == 'GET'
                    ? jsonEncode({
                        'title': '恢复混合媒体草稿',
                        'reply': raw,
                        'categoryId': 1,
                        'action': 'create_topic',
                      })
                    : null,
                'draft_sequence': 1,
                'success': 'OK',
              },
            ),
          );
        },
      );
      final service = DiscourseService();
      service.dio.interceptors.insert(0, mock);
      addTearDown(() => service.dio.interceptors.remove(mock));
      await tester.runAsync(() async {
        await PreloadedDataService().hydrateFromHtml(
          '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">${jsonEncode({
            'currentUser': {'id': 1, 'username': 'tester', 'can_tag_topics': true},
            'siteSettings': {'min_topic_title_length': 6, 'min_first_post_length': 20, 'max_post_length': 10000, 'tagging_enabled': true},
            'site': {'categories': [], 'top_tags': []},
          })}</script>',
        );
        await DiscourseCookService().ensureInitialized();
      });
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          localDraftStoreProvider.overrideWithValue(MemoryDraftStore()),
          categoriesProvider.overrideWith(
            (_) async => [
              Category.fromJson({
                'id': 1,
                'name': '开发调优',
                'color': '4b73e6',
                'permission': 1,
              }),
            ],
          ),
          tagsProvider.overrideWith((_) async => ['flutter']),
          canTagTopicsProvider.overrideWith((_) async => true),
        ],
      );
      final navigator = navigatorKey;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        container.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigator,
              locale: const Locale('zh'),
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocaleUtils.supportedLocales,
              scrollBehavior: const DesktopScrollInteractionBehavior(),
              theme: ThemeData(
                platform: TargetPlatform.android,
                pageTransitionsTheme: const PageTransitionsTheme(
                  builders: {
                    TargetPlatform.android:
                        PredictiveBackCupertinoPageTransitionsBuilder(),
                  },
                ),
              ),
              home: const Scaffold(body: SizedBox.expand()),
            ),
          ),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => RepaintBoundary(
            key: const ValueKey('race-page'),
            child: CreateTopicPage(
              initialCategoryId: 1,
              initialTitle: restore ? null : '恢复混合媒体草稿',
              initialContent: restore ? null : raw,
            ),
          ),
        ),
      );
      int? mountedFrame;
      int? focusedFrame;
      var restored = false;
      for (var frame = 0; frame < 180; frame++) {
        final restoreButton = find.widgetWithText(
          FilledButton,
          S.current.common_restore,
        );
        if (!restored && restoreButton.evaluate().isNotEmpty) {
          await tester.tap(restoreButton);
          restored = true;
        }
        final editorFinder = find.byType(FluxdoEditor);
        if (editorFinder.evaluate().isNotEmpty) {
          mountedFrame ??= frame;
          if (focusedFrame == null && frame >= mountedFrame + focusDelay) {
            tester.widget<FluxdoEditor>(editorFinder).focusNode!.requestFocus();
            focusedFrame = frame;
          }
        }
        if (focusedFrame != null) {
          final step = frame - focusedFrame;
          // 键盘逐帧升起，部分轮次模拟候选栏临时改高后回落。
          final extra = seed % 3 == 0 && step >= 15 && step < 23 ? 48.0 : 0.0;
          tester.view.viewInsets = FakeViewPadding(
            bottom: min(1.0, step / 12) * keyboard + extra,
          );
          if (step >= imageDelay && pending.isNotEmpty) {
            final (options, handler) = pending.removeAt(0);
            handler.resolve(
              Response(
                requestOptions: options,
                data: [
                  for (final url in options.data['short_urls'] as List)
                    if (random.nextInt(4) != 0)
                      {
                        'short_url': url,
                        'url': 'https://example.invalid/race.jpg',
                      },
                ],
              ),
            );
          }
        }
        await tester.pump(
          Duration(milliseconds: [8, 16, 32, 80][random.nextInt(4)]),
        );
        // cook 通过真实 isolate/平台桥异步返回，允许真实事件循环推进。
        if (mountedFrame == null && frame % 5 == 0) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
      }
      expect(focusedFrame, isNotNull, reason: '编辑器必须完成导入并聚焦');
      if (restore) expect(restored, isTrue);
      expect(pending, isEmpty);
      expect(tester.takeException(), isNull);
      final surface = tester.getRect(
        find.byKey(const ValueKey('composer-island-surface')),
      );
      final tail = tester.getRect(find.text('就反复', skipOffstage: false));
      final caret = tester.getRect(
        find.byType(EditorCaret, skipOffstage: false),
      );
      final visible = Rect.fromLTRB(0, 131, width, surface.top);
      final position = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!
          .position;
      if (const bool.fromEnvironment('RESTORE_RACE_TRACE')) {
        debugPrint(
          'RESTORE_RACE seed=$seed restore=$restore focus=$focusedFrame imageDelay=$imageDelay tail=$tail caret=$caret visible=$visible scroll=${position.pixels}/${position.maxScrollExtent}',
        );
      }

      // 验证实际像素：裁掉顶栏和底部工具，正文区域不能只有背景色。
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('race-page')),
      );
      final ink = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        var dark = 0;
        for (var y = visible.top.ceil(); y < visible.bottom.floor(); y++) {
          for (var x = 16; x < width.floor() - 16; x++) {
            final i = (y * image.width + x) * 4;
            if (bytes.getUint8(i) < 150 &&
                bytes.getUint8(i + 1) < 150 &&
                bytes.getUint8(i + 2) < 150)
              dark++;
          }
        }
        if (dark < 20 ||
            !tail.overlaps(visible) ||
            (const bool.fromEnvironment('RESTORE_RACE_CAPTURE') &&
                seed == 20)) {
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File('/tmp/fluxdo-restore-race-$seed.png')
              .writeAsBytes(png.buffer.asUint8List());
        }
        image.dispose();
        return dark;
      });
      expect(ink, greaterThan(20), reason: '正文坐标存在但实际画面空白 seed=$seed');
      expect(position.outOfRange, isFalse, reason: '自动定位结束后不能停在滚动范围外');
      expect(
        tail.overlaps(visible),
        isTrue,
        reason: '文末不能被滚出正文可见区 seed=$seed tail=$tail viewport=$visible',
      );
      expect(caret.overlaps(visible), isTrue);
    });
  }
}
