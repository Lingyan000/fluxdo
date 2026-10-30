/// ComposerMetaBar 底部属性条:pills 渲染形态与禁用态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/topic/topic_editor_helpers.dart';
import 'package:fluxdo/utils/platform_utils.dart';

Widget _wrap(Widget child) {
  return TranslationProvider(
    child: MaterialApp(
      locale: const Locale('zh'),
      navigatorKey: navigatorKey,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocaleUtils.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

Category _cat({int minTags = 0}) => Category.fromJson({
  'id': 1,
  'name': '沙盒',
  'color': '22c55e',
  'minimum_required_tags': minTags,
});

void main() {
  for (final width in [152.0, 280.0]) {
    testWidgets('手机胶囊适配剩余宽度，标签完整值可查看 width=$width', (tester) async {
      PlatformUtils.debugDesktopOverride = false;
      addTearDown(() => PlatformUtils.debugDesktopOverride = null);
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: width,
            child: ComposerMetaBar(
              category: _cat(),
              categories: [_cat()],
              onCategorySelected: (_) {},
              selectedTags: const ['flutter', 'design', '体验'],
              allTags: const [],
              onTagsChanged: (_) {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final category = find.byKey(const ValueKey('composer-category-chip'));
      final tags = find.byKey(const ValueKey('composer-tags-chip'));
      expect(tester.getSize(category).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(tags).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(tags).width, greaterThanOrEqualTo(48));
      expect(tester.getRect(tags).left - tester.getRect(category).right, 6);
      expect(
        find.byTooltip('${S.current.tag_tabTags}: #flutter #design #体验'),
        findsOneWidget,
      );
      expect(find.text(width < 200 ? '3' : 'flutter'), findsOneWidget);
      if (width > 200) expect(find.text('+2'), findsOneWidget);
    });
  }

  testWidgets('未选分类:引导文案;已选:名字+色点', (tester) async {
    var bar = ComposerMetaBar(
      category: null,
      categories: const [],
      onCategorySelected: (_) {},
      selectedTags: const [],
      allTags: const [],
      onTagsChanged: (_) {},
    );
    await tester.pumpWidget(_wrap(bar));
    expect(find.text(S.current.topic_selectCategory), findsOneWidget);

    bar = ComposerMetaBar(
      category: _cat(),
      categories: const [],
      onCategorySelected: (_) {},
      selectedTags: const [],
      allTags: const [],
      onTagsChanged: (_) {},
    );
    await tester.pumpWidget(_wrap(bar));
    expect(find.text('沙盒'), findsOneWidget);
  });

  testWidgets('标签 pill:空显示添加入口,多标签收纳 +N', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ComposerMetaBar(
          category: _cat(),
          categories: const [],
          onCategorySelected: (_) {},
          selectedTags: const [],
          allTags: const ['a'],
          onTagsChanged: (_) {},
        ),
      ),
    );
    expect(find.text(S.current.topic_addTags), findsOneWidget);

    await tester.pumpWidget(
      _wrap(
        ComposerMetaBar(
          category: _cat(),
          categories: const [],
          onCategorySelected: (_) {},
          selectedTags: const ['aa', 'bb', 'cc'],
          allTags: const ['aa', 'bb', 'cc'],
          onTagsChanged: (_) {},
        ),
      ),
    );
    expect(find.text('#aa #bb +1'), findsOneWidget);
  });

  testWidgets('必选标签未满足:pill 呈 error 色文案', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ComposerMetaBar(
          category: _cat(minTags: 2),
          categories: const [],
          onCategorySelected: (_) {},
          selectedTags: const [],
          allTags: const ['a', 'b'],
          onTagsChanged: (_) {},
        ),
      ),
    );
    expect(find.text(S.current.topic_minTagsRequired(2)), findsOneWidget);
  });

  testWidgets('禁用态:pills 不可点(IgnorePointer)', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _wrap(
        ComposerMetaBar(
          category: _cat(),
          categories: const [],
          onCategorySelected: (_) => tapped = true,
          selectedTags: const [],
          allTags: const [],
          onTagsChanged: (_) {},
          enabled: false,
        ),
      ),
    );
    await tester.tap(find.text('沙盒'), warnIfMissed: false);
    await tester.pump();
    expect(tapped, isFalse);
  });
}
