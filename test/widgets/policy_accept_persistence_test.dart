// 回归:policy 接受/撤销落地 provider 后,滚出滚回(State 销毁重建)状态保留。
// 根因:旧 _accept/_revoke 成功后只本地 setState,无任何落地 —— sliver 回收
// 销毁 State 后,initState 从 post 旧值 _syncFromPost,接受状态丢失。
// 修复:成功后 updatePostPolicy 回写 provider(copyWith 新 post →
// CurrentPostScope 广播),重建时 post 已是新值。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/content/discourse_html_content/builders/policy_builder.dart';
import 'package:fluxdo/widgets/content/discourse_html_content/current_post_scope.dart';

void main() {
  Post makePost({
    bool accepted = false,
    bool revoked = false,
    bool canAccept = true,
    bool canRevoke = false,
    int? acceptedCount,
    int? notAcceptedCount,
  }) {
    return Post(
      id: 1,
      username: 'tester',
      avatarTemplate: '',
      cooked: '',
      postNumber: 1,
      postType: 1,
      updatedAt: DateTime.now(),
      createdAt: DateTime.now(),
      likeCount: 0,
      replyCount: 0,
      policyAccepted: accepted,
      policyRevoked: revoked,
      policyCanAccept: canAccept,
      policyCanRevoke: canRevoke,
      policyAcceptedByCount: acceptedCount,
      policyNotAcceptedByCount: notAcceptedCount,
    );
  }

  const serverCooked = '''
<div class="policy" data-accept="接受" data-revoke="撤销">
  <div class="policy-body">政策正文</div>
</div>''';

  /// [wrapScope] 模拟正文渲染树:CurrentPostScope 广播 post 引用
  Widget host(Post post, {bool wrapScope = false}) {
    final doc = html_parser.parse(serverCooked);
    final el = doc.querySelector('div.policy')!;
    return ProviderScope(
      child: TranslationProvider(
      child: MaterialApp(
        locale: const Locale('zh'),
        navigatorKey: navigatorKey,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('zh'), Locale('en')],
        home: Scaffold(
          body: Builder(
            builder: (context) {
              final policy = buildPolicy(
                context: context,
                theme: ThemeData(),
                element: el,
                post: post,
                // 纯 UI 验证:无话题上下文,_syncToProvider 判空静默
                topicId: null,
                htmlBuilder: (html, _) => Text(
                  html.replaceAll(RegExp(r'<[^>]*>'), ''),
                ),
              );
              return SingleChildScrollView(
                child: wrapScope
                    ? CurrentPostScope(post: post, child: policy)
                    : policy,
              );
            },
          ),
        ),
      ),
      ),
    );
  }

  testWidgets('落地后重建(模拟滚出滚回)→ 已接受态:撤销按钮 + 计数',
      (tester) async {
    // provider 落地后的 post(updatePostPolicy copyWith 产物等价形态)
    final post = makePost(
      accepted: true,
      canAccept: false,
      canRevoke: true,
      acceptedCount: 1,
      notAcceptedCount: 0,
    );
    await tester.pumpWidget(host(post));
    await tester.pump();

    expect(find.text('撤销'), findsOneWidget, reason: '已接受 → 出现撤销按钮');
    expect(find.text('接受'), findsNothing, reason: 'canAccept=false → 不再渲染接受按钮');
    expect(find.text('1'), findsOneWidget, reason: '已接受计数显示');
  });

  testWidgets('未接受(对照组)→ 接受按钮', (tester) async {
    await tester.pumpWidget(host(makePost()));
    await tester.pump();

    expect(find.text('接受'), findsOneWidget);
    expect(find.text('撤销'), findsNothing);
  });

  testWidgets('CurrentPostScope 替换 post(provider 落地广播)→ widget 跟随',
      (tester) async {
    // 初始:未接受
    await tester.pumpWidget(host(makePost(), wrapScope: true));
    await tester.pump();
    expect(find.text('接受'), findsOneWidget);

    // accept 成功 → updatePostPolicy copyWith 产出新 post → scope 广播
    final updated = makePost(
      accepted: true,
      canAccept: false,
      canRevoke: true,
      acceptedCount: 1,
    );
    await tester.pumpWidget(host(updated, wrapScope: true));
    await tester.pump();

    expect(find.text('撤销'), findsOneWidget, reason: 'scope 新 post 应同步覆盖本地态');
    expect(find.text('接受'), findsNothing);
  });

  // ConsumerStatefulWidget 化后,无 provider 环境也得能渲染(分享截图等
  // topicId=null 场景不落地但不崩)
  testWidgets('包在 ProviderScope 中渲染不崩(Consumer 化冒烟)', (tester) async {
    await tester.pumpWidget(ProviderScope(child: host(makePost())));
    await tester.pump();
    expect(find.text('接受'), findsOneWidget);
  });
}
