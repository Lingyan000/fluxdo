import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/services/local_notification_service.dart' show navigatorKey;
import 'package:fluxdo/plugins/plugins.dart';
import 'package:fluxdo/widgets/common/character_counts_overlay.dart';
import 'package:fluxdo/widgets/topic/topic_editor_helpers.dart';

/// linux.do 真实分类 JSON 的最小形态（搞七捻三：回复 16 字）
Map<String, dynamic> _categoryJson({
  Object? minPost,
  Object? minFirst,
  bool includeKeys = true,
}) => {
  'id': 11,
  'name': '搞七捻三',
  'slug': 'gossip',
  'color': 'BF1E2E',
  'text_color': 'FFFFFF',
  if (includeKeys)
    'custom_fields': {
      // warden 对未配置的分类也会下发 null，必须能正确当作"未配置"
      'warden_min_post_length': minPost,
      'warden_min_first_post_length': minFirst,
      'has_chat_enabled': null,
      'category_expert_group_ids': '57|54',
    },
};

/// 直接构造插件入参
ComposerMinLengthContext _ctx({
  Map<String, dynamic> extras = const {},
  bool isFirstPost = false,
  bool isPrivateMessage = false,
  bool isPmWithNonHumanUser = false,
  int maxPostLength = 32000,
}) => ComposerMinLengthContext(
  categoryExtras: extras,
  isFirstPost: isFirstPost,
  isPrivateMessage: isPrivateMessage,
  isPmWithNonHumanUser: isPmWithNonHumanUser,
  maxPostLength: maxPostLength,
);

Widget _host(Widget child) => TranslationProvider(
  child: MaterialApp(
    // ComposerMetaBar 内部 pills 用 S.current 取文案，依赖全局 navigatorKey
    navigatorKey: navigatorKey,
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocaleUtils.supportedLocales,
    home: Scaffold(body: child),
  ),
);

