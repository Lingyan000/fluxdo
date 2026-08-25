// 临时验证:饼图渲染链路(buildPoll → _PollWidget → _PiePainter)。
// 验证点:1) 服务端形态 cooked(camelCase 属性)能读出 chartType;
// 2) 已投票 + voters>0 + pie → CustomPaint 出现;3) voters=0 回落条形。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/content/discourse_html_content/builders/poll_builder.dart';

void main() {
  Post makePost({
    required int voters,
    required List<String> votes,
    String? apiChartType,
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
      polls: [
        Poll(
          id: 1,
          name: 'poll',
          type: 'regular',
          status: 'open',
          results: 'always',
          voters: voters,
          chartType: apiChartType,
          options: [
            PollOption(id: 'aaa', html: '选项A', votes: voters > 0 ? 3 : 0),
            PollOption(id: 'bbb', html: '选项B', votes: voters > 0 ? 1 : 0),
          ],
        ),
      ],
      pollsVotes: votes.isEmpty ? null : {'poll': votes},
    );
  }

  // 服务端 cooked 形态:属性名 camelCase(markdown-it 原样输出),
  // package:html 解析后应归一为小写可读
  const serverCooked = '''
<div class="poll" data-poll-chartType="pie" data-poll-name="poll"
     data-poll-public="true" data-poll-results="always"
     data-poll-status="open" data-poll-type="regular">
  <div class="poll-container"><ul>
    <li data-poll-option-id="aaa">选项A</li>
    <li data-poll-option-id="bbb">选项B</li>
  </ul></div>
</div>''';

  Widget host(Post post, {String cooked = serverCooked}) {
    final doc = html_parser.parse(cooked);
    final el = doc.querySelector('div.poll')!;
    return TranslationProvider(
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
            builder: (context) => SingleChildScrollView(
              child: buildPoll(
                context: context,
                theme: ThemeData(),
                element: el,
                post: post,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('已投票+有票数+pie → 渲染饼图 CustomPaint', (tester) async {
    await tester.pumpWidget(host(makePost(voters: 4, votes: ['aaa'])));
    await tester.pump();
    // 饼图的 CustomPaint(区别于框架自带),按 key 或 painter 类型找
    final customPaints = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_PiePainter',
    );
    expect(customPaints, findsOneWidget, reason: '应出现饼图 painter');
  });

  testWidgets('API chart_type=pie 为主源:cooked 无属性也画饼图(线上真实形态)',
      (tester) async {
    // 线上 rawHtml 链路 data-poll-charttype 可能缺失,API poll 对象带
    // chart_type: "pie" —— 判定必须以 API 为主源
    const cookedNoChart = '''
<div class="poll" data-poll-name="poll" data-poll-status="open"
     data-poll-type="regular">
  <div class="poll-container"><ul>
    <li data-poll-option-id="aaa">选项A</li>
    <li data-poll-option-id="bbb">选项B</li>
  </ul></div>
</div>''';
    await tester.pumpWidget(host(
      makePost(voters: 275, votes: ['aaa'], apiChartType: 'pie'),
      cooked: cookedNoChart,
    ));
    await tester.pump();
    final customPaints = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_PiePainter',
    );
    expect(customPaints, findsOneWidget, reason: 'API chart_type 应独立触发饼图');
  });

  testWidgets('voters=0 + pie → 回落条形(无饼图)', (tester) async {
    await tester.pumpWidget(host(makePost(voters: 0, votes: [])));
    await tester.pump();
    final customPaints = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_PiePainter',
    );
    expect(customPaints, findsNothing);
  });
}
