// 回归:投票后滚出 cacheExtent 再滚回(State 销毁重建)不丢投票状态。
// 根因:服务端只在用户已有投票记录时才下发 polls_votes,首次投票时
// post.pollsVotes 为 null,旧 onPollUpdated 回写被 if (pollsVotes != null)
// 跳过 → 重建时 userVotes 读空 → 回到未投票界面(票数却涨了)。
// 修复:Post.applyPollUpdate 集中落地,??= 初始化 pollsVotes。
import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/content/discourse_html_content/builders/poll_builder.dart';

void main() {
  Poll makePoll({required int voters, int votesA = 0, int votesB = 0}) {
    return Poll(
      id: 1,
      name: 'poll',
      type: 'regular',
      status: 'open',
      results: 'always',
      voters: voters,
      options: [
        PollOption(id: 'aaa', html: '选项A', votes: votesA),
        PollOption(id: 'bbb', html: '选项B', votes: votesB),
      ],
    );
  }

  // 首次投票前的 post:有 polls,但 pollsVotes 为 null(服务端未下发)
  Post makePost() {
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
      polls: [makePoll(voters: 0)],
      pollsVotes: null,
    );
  }

  const serverCooked = '''
<div class="poll" data-poll-name="poll" data-poll-results="always"
     data-poll-status="open" data-poll-type="regular">
  <div class="poll-container"><ul>
    <li data-poll-option-id="aaa">选项A</li>
    <li data-poll-option-id="bbb">选项B</li>
  </ul></div>
</div>''';

  Widget host(Post post) {
    final doc = html_parser.parse(serverCooked);
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

  group('Post.applyPollUpdate', () {
    test('pollsVotes 为 null 时初始化并落地(首投场景)', () {
      final post = makePost();
      expect(post.pollsVotes, isNull);

      post.applyPollUpdate('poll', makePoll(voters: 1, votesA: 1), ['aaa']);

      expect(post.pollsVotes, {
        'poll': ['aaa'],
      });
      expect(post.polls!.single.voters, 1, reason: '同名 poll 应被替换');
      expect(post.polls!.single.options.first.votes, 1);
    });

    test('撤票落地为空列表(非 null),重建后回到未投票态', () {
      final post = makePost();
      post.applyPollUpdate('poll', makePoll(voters: 1, votesA: 1), ['aaa']);
      post.applyPollUpdate('poll', makePoll(voters: 0), []);

      expect(post.pollsVotes, {'poll': <String>[]});
      expect(post.polls!.single.voters, 0);
    });

    test('votes 拷贝写入:调用方后续 mutate 传入 list 不污染 post', () {
      final post = makePost();
      final src = ['aaa'];
      post.applyPollUpdate('poll', makePoll(voters: 1, votesA: 1), src);

      // _submitMultipleVote 会把 State 里的 _userVotes 引用传进来,
      // 用户继续点选会 mutate 同一 list —— 落地必须拷贝
      src.add('bbb');
      expect(post.pollsVotes!['poll'], ['aaa']);
    });

    test('post.polls 为 null 时不崩(无投票帖被误调)', () {
      final post = makePost();
      post.polls!.clear();
      final raw = Post(
        id: 2,
        username: 't',
        avatarTemplate: '',
        cooked: '',
        postNumber: 1,
        postType: 1,
        updatedAt: DateTime.now(),
        createdAt: DateTime.now(),
        likeCount: 0,
        replyCount: 0,
      );
      raw.applyPollUpdate('poll', makePoll(voters: 1), ['aaa']);
      expect(raw.polls, isNull);
      expect(raw.pollsVotes, {
        'poll': ['aaa'],
      });
    });
  });

  group('重建恢复(模拟滚出滚回)', () {
    testWidgets('投票落地后全新构建 → 结果态 + 自己的选项勾选', (tester) async {
      final post = makePost();
      // 等价于 _vote 成功后的 onPollUpdated 路径
      post.applyPollUpdate('poll', makePoll(voters: 1, votesA: 1), ['aaa']);

      // 全新 widget 树:旧 State 已销毁(滚出),从 post 现读重建
      await tester.pumpWidget(host(post));
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsNWidgets(2),
          reason: 'hasVoted=true 应显示条形结果,而不是选项列表');
      expect(find.byIcon(Symbols.check_circle_rounded), findsOneWidget,
          reason: '自己投的选项应有勾选标记');
      expect(find.byIcon(Symbols.radio_button_unchecked_rounded), findsNothing,
          reason: '不应回到未投票的选项界面');
    });

    testWidgets('未投票(对照组)→ 选项界面', (tester) async {
      await tester.pumpWidget(host(makePost()));
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byIcon(Symbols.radio_button_unchecked_rounded),
          findsNWidgets(2));
    });
  });
}
