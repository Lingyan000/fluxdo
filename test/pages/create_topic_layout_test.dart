import 'dart:convert';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/pages/create_topic_page.dart';
import 'package:fluxdo/providers/discourse_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_page_chrome.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_view_mode_switcher.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_workbench.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:fluxdo/widgets/topic/topic_editor_helpers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo_render/editor.dart' show FluxdoEditor;

void main() {
  for (final variant in [
    (true, 1100.0, false),
    (true, 700.0, false),
    (false, 390.0, false),
    (false, 320.0, false),
    (true, 1100.0, true),
  ]) {
    final (desktop, width, empty) = variant;
    testWidgets(
      '完整创建页 ${desktop ? "PC" : "手机"} $width${empty ? ' 空正文' : ''}：直接操作、类型切换和属性分区',
      (tester) async {
        PlatformUtils.debugDesktopOverride = desktop;
        addTearDown(() => PlatformUtils.debugDesktopOverride = null);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 760);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        SharedPreferences.setMockInitialValues({
          'pref_use_rich_composer': true,
          'pref_ai_post_review_enabled': true,
        });
        final prefs = await SharedPreferences.getInstance();
        final categories = [
          Category.fromJson({
            'id': 1,
            'name': '开发',
            'color': '4b73e6',
            'permission': 1,
            'create_as_post_voting_default': false,
          }),
        ];
        final service = DiscourseService();
        final mock = InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                data: {'draft': null, 'draft_sequence': 0, 'success': 'OK'},
              ),
            );
          },
        );
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
            categoriesProvider.overrideWith((_) async => categories),
            tagsProvider.overrideWith((_) async => ['flutter', '体验']),
            canTagTopicsProvider.overrideWith((_) async => true),
          ],
        );
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
                navigatorKey: navigatorKey,
                builder: (context, child) => RepaintBoundary(
                  key: const ValueKey('app-menu-capture'),
                  child: child!,
                ),
                locale: const Locale('zh'),
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                supportedLocales: AppLocaleUtils.supportedLocales,
                theme: ThemeData(
                  inputDecorationTheme: const InputDecorationTheme(
                    contentPadding: EdgeInsets.symmetric(horizontal: 12),
                  ),
                  brightness: desktop ? Brightness.dark : Brightness.light,
                  platform: desktop
                      ? TargetPlatform.macOS
                      : TargetPlatform.android,
                  colorSchemeSeed: const Color(0xff4b73e6),
                ),
                // 从首页进入创建页，让 AppBar 自行生成返回按钮。
                initialRoute: '/create',
                routes: {
                  '/': (_) => const SizedBox.shrink(),
                  '/create': (_) => RepaintBoundary(
                    key: const ValueKey('create-page-capture'),
                    child: CreateTopicPage(
                      initialCategoryId: 1,
                      initialTags: ['flutter', '体验'],
                      initialTitle: empty ? '123123' : '分享最近的开发体验',
                      initialContent: empty
                          ? ''
                          : '最近重新整理了写作环境。\n\n常用工具应该留在手边，需要的时候能直接找到。\n\n大家平时更习惯怎样的编辑器？',
                    ),
                  ),
                },
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        for (
          var i = 0;
          i < 40 && find.byType(GlassSurfaceFrame).evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }

        expect(tester.takeException(), isNull);
        final appbar = find.byType(AppBar);
        final toolbar = tester.widget<NavigationToolbar>(
          find.descendant(of: appbar, matching: find.byType(NavigationToolbar)),
        );
        expect(toolbar.middleSpacing, NavigationToolbar.kMiddleSpacing);
        expect(
          find.descendant(of: appbar, matching: find.byType(BackButton)),
          findsOneWidget,
        );
        expect(tester.getSize(find.byWidget(toolbar.leading!)).width, 56);
        expect(
          find.descendant(
            of: appbar,
            matching: find.byType(ComposerDiscardButton),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: appbar,
            matching: find.byIcon(Symbols.more_horiz_rounded),
          ),
          findsNothing,
        );
        expect(find.byTooltip(S.current.aiPostReview_button), findsOneWidget);
        expect(find.byType(ComposerTopicKindPicker), findsOneWidget);
        expect(
          find.descendant(of: appbar, matching: find.byType(ComposerMetaBar)),
          desktop ? findsOneWidget : findsNothing,
        );
        expect(find.byType(ComposerDesktopMetadata), findsNothing);
        expect(find.byType(GlassSurfaceFrame), findsOneWidget);
        final initialScroll = tester
            .widget<CustomScrollView>(
              find
                  .descendant(
                    of: find.byType(RichComposerEditor),
                    matching: find.byType(CustomScrollView),
                  )
                  .first,
            )
            .controller!;
        expect(
          initialScroll.position.maxScrollExtent,
          closeTo(0, .01),
          reason: '空白和短正文不应被最小高度或底部留白撑出滚动',
        );
        final titleEditable = tester
            .state<EditableTextState>(
              find.descendant(
                of: find.byType(TextFormField),
                matching: find.byType(EditableText),
              ),
            )
            .renderEditable;
        final richParagraph = tester.renderObject<RenderParagraph>(
          empty
              ? find.byKey(const ValueKey('rich-composer-placeholder'))
              : find
                    .descendant(
                      of: find.byType(FluxdoEditor),
                      matching: find.byWidgetPredicate(
                        (w) =>
                            w is RichText &&
                            w.text.toPlainText().contains('最近重新整理'),
                      ),
                    )
                    .first,
        );
        expect(
          titleEditable.localToGlobal(Offset.zero).dx,
          closeTo(richParagraph.localToGlobal(Offset.zero).dx, .1),
        );
        expect(
          titleEditable.localToGlobal(Offset(titleEditable.size.width, 0)).dx,
          closeTo(
            richParagraph
                .localToGlobal(Offset(richParagraph.constraints.maxWidth, 0))
                .dx,
            .1,
          ),
        );

        expect(
          find.descendant(
            of: find.byType(ComposerModeButton),
            matching: find.byType(Text),
          ),
          findsNothing,
        );
        final trigger = find.byKey(const ValueKey('composer-kind-trigger'));
        final triggerButton = find
            .ancestor(of: trigger, matching: find.byType(InkWell))
            .first;
        final titleLabel = find.byKey(const ValueKey('composer-title-label'));
        expect(
          tester.widget<Text>(titleLabel).semanticsLabel,
          S.current.composer_kindTopic,
        );
        expect(find.text(S.current.composer_kindQuestion), findsNothing);
        final kindLabel = tester.renderObject<RenderParagraph>(
          find
              .descendant(of: titleLabel, matching: find.byType(RichText))
              .first,
        );
        expect(
          kindLabel.text.style?.fontSize,
          greaterThanOrEqualTo(18),
          reason: '创建类型应保持页面标题的层级',
        );
        // 极窄屏沿用 AppBar 的标题省略，不再压缩默认间距。
        if (width >= 390) {
          expect(kindLabel.didExceedMaxLines, isFalse);
        }
        expect(
          kindLabel.getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
          ),
          isNotEmpty,
          reason: '极窄屏也应优先显示标题文字',
        );
        final triggerRect = tester.getRect(trigger);

        await tester.tap(triggerButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        for (final value in [false, true]) {
          expect(
            tester
                .getRect(find.byKey(ValueKey('composer-kind-option-$value')))
                .top,
            greaterThanOrEqualTo(triggerRect.bottom + 6),
          );
        }
        await tester.tap(
          find.byKey(const ValueKey('composer-kind-option-true')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester
              .widget<ComposerTopicKindPicker>(
                find.byType(ComposerTopicKindPicker),
              )
              .question,
          isTrue,
        );
        // 第二项选中时再次打开，也不能把菜单居中盖到当前入口上。
        await tester.tap(triggerButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester
              .getRect(find.byKey(const ValueKey('composer-kind-option-false')))
              .top,
          greaterThanOrEqualTo(tester.getRect(trigger).bottom + 6),
        );

        await tester.tapAt(Offset(width - 4, 260));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          find.byKey(const ValueKey('composer-kind-option-true')),
          findsNothing,
        );

        await tester.tap(find.byType(ComposerModeButton));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(MarkdownEditor), findsOneWidget);
        final sourceScroll = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView).first)
            .controller!;
        expect(
          sourceScroll.position.maxScrollExtent,
          closeTo(0, .01),
          reason: '源码模式也不应为底部避让额外增加一段滚动',
        );
        final sourceTitle = tester
            .state<EditableTextState>(
              find.descendant(
                of: find.byType(TextFormField),
                matching: find.byType(EditableText),
              ),
            )
            .renderEditable;
        final sourceField = find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.hintText == S.current.createTopic_contentHint,
        );
        final sourceBody = tester
            .state<EditableTextState>(
              find.descendant(
                of: sourceField,
                matching: find.byType(EditableText),
              ),
            )
            .renderEditable;
        expect(
          sourceTitle.localToGlobal(Offset.zero).dx,
          closeTo(sourceBody.localToGlobal(Offset.zero).dx, .1),
        );
        expect(
          sourceTitle.localToGlobal(Offset(sourceTitle.size.width, 0)).dx,
          closeTo(
            sourceBody.localToGlobal(Offset(sourceBody.size.width, 0)).dx,
            .1,
          ),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }
}
