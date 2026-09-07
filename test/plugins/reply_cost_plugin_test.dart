import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/plugins/plugins.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 包一层 ProviderScope + 本地化 + MaterialApp，并回抄内层 context
///
/// showAppDialog 会读取模糊偏好，必须有 ProviderScope。
Widget _host(
  SharedPreferences prefs,
  void Function(BuildContext) captureContext,
) {
  return ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    child: TranslationProvider(
      child: MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Builder(
          builder: (context) {
            captureContext(context);
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    ),
  );
}

/// 构造一个最小可用的话题详情 JSON
Map<String, dynamic> _topicJson({Object? replyCost}) => {
  'id': 1,
  'title': 'Topic',
  'slug': 'topic',
  'posts_count': 1,
  'post_stream': {
    'posts': const <Map<String, dynamic>>[],
    'stream': const <int>[],
  },
  'category_id': 1,
  'details': const <String, dynamic>{},
  'reply_cost': ?replyCost,
};

/// 在真实 MaterialApp 里跑插件钩子，返回钩子结果
///
/// [onDialog] 在确认框出现后被调用，用于点「确定」或「取消」。
Future<bool> _runHook(
  WidgetTester tester, {
  required Map<String, dynamic> extras,
  bool isEditing = false,
  Future<void> Function(WidgetTester tester)? onDialog,
}) async {
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();
  late BuildContext ctx;
  await tester.pumpWidget(_host(prefs, (c) => ctx = c));

  const plugin = ReplyCostPlugin();
  final future = plugin.beforeReplySubmit(
    ReplySubmitContext(
      context: ctx,
      topic: TopicPluginContext(topicId: 1, topicJson: extras),
      isEditing: isEditing,
      isPrivateMessage: false,
    ),
  );

  await tester.pumpAndSettle();
  if (onDialog != null) await onDialog(tester);
  await tester.pumpAndSettle();

  return future;
}

void main() {
  group('TopicDetail.pluginExtras', () {
    test('保留顶层非标准标量字段，供插件读取', () {
      final detail = TopicDetail.fromJson(_topicJson(replyCost: 10));
      expect(detail.pluginExtras['reply_cost'], 10);
    });

    test('不含 reply_cost 时扩展字段里也没有该键', () {
      final detail = TopicDetail.fromJson(_topicJson());
      expect(detail.pluginExtras.containsKey('reply_cost'), isFalse);
    });

    test('不收录 post_stream 等重型嵌套结构', () {
      final detail = TopicDetail.fromJson(_topicJson(replyCost: 5));
      expect(detail.pluginExtras.containsKey('post_stream'), isFalse);
      expect(detail.pluginExtras.containsKey('details'), isFalse);
    });

    test('copyWith 透传扩展字段', () {
      final detail = TopicDetail.fromJson(_topicJson(replyCost: 7));
      expect(detail.copyWith(title: 'x').pluginExtras['reply_cost'], 7);
    });
  });

  group('TopicPluginContext.readInt', () {
    test('解析数字与数字字符串，其他返回 null', () {
      expect(
        const TopicPluginContext(topicJson: {'reply_cost': 3}).readInt(
          'reply_cost',
        ),
        3,
      );
      expect(
        const TopicPluginContext(topicJson: {'reply_cost': '4'}).readInt(
          'reply_cost',
        ),
        4,
      );
      expect(
        const TopicPluginContext(topicJson: {'reply_cost': 'abc'}).readInt(
          'reply_cost',
        ),
        isNull,
      );
      expect(
        const TopicPluginContext().readInt('reply_cost'),
        isNull,
      );
    });
  });

  group('TopicPluginData', () {
    setUp(TopicPluginData.clear);

    test('按 topicId 存取，forget 后清空', () {
      TopicPluginData.put(1, {'reply_cost': 9});
      expect(TopicPluginData.of(1)['reply_cost'], 9);
      TopicPluginData.forget(1);
      expect(TopicPluginData.of(1), isEmpty);
    });

    test('未知话题与 null 返回空 Map', () {
      expect(TopicPluginData.of(999), isEmpty);
      expect(TopicPluginData.of(null), isEmpty);
    });
  });

  group('ReplyCostPlugin 钩子', () {
    testWidgets('无 reply_cost 时直接放行且不弹框', (tester) async {
      final allowed = await _runHook(tester, extras: const {});
      expect(allowed, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('reply_cost <= 0 时直接放行', (tester) async {
      final allowed = await _runHook(tester, extras: const {'reply_cost': 0});
      expect(allowed, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('编辑帖子时不拦截（对齐 editingPost）', (tester) async {
      final allowed = await _runHook(
        tester,
        extras: const {'reply_cost': 20},
        isEditing: true,
      );
      expect(allowed, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('reply_cost > 0 且用户确认时放行', (tester) async {
      final allowed = await _runHook(
        tester,
        extras: const {'reply_cost': 20},
        onDialog: (t) async {
          expect(find.textContaining('20'), findsOneWidget);
          await t.tap(find.byType(FilledButton));
        },
      );
      expect(allowed, isTrue);
    });

    testWidgets('reply_cost > 0 且用户取消时中止', (tester) async {
      final allowed = await _runHook(
        tester,
        extras: const {'reply_cost': 20},
        onDialog: (t) async {
          await t.tap(find.byType(TextButton));
        },
      );
      expect(allowed, isFalse);
    });
  });

  group('PluginRegistry', () {
    tearDown(PluginRegistry.resetOverride);

    test('linux.do 默认注册了回复扣积分插件', () {
      expect(
        PluginRegistry.plugins.whereType<ReplyCostPlugin>(),
        isNotEmpty,
      );
    });

    testWidgets('任一插件否决即中止，后续插件不再执行', (tester) async {
      var secondRan = false;
      PluginRegistry.overridePlugins([
        const _DenyPlugin(),
        _SpyPlugin(() => secondRan = true),
      ]);

      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      late BuildContext ctx;
      await tester.pumpWidget(_host(prefs, (c) => ctx = c));

      final allowed = await PluginRegistry.runBeforeReplySubmit(
        ReplySubmitContext(
          context: ctx,
          topic: const TopicPluginContext(topicId: 1),
          isEditing: false,
          isPrivateMessage: false,
        ),
      );

      expect(allowed, isFalse);
      expect(secondRan, isFalse);
    });
  });
}

class _DenyPlugin extends SitePlugin {
  const _DenyPlugin();
  @override
  String get id => 'deny';
  @override
  Future<bool> beforeReplySubmit(ReplySubmitContext context) async => false;
}

class _SpyPlugin extends SitePlugin {
  const _SpyPlugin(this.onRun);
  final VoidCallback onRun;
  @override
  String get id => 'spy';
  @override
  Future<bool> beforeReplySubmit(ReplySubmitContext context) async {
    onRun();
    return true;
  }
}
