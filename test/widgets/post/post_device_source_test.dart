import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_action_bar.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_footer_section/post_footer_section.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_device_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    LocaleSettings.setLocale(AppLocale.zh);
  });

  Widget app({
    Widget? child,
    String? device = 'iPhone 17 Pro Max',
    double width = 320,
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) => ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      currentUserProvider.overrideWith(_GuestUser.new),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: brightness,
          ),
        ),
        locale: const Locale('zh'),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Center(
              child: SizedBox(
                width: width,
                child: child ?? PostDeviceSource(deviceName: device),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('缺少或空白型号不占空间', (tester) async {
    for (final device in <String?>[null, '', '   ']) {
      await tester.pumpWidget(app(device: device));
      expect(find.byType(TextButton), findsNothing);
      expect(tester.getSize(find.byType(PostDeviceSource)).height, 0);
    }
  });

  testWidgets('长型号在窄屏和大字号下单行省略，保留完整可访问文本', (tester) async {
    final device = List.filled(12, 'iPhone 17 Pro Max').join(' ');
    final semantics = tester.ensureSemantics();
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.5]) {
        await tester.pumpWidget(
          app(device: device, width: 120, scale: scale, brightness: brightness),
        );
        final text = tester.widget<Text>(find.text('来自 $device'));
        expect(text.maxLines, 1);
        expect(text.overflow, TextOverflow.ellipsis);
        expect(
          tester.getSize(find.byType(TextButton)).width,
          lessThanOrEqualTo(120),
        );
        expect(
          tester.getSize(find.byType(TextButton)).height,
          greaterThanOrEqualTo(44),
        );
        expect(find.bySemanticsLabel('来自 $device'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
    semantics.dispose();
  });

  testWidgets('点击可查看并选择完整型号，关闭后回到帖子', (tester) async {
    final device = List.filled(12, 'iPhone 17 Pro Max').join(' ');
    await tester.pumpWidget(app(device: device, width: 120));
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(find.text('帖子来源'), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      '来自 $device',
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('共用帖子底部在操作栏前显示来源，缺少来源时隐藏', (tester) async {
    for (final device in <String?>['iPhone 17 Pro Max', null]) {
      final post = Post.fromJson({
        'id': 1,
        'username': 'tester',
        'ios_device_name': device,
      });
      await tester.pumpWidget(
        app(
          child: PostFooterSection(
            post: post,
            topicId: 1,
            topicHasAcceptedAnswer: false,
            padding: EdgeInsets.zero,
            onReply: null,
            onEdit: null,
            onShareAsImage: null,
            onRefreshPost: null,
            onJumpToPost: null,
            onSolutionChanged: null,
          ),
        ),
      );
      if (device != null) {
        expect(find.byType(PostDeviceSource), findsOneWidget);
        expect(
          tester.getBottomLeft(find.byType(PostDeviceSource)).dy,
          lessThanOrEqualTo(tester.getTopLeft(find.byType(PostActionBar)).dy),
        );
      } else {
        expect(find.byType(PostDeviceSource), findsNothing);
      }
      expect(tester.takeException(), isNull);
    }
  });
}

class _GuestUser extends CurrentUserNotifier {
  @override
  User? build() => null;
}
