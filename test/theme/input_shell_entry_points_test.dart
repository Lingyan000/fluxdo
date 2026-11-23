import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:common_ui/common_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/emoji.dart';
import 'package:fluxdo/pages/forum_preferences/forum_preferences_page.dart';
import 'package:fluxdo/pages/my_browser_page.dart';
import 'package:fluxdo/pages/settings_page.dart';
import 'package:fluxdo/providers/emoji_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/crypto/crypto_toolbox.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/theme_style.dart';
import 'package:fluxdo/widgets/ai/ai_model_select_sheet.dart';
import 'package:fluxdo/widgets/crypto/crypto_algorithm_field.dart';
import 'package:fluxdo/widgets/post/post_boost/boost_input.dart';
import 'package:fluxdo/widgets/post/post_item/post_voting_comment_sheet.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/input_field_shell.dart';

void main() {
  final entries = [
    (
      name: '设置搜索',
      home: const SettingsPage(),
      hint: (AppLocalizations s) => s.settings_searchHint,
    ),
    (
      name: '论坛偏好搜索',
      home: const ForumPreferencesPage(username: 'tester'),
      hint: (AppLocalizations s) => s.forumPrefs_search,
    ),
    (
      name: 'AI 模型搜索',
      home: _sheetHost(_openAiPicker),
      hint: (AppLocalizations s) => s.ai_modelSearchHint,
    ),
    (
      name: '加密算法搜索',
      home: _sheetHost(
        (context) => showCryptoAlgorithmPicker(
          context,
          currentAlgorithmId: CryptoToolbox.defaultAlgorithmId,
        ),
      ),
      hint: (AppLocalizations s) => s.crypto_searchHint,
    ),
    (
      name: '浏览器地址栏',
      home: const MyBrowserPage(),
      hint: (AppLocalizations s) => s.webview_addressHint,
    ),
    (
      name: '助推输入',
      home: _sheetHost(showBoostInputSheet),
      hint: (AppLocalizations s) => s.boost_placeholder,
    ),
    (
      name: '投票评论输入',
      home: _sheetHost(
        (context) => showPostVotingCommentSheet(
          context,
          postId: 1,
          replyToUsername: 'tester',
        ),
      ),
      hint: (AppLocalizations s) => s.postVoting_commentHint,
    ),
  ];

  for (final inputs in [InputStyle.outlined, InputStyle.underline]) {
    for (final brightness in Brightness.values) {
      for (final entry in entries) {
        testWidgets('${entry.name} ${inputs.name} ${brightness.name}', (
          tester,
        ) async {
          if (entry.home is ForumPreferencesPage) _mockForumPreferences();
          final theme = _buildTheme(inputs, brightness);
          await _pumpEntry(tester, entry.home, theme);
          final hint = entry.hint(S.current);
          final field = find.byWidgetPredicate(
            (widget) =>
                widget is TextField && widget.decoration?.hintText == hint,
          );
          await _expectFieldStates(tester, field, theme.inputDecorationTheme);
        });
      }
    }
  }
}

ThemeData _buildTheme(InputStyle inputs, Brightness brightness) {
  const seed = Color(0xFFB9532F);
  return buildAppTheme(
    ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
    AppColors.material(brightness),
    UiShapes.standard,
    const ThemeState(mode: ThemeMode.system, seedColor: seed),
    fullscreenSwipeBack: false,
    pageBackground: false,
    style: ThemeStyle(inputs: inputs),
  );
}

Widget _sheetHost(void Function(BuildContext) openSheet) => Scaffold(
  body: Builder(
    builder: (context) => TextButton(
      key: const ValueKey('open-input-test-sheet'),
      onPressed: () => openSheet(context),
      child: const Text('打开'),
    ),
  ),
);

void _openAiPicker(BuildContext context) {
  const model = AiModel(id: 'test', name: 'Test', output: [Modality.text]);
  const provider = AiProvider(
    id: 'test',
    name: 'Test',
    type: AiProviderType.openai,
    baseUrl: 'https://example.com',
    models: [model],
  );
  const current = (provider: provider, model: model);
  showAiModelSelectSheet(
    context: context,
    allModels: const [current],
    current: current,
    mode: PromptType.text,
  );
}

void _mockForumPreferences() {
  final preloaded = PreloadedDataService()..debugSeed(loaded: true);
  addTearDown(preloaded.reset);
  final interceptors = DiscourseService().dio.interceptors;
  final interceptor = InterceptorsWrapper(
    onRequest: (options, handler) {
      expect(options.path, '/u/tester.json');
      handler.resolve(
        Response(
          requestOptions: options,
          data: {
            'user': {
              'id': 1,
              'username': 'tester',
              'can_edit': true,
              'user_option': <String, dynamic>{},
            },
          },
        ),
      );
    },
  );
  interceptors.insert(0, interceptor);
  addTearDown(() => interceptors.remove(interceptor));
}

Future<void> _pumpEntry(
  WidgetTester tester,
  Widget home,
  ThemeData theme,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'pref_dialog_blur': false});
  final prefs = await SharedPreferences.getInstance();
  final providers = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      aiSharedPreferencesProvider.overrideWithValue(prefs),
      emojiGroupsProvider.overrideWith(
        (_) => Stream.value(const <String, List<Emoji>>{}),
      ),
    ],
  );
  addTearDown(providers.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: providers,
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: theme,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: home,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final open = find.byKey(const ValueKey('open-input-test-sheet'));
  if (open.evaluate().isNotEmpty) {
    await tester.tap(open);
    await tester.pumpAndSettle();
  }
}

Future<void> _expectFieldStates(
  WidgetTester tester,
  Finder field,
  InputDecorationThemeData theme,
) async {
  expect(field, findsOneWidget);
  final shell = find.ancestor(
    of: field,
    matching: find.byType(InputFieldShell),
  );
  expect(shell, findsOneWidget);
  final surface = find.ancestor(
    of: field,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Container && widget.foregroundDecoration is ShapeDecoration,
    ),
  );
  final decorator = find.descendant(
    of: field,
    matching: find.byType(InputDecorator),
  );
  final editable = find.descendant(
    of: field,
    matching: find.byType(EditableText),
  );
  final state = tester.state<EditableTextState>(editable);
  final focus = state.widget.focusNode;
  if (focus.hasFocus) {
    focus.unfocus();
    await tester.pumpAndSettle();
  }

  void expectStroke({required bool focused}) {
    final input = tester.widget<InputDecorator>(decorator);
    expect(input.isFocused, focused);
    expect(input.decoration.enabledBorder, InputBorder.none);
    expect(input.decoration.focusedBorder, InputBorder.none);
    final container = tester.widget<Container>(surface);
    expectInputShellStroke(
      stroke: (container.foregroundDecoration! as ShapeDecoration).shape,
      outline:
          (container.decoration! as ShapeDecoration).shape
              as RoundedSuperellipseBorder,
      size: tester.getSize(surface),
      themeBorder: focused ? theme.focusedBorder : theme.enabledBorder,
    );
  }

  expectStroke(focused: false);
  await tester.tap(field);
  await tester.pumpAndSettle();
  expectStroke(focused: true);
  await tester.enterText(field, 'test');
  await tester.pumpAndSettle();
  expect(tester.state<EditableTextState>(editable), same(state));
  expect(state.widget.controller.text, 'test');
  expectStroke(focused: true);
  focus.unfocus();
  await tester.pumpAndSettle();
  expectStroke(focused: false);
}
