import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/topic_list/filter_provider.dart';
import 'package:fluxdo/widgets/topic/topic_list_update_banner.dart';

void main() {
  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    for (final brightness in Brightness.values) {
      testWidgets('更新横幅 $size $brightness 保持原有加载态，禁止重复点击', (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var taps = 0;
        Future<void> pump(bool loading) => tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: Colors.blue,
                  brightness: brightness,
                ),
              ),
              home: MediaQuery(
                data: MediaQueryData(size: size, disableAnimations: true),
                child: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.all(12),
                    child: ListView(
                      children: [
                        TopicListUpdateBanner(
                          count: 123,
                          filter: TopicListFilter.newTopics,
                          newNewView: true,
                          loading: loading,
                          onTap: () => taps++,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await pump(false);
        expect(tester.takeException(), isNull);
        final rect = tester.getRect(find.byType(TopicListUpdateBanner));
        expect(rect.width, lessThanOrEqualTo(size.width));
        await tester.tap(find.byType(TopicListUpdateBanner));
        expect(taps, 1);
        await pump(true);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(TopicListUpdateBanner),
            matching: find.byType(Text),
          ),
          findsNothing,
        );
        await tester.tap(find.byType(TopicListUpdateBanner));
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
