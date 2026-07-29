import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/private_message_participants.dart';

TopicUser _user(int id, String username, {String? name}) {
  return TopicUser(id: id, username: username, name: name, avatarTemplate: '');
}

Widget _wrap(Widget child) {
  return TranslationProvider(
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocaleUtils.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

PrivateMessageParticipants _panel({
  required bool canRemoveOtherParticipants,
  int? removableSelfId = 1,
  int? removingParticipantId,
  ValueChanged<TopicUser>? onRemoveParticipant,
}) {
  return PrivateMessageParticipants(
    location: PrivateMessageParticipantsLocation.firstPost,
    participants: [
      _user(1, 'me', name: '我'),
      _user(2, 'alice', name: 'Alice'),
      _user(3, 'bob'),
    ],
    currentUserId: 1,
    canRemoveOtherParticipants: canRemoveOtherParticipants,
    removableSelfId: removableSelfId,
    removingParticipantId: removingParticipantId,
    onRemoveParticipant: onRemoveParticipant,
  );
}

void main() {
  testWidgets('面板显示全部私信成员、用户名与人数', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _panel(canRemoveOtherParticipants: false, onRemoveParticipant: (_) {}),
      ),
    );
    await tester.pump();

    expect(find.text('参与者'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('我'), findsOneWidget);
    expect(find.text('@me'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
  });

  testWidgets('普通成员只显示自己的退出按钮', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _panel(canRemoveOtherParticipants: false, onRemoveParticipant: (_) {}),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('pm-participant-firstPost-remove-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('pm-participant-firstPost-remove-2')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('pm-participant-firstPost-remove-3')),
      findsNothing,
    );
  });

  testWidgets('管理员可退出自己并移除其他成员', (tester) async {
    TopicUser? removed;
    await tester.pumpWidget(
      _wrap(
        _panel(
          canRemoveOtherParticipants: true,
          onRemoveParticipant: (participant) => removed = participant,
        ),
      ),
    );
    await tester.pump();

    for (final id in [1, 2, 3]) {
      expect(
        find.byKey(ValueKey('pm-participant-firstPost-remove-$id')),
        findsOneWidget,
      );
    }

    await tester.tap(
      find.byKey(const ValueKey('pm-participant-firstPost-remove-2')),
    );
    expect(removed?.username, 'alice');
  });

  testWidgets('后端未授予退出权限时不显示自己的按钮', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _panel(
          canRemoveOtherParticipants: false,
          removableSelfId: null,
          onRemoveParticipant: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('pm-participant-firstPost-remove-1')),
      findsNothing,
    );
  });
}
