import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/app_localizations.dart';
import 'package:fluxdo/models/translation_engine.dart';
import 'package:fluxdo/providers/ai_translation_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/translation_service.dart';
import 'package:fluxdo/widgets/ai/ai_translation_sheet.dart';

class _TranslationService extends TranslationService {
  _TranslationService() : super(dio: Dio());
  final streams = <StreamController<String>>[];
  final tokens = <CancelToken>[];
  final inputs = <String>[];

  @override
  Stream<String> translate({
    required TranslationEngine engine,
    required String text,
    required String targetCode,
    required String targetName,
    required CancelToken cancelToken,
  }) {
    final stream = StreamController<String>();
    streams.add(stream);
    tokens.add(cancelToken);
    inputs.add(text);
    return stream.stream;
  }
}

void main() {
  testWidgets('切换翻译服务取消旧请求，部分结果遇错后仍可复制和重试', (tester) async {
    SharedPreferences.setMockInitialValues({
      'pref_ai_translation_target_language': 'invalid',
    });
    final prefs = await SharedPreferences.getInstance();
    final service = _TranslationService();
    addTearDown(service.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          translationServiceProvider.overrideWithValue(service),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: TranslationSheetBody(text: '<原文>\nHello'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(service.inputs, ['<原文>\nHello']);
    service.streams[0].add('旧译文');
    await tester.pump();
    expect(find.text('旧译文'), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<TranslationEngine>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('哔哩哔哩（免费）').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.tokens.first.isCancelled, isTrue);
    service.streams[0].add('旧请求迟到结果');
    service.streams[1].add('新译文');
    await tester.pump();
    expect(find.text('新译文'), findsOneWidget);
    expect(find.textContaining('旧请求'), findsNothing);
    expect(prefs.getString('pref_translation_engine'), 'bilibili');
    service.streams[1].addError(
      const TranslationException(TranslationFailure.rateLimited),
    );
    await tester.pump();
    expect(find.text('新译文'), findsOneWidget);
    expect(find.textContaining('请求过于频繁'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(service.streams, hasLength(3));
    await tester.pumpWidget(const SizedBox());
    expect(service.tokens.last.isCancelled, isTrue);
    for (final stream in service.streams) {
      unawaited(stream.close());
    }
  });
}