void main() {
  group('Category.pluginExtras', () {
    test('解析 custom_fields 里的 warden 字段', () {
      final c = Category.fromJson(_categoryJson(minPost: 16));
      expect(c.pluginExtras['warden_min_post_length'], 16);
    });

    test('值为 null 的键被丢弃（warden 对未配置分类也下发 null）', () {
      final c = Category.fromJson(_categoryJson(minPost: null));
      expect(c.pluginExtras.containsKey('warden_min_post_length'), isFalse);
      // 同批次的非空字段仍要保留
      expect(c.pluginExtras['category_expert_group_ids'], '57|54');
    });

    test('没有 custom_fields 时为空 Map', () {
      final c = Category.fromJson(_categoryJson(includeKeys: false));
      expect(c.pluginExtras, isEmpty);
    });
  });

  group('WardenPlugin.composerMinPostLength', () {
    const plugin = WardenPlugin();

    test('分类配了回复下限 → 采用该值', () {
      expect(
        plugin.composerMinPostLength(
          8,
          _ctx(extras: const {'warden_min_post_length': 16}),
        ),
        16,
      );
    });

    test('首帖读 first 字段，回复读 post 字段（互不串用）', () {
      const extras = {
        'warden_min_post_length': 16,
        'warden_min_first_post_length': 30,
      };
      expect(
        plugin.composerMinPostLength(8, _ctx(extras: extras)),
        16,
      );
      expect(
        plugin.composerMinPostLength(
          20,
          _ctx(extras: extras, isFirstPost: true),
        ),
        30,
      );
    });

    test('首帖字段缺失时回退站点默认，不串用回复字段', () {
      // 这正是 linux.do 现状：first 全为 null、post 有值
      expect(
        plugin.composerMinPostLength(
          20,
          _ctx(extras: const {'warden_min_post_length': 16}, isFirstPost: true),
        ),
        20,
      );
    });

    test('私信完全不接管（即便分类配了值）', () {
      expect(
        plugin.composerMinPostLength(
          10,
          _ctx(
            extras: const {'warden_min_post_length': 16},
            isPrivateMessage: true,
          ),
        ),
        10,
      );
    });

    test('与非真人用户的私信同样不接管', () {
      expect(
        plugin.composerMinPostLength(
          1,
          _ctx(
            extras: const {'warden_min_post_length': 16},
            isPmWithNonHumanUser: true,
          ),
        ),
        1,
      );
    });

    test('0 / 负数 / 非数字一律回退上一级结果', () {
      for (final bad in <Object>[0, -5, 'abc', true]) {
        expect(
          plugin.composerMinPostLength(
            8,
            _ctx(extras: {'warden_min_post_length': bad}),
          ),
          8,
          reason: '值 $bad 应回退',
        );
      }
    });

    test('字符串数字可用（对齐 parseInt）', () {
      expect(
        plugin.composerMinPostLength(
          8,
          _ctx(extras: const {'warden_min_post_length': '16'}),
        ),
        16,
      );
    });

    test('按 max_post_length 封顶', () {
      expect(
        plugin.composerMinPostLength(
          8,
          _ctx(
            extras: const {'warden_min_post_length': 99999},
            maxPostLength: 32000,
          ),
        ),
        32000,
      );
    });

    test('未配置时原样返回上一级值（会员优惠等）', () {
      expect(plugin.composerMinPostLength(4, _ctx()), 4);
    });
  });

  group('PluginRegistry.resolveMinPostLength', () {
    tearDown(PluginRegistry.resetOverride);

    test('linux.do 默认注册了 warden 插件', () {
      expect(PluginRegistry.plugins.whereType<WardenPlugin>(), isNotEmpty);
    });

    test('真实分类数据：搞七捻三回复要 16 字', () {
      final category = Category.fromJson(_categoryJson(minPost: 16));
      expect(
        PluginRegistry.resolveMinPostLength(
          8,
          _ctx(extras: category.pluginExtras),
        ),
        16,
      );
    });
  });

  group('CharacterCountsOverlay', () {
    testWidgets('字数不足时显示 `x / min` + 社区警告', (tester) async {
      await tester.pumpWidget(
        _host(const CharacterCountsOverlay(length: 12, minimumLength: 16)),
      );
      expect(find.textContaining('12 / 16'), findsOneWidget);
      expect(find.textContaining('勿用各类字数补丁'), findsOneWidget);
    });

    testWidgets('达标后完全不显示（不占位、无常驻字数）', (tester) async {
      await tester.pumpWidget(
        _host(const CharacterCountsOverlay(length: 25, minimumLength: 16)),
      );
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('恰好等于下限即视为达标（对齐 missing > 0）', (tester) async {
      await tester.pumpWidget(
        _host(const CharacterCountsOverlay(length: 16, minimumLength: 16)),
      );
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('无下限时不显示', (tester) async {
      await tester.pumpWidget(_host(const CharacterCountsOverlay(length: 7)));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('0 字时也显示提示（不是等打字了才出现）', (tester) async {
      await tester.pumpWidget(
        _host(
          const CharacterCountsOverlay(
            length: 0,
            minimumLength: 15,
            showWarning: false,
          ),
        ),
      );
      expect(find.text('0 / 15'), findsOneWidget);
    });

    testWidgets('标题场景 showWarning=false 时不带警告文案', (tester) async {
      await tester.pumpWidget(
        _host(
          const CharacterCountsOverlay(
            length: 5,
            minimumLength: 15,
            showWarning: false,
          ),
        ),
      );
      expect(find.text('5 / 15'), findsOneWidget);
      expect(find.textContaining('勿用各类字数补丁'), findsNothing);
    });

    testWidgets('是纯文字提示，不带背景装饰', (tester) async {
      await tester.pumpWidget(
        _host(const CharacterCountsOverlay(length: 12, minimumLength: 16)),
      );
      // 组件内部不应引入带 decoration 的 Container（视觉过重）
      final containers = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(CharacterCountsOverlay),
          matching: find.byType(Container),
        ),
      );
      expect(containers.where((c) => c.decoration != null), isEmpty);
    });

    testWidgets('不拦截触摸事件（IgnorePointer）', (tester) async {
      await tester.pumpWidget(
        _host(const CharacterCountsOverlay(length: 12, minimumLength: 16)),
      );
      expect(
        find.descendant(
          of: find.byType(CharacterCountsOverlay),
          matching: find.byType(IgnorePointer),
        ),
        findsOneWidget,
      );
    });
  });

  group('ComposerMetaBar 不再展示常驻字数', () {
    Widget metaBarAt(double width) => _host(
      Center(
        child: SizedBox(
          width: width,
          child: ComposerMetaBar(
            category: null,
            categories: const [],
            onCategorySelected: (_) {},
            selectedTags: const [],
            allTags: const [],
            onTagsChanged: (_) {},
          ),
        ),
      ),
    );

    for (final width in <double>[320, 360, 411, 480]) {
      testWidgets('宽度 ${width.toInt()} 下不溢出', (tester) async {
        await tester.pumpWidget(metaBarAt(width));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '宽度 $width 下 ComposerMetaBar 溢出了',
        );
      });
    }

    testWidgets('不再出现「N 字符」这类常驻计数与警告文案', (tester) async {
      await tester.pumpWidget(metaBarAt(360));
      await tester.pumpAndSettle();
      expect(find.textContaining('字符'), findsNothing);
      expect(find.textContaining('勿用各类字数补丁'), findsNothing);
      expect(find.textContaining('/'), findsNothing);
    });
  });
}
