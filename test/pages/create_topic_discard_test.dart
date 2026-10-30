import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/pages/create_topic_page.dart';
import 'package:fluxdo/providers/discourse_providers.dart';
import 'package:fluxdo/providers/draft_store_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/memory_draft_store.dart';

void main() {
  for (final saved in [false, true]) {
    testWidgets('顶栏舍弃后迟到的正文更新不能复活草稿 saved=$saved', (tester) async {
      PlatformUtils.debugDesktopOverride = false;
      addTearDown(() => PlatformUtils.debugDesktopOverride = null);
      SharedPreferences.setMockInitialValues({'pref_use_rich_composer': false});
      FlutterSecureStorage.setMockInitialValues({
        'linux_do_username': 'tester',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryDraftStore();
      DraftData? remote;
      var sequence = 0;
      var writes = 0;
      var deletes = 0;
      Completer<void>? deletionStarted;
      Completer<void>? releaseDeletion;
      final interceptor = InterceptorsWrapper(
        onRequest: (request, handler) async {
          if (request.method == 'GET' &&
              request.path.startsWith('/drafts/') &&
              deletionStarted != null &&
              !deletionStarted.isCompleted) {
            deletionStarted.complete();
            await releaseDeletion!.future;
          }
          if (request.method == 'POST' && request.path == '/drafts.json') {
            writes++;
            remote = DraftData.fromJson(
              jsonDecode((request.data as Map)['data'] as String)
                  as Map<String, dynamic>,
            );
            sequence++;
          }
          if (request.method == 'DELETE') {
            deletes++;
            remote = null;
          }
          handler.resolve(
            Response(
              requestOptions: request,
              data: {
                'success': 'OK',
                'draft': remote?.toJsonString(),
                'draft_sequence': sequence,
              },
            ),
          );
        },
      );
      final service = DiscourseService();
      service.dio.interceptors.insert(0, interceptor);
      addTearDown(() => service.dio.interceptors.remove(interceptor));
      await tester.runAsync(() async {
        await PreloadedDataService().hydrateFromHtml(
          '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">${jsonEncode({
            'currentUser': {'id': 1, 'username': 'tester'},
            'siteSettings': {'min_topic_title_length': 6, 'min_first_post_length': 20},
            'site': {'categories': []},
          })}</script>',
        );
      });
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          localDraftStoreProvider.overrideWithValue(store),
          categoriesProvider.overrideWith((_) async => []),
          tagsProvider.overrideWith((_) async => []),
          canTagTopicsProvider.overrideWith((_) async => false),
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
              locale: const Locale('zh'),
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocaleUtils.supportedLocales,
              home: const Scaffold(body: Text('测试首页')),
            ),
          ),
        ),
      );
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const CreateTopicPage(
            initialTitle: '等待舍弃的标题',
            initialContent: '等待舍弃的正文',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      if (saved) {
        await tester.pump(const Duration(seconds: 3));
        expect(remote?.reply, '等待舍弃的正文');
        await tester.tap(find.byKey(const ValueKey('composer-header-more')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('composer-header-discard')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(TextButton, S.current.common_cancel),
        );
        await tester.pumpAndSettle();
        final editor = tester.widget<MarkdownEditor>(
          find.byType(MarkdownEditor),
        );
        editor.controller.text = '取消舍弃后继续编辑的正文';
        await tester.pump(const Duration(seconds: 3));
        expect(remote?.reply, editor.controller.text);
        expect(deletes, 0, reason: '取消舍弃仍能正常编辑和自动保存');
      }
      final previousWrites = writes;
      deletionStarted = Completer<void>();
      releaseDeletion = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('composer-header-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('composer-header-discard')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, S.current.common_discard),
      );
      await tester.pumpAndSettle();
      expect(deletionStarted.isCompleted, isTrue);

      // 模拟富文本延迟镜像或失焦回调在删除请求期间更新正文。
      tester
              .widget<MarkdownEditor>(find.byType(MarkdownEditor))
              .controller
              .text =
          '舍弃后迟到的正文';
      releaseDeletion.complete();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('测试首页'), findsOneWidget);
      expect(writes, previousWrites);
      expect(deletes, 1);
      expect(remote, isNull);
      expect(store.entry, isNull);

      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const CreateTopicPage()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester
            .widget<MarkdownEditor>(find.byType(MarkdownEditor))
            .controller
            .text,
        isEmpty,
      );
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    });
  }
}
