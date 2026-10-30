import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/topic_detail_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_renderer.dart';
import 'package:fluxdo/widgets/topic/topic_summary_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

TopicSummary _summary(String text, {bool streaming = true}) => TopicSummary(
  summarizedText: text,
  outdated: false,
  canRegenerate: false,
  newPostsSinceSummary: 0,
  isStreaming: streaming,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('首次展开只订阅一次，收起再展开继续显示已有摘要', (tester) async {
    await _prepareMarkdown(tester);
    final updates = StreamController<TopicSummary?>();
    var requests = 0;
    await tester.pumpWidget(
      ProviderScope(
        retry: (_, _) => null,
        overrides: [
          topicSummaryProvider(42).overrideWith((ref) {
            requests++;
            return updates.stream;
          }),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: CollapsibleTopicSummary(topicId: 42)),
          ),
        ),
      ),
    );
    expect(requests, 0);
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    expect(requests, 1);
    updates.add(_summary('First summary'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    updates.add(_summary('First summary complete', streaming: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byType(InkWell).first);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byType(InkWell).first);
    await tester.pump(const Duration(milliseconds: 350));
    expect(requests, 1);
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
      'First summary complete',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(updates.close());
  });

  testWidgets('流式分片回退或修订前缀时保留显示进度，最终结果仍以服务端为准', (tester) async {
    await _prepareMarkdown(tester);
    Future<void> show(String text, {bool streaming = true, int topicId = 42}) =>
        tester.pumpWidget(
          ProviderScope(
            child: TranslationProvider(
              child: MaterialApp(
                navigatorKey: navigatorKey,
                home: Scaffold(
                  body: TopicSummaryWidget(
                    topicId: topicId,
                    summaryAsyncOverride: AsyncData(
                      _summary(text, streaming: streaming),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
    String displayed() => tester
        .widget<MarkdownBody>(find.byType(MarkdownBody))
        .data
        .replaceAll(' ▍', '');

    await show('First summary in progress');
    await tester.pump(const Duration(milliseconds: 150));
    final progress = displayed();
    expect(progress.length, greaterThan(5));

    // 重连重放的较短累计分片不能清空已显示文本。
    await show('First');
    expect(displayed(), progress);
    await tester.pump(const Duration(milliseconds: 30));
    expect(displayed().length, greaterThanOrEqualTo(progress.length));

    // 即使新分片修订了前缀，也沿用已显示字符数，不重新从空串打字。
    final length = displayed().length;
    await show('Revised summary in progress with more text');
    expect(
      displayed(),
      'Revised summary in progress with more text'.substring(0, length),
    );

    await show('Final', streaming: false);
    expect(displayed(), 'Final');
    await show('Another generation');
    expect(displayed(), isEmpty);
    await tester.pump(const Duration(milliseconds: 30));
    expect(displayed(), 'An');
    await show('Other topic', topicId: 43);
    expect(displayed(), isEmpty);
    await tester.pump(const Duration(milliseconds: 30));
    expect(displayed(), 'Ot');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _prepareMarkdown(WidgetTester tester) => tester.runAsync(() async {
  await PreloadedDataService().hydrateFromHtml(
    '<meta id="data-discourse-setup"><script id="data-preloaded" '
    'type="application/json">${jsonEncode({
      'currentUser': {'id': 1, 'username': 'tester'},
      'siteSettings': <String, dynamic>{},
      'site': {'categories': [], 'top_tags': []},
    })}</script>',
  );
  await DiscourseCookService().ensureInitialized();
});
