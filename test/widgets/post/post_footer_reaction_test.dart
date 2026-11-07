import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_footer_section/post_footer_section.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/reaction_emoji.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 拦在 dio 拦截器链最前面:记录请求,结果由测试手动放行,模拟请求在途。
/// 后面的 CSRF / Cookie / CF 拦截器都不会执行。
class _ToggleStub {
  final paths = <String>[];
  final _pending = <Completer<Response<dynamic>?>>[];

  late final interceptor = InterceptorsWrapper(
    onRequest: (options, handler) {
      paths.add(options.uri.path);
      final completer = Completer<Response<dynamic>?>();
      _pending.add(completer);
      completer.future.then((response) {
        if (response != null) {
          handler.resolve(response);
        } else {
          handler.reject(
            DioException.badResponse(
              statusCode: 500,
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 500),
            ),
          );
        }
      });
    },
  );

  void succeed(Map<String, dynamic> data) {
    final completer = _pending.removeAt(0);
    completer.complete(
      Response(
        requestOptions: RequestOptions(path: paths.last),
        statusCode: 200,
        data: data,
      ),
    );
  }

  void fail() => _pending.removeAt(0).complete(null);
}

class _Me extends CurrentUserNotifier {
  @override
  User? build() => User(id: 2, username: 'me', trustLevel: 1);
}

Post _post({
  int likeCount = 0,
  List<Map<String, dynamic>> reactions = const [],
  Map<String, dynamic>? current,
}) => Post.fromJson({
  'id': 1,
  'username': 'author',
  'post_number': 2,
  'like_count': likeCount,
  'reactions': reactions,
  'current_user_reaction': current,
});

Finder _buttonEmoji(String id) => find.byWidgetPredicate(
  (widget) => widget is ReactionEmoji && widget.reactionId == id,
);

void main() {
  late SharedPreferences preferences;
  late _ToggleStub stub;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    LocaleSettings.setLocale(AppLocale.zh);
    PlatformUtils.debugDesktopOverride = false;

    stub = _ToggleStub();
    final interceptors = DiscourseService().dio.interceptors;
    interceptors.insert(0, stub.interceptor);
    addTearDown(() {
      PlatformUtils.debugDesktopOverride = null;
      interceptors.remove(stub.interceptor);
    });
  });

  Widget app(Post post) => ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      currentUserProvider.overrideWith(_Me.new),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        // 关掉动态表情:本用例只看回应状态,不碰 AVIF 解码
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: PostFooterSection(
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
      ),
    ),
  );

  testWidgets('回应请求在途时帖子被推送替换,不回闪成旧状态', (tester) async {
    await tester.pumpWidget(app(_post()));
    expect(_buttonEmoji('heart'), findsNothing);

    await tester.tap(find.byIcon(Symbols.favorite_rounded));
    await tester.pump();
    // 乐观更新:接口未返回,按钮已换成 ❤️
    expect(_buttonEmoji('heart'), findsOneWidget);
    // 服务自带的前置拦截器带计时器,推进时钟让请求走到 stub
    await tester.pump(const Duration(seconds: 1));
    expect(stub.paths, [
      '/discourse-reactions/posts/1/custom-reactions/heart/toggle.json',
    ]);

    // 服务端切换回应时推送 liked,页面用只改了点赞数的新帖子对象替换本楼
    await tester.pumpWidget(app(_post(likeCount: 1)));
    expect(_buttonEmoji('heart'), findsOneWidget);

    stub.succeed({
      'reactions': [
        {'id': 'heart', 'type': 'emoji', 'count': 1},
      ],
      'current_user_reaction': {'id': 'heart', 'type': 'emoji'},
    });
    await tester.pump(const Duration(seconds: 1));
    expect(_buttonEmoji('heart'), findsOneWidget);
  });

  testWidgets('回应提交失败回滚,之后帖子更新照常同步', (tester) async {
    await tester.pumpWidget(app(_post()));
    await tester.tap(find.byIcon(Symbols.favorite_rounded));
    await tester.pump();
    expect(_buttonEmoji('heart'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));

    stub.fail();
    await tester.pump(const Duration(seconds: 1));
    expect(_buttonEmoji('heart'), findsNothing);

    // 不再在途:帖子对象带来的新回应状态正常落到按钮上
    await tester.pumpWidget(
      app(
        _post(
          likeCount: 1,
          reactions: [
            {'id': '+1', 'type': 'emoji', 'count': 1},
          ],
          current: {'id': '+1', 'type': 'emoji'},
        ),
      ),
    );
    expect(_buttonEmoji('+1'), findsOneWidget);
  });
}
