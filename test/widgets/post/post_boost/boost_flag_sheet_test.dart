import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/app_localizations.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/boost_flag_sheet.dart';

void main() {
  group('Boost 操作权限', () {
    const selfBoost = Boost(
      id: 1,
      cooked: 'self',
      user: BoostUser(id: 1, username: 'alice', avatarTemplate: ''),
    );
    const otherBoost = Boost(
      id: 2,
      cooked: 'other',
      user: BoostUser(id: 2, username: 'bob', avatarTemplate: ''),
      canFlag: true,
    );

    test('本人 Boost 可删除但不可举报', () {
      expect(
        canDeleteBoostAction(boost: selfBoost, currentUsername: 'alice'),
        isTrue,
      );
      expect(
        canFlagBoostAction(boost: selfBoost, currentUsername: 'alice'),
        isFalse,
      );
      expect(
        canOpenBoostActionMenu(boost: selfBoost, currentUsername: 'alice'),
        isTrue,
      );
    });

    test('他人 Boost 在 canFlag 为真时可举报', () {
      expect(
        canDeleteBoostAction(boost: otherBoost, currentUsername: 'alice'),
        isFalse,
      );
      expect(
        canFlagBoostAction(boost: otherBoost, currentUsername: 'alice'),
        isTrue,
      );
      expect(
        canOpenBoostActionMenu(boost: otherBoost, currentUsername: 'alice'),
        isTrue,
      );
    });

    test('游客不能打开 Boost 操作菜单', () {
      expect(
        canDeleteBoostAction(boost: otherBoost, currentUsername: null),
        isFalse,
      );
      expect(
        canFlagBoostAction(boost: otherBoost, currentUsername: null),
        isFalse,
      );
      expect(
        canOpenBoostActionMenu(boost: otherBoost, currentUsername: null),
        isFalse,
      );
    });

    test('已举报的他人 Boost 不再视为可举报', () {
      const flaggedBoost = Boost(
        id: 3,
        cooked: 'flagged',
        user: BoostUser(id: 3, username: 'carol', avatarTemplate: ''),
        canFlag: true,
        userFlagStatus: 1,
      );

      expect(
        boostAlreadyReportedByCurrentUser(
          boost: flaggedBoost,
          currentUsername: 'alice',
        ),
        isTrue,
      );
      expect(
        canFlagBoostAction(boost: flaggedBoost, currentUsername: 'alice'),
        isFalse,
      );
    });
  });

  group('Boost 举报类型过滤', () {
    const types = [
      FlagType(
        id: 7,
        nameKey: 'notify_moderators',
        name: 'Other',
        description: '需要版主处理',
        isFlag: true,
        requireMessage: true,
        position: 2,
      ),
      FlagType(
        id: 2,
        nameKey: 'notify_user',
        name: 'Message user',
        description: '提醒 %{username}',
        isFlag: true,
        position: 1,
      ),
      FlagType(
        id: 8,
        nameKey: 'spam',
        name: 'Spam',
        description: '垃圾内容',
        isFlag: true,
        enabled: false,
        position: 3,
      ),
    ];

    test('按 availableFlags 过滤并按 position 排序', () {
      final result = filterBoostFlagTypes(
        allFlagTypes: types,
        availableFlags: const ['notify_moderators', 'notify_user'],
      );

      expect(result.map((type) => type.nameKey).toList(), [
        'notify_user',
        'notify_moderators',
      ]);
    });

    test('availableFlags 为空列表时不返回任何类型', () {
      final result = filterBoostFlagTypes(
        allFlagTypes: types,
        availableFlags: const [],
      );

      expect(result, isEmpty);
    });

    test('availableFlags 缺失时不返回任何类型', () {
      final result = filterBoostFlagTypes(allFlagTypes: types);

      expect(result, isEmpty);
    });
  });

  group('Boost 举报弹层', () {
    testWidgets('选择需要补充说明的类型后可提交举报', (tester) async {
      int? submittedFlagTypeId;
      String? submittedMessage;
      var successCalled = false;

      final boost = const Boost(
        id: 10,
        cooked: 'hello',
        user: BoostUser(id: 2, username: 'bob', avatarTemplate: ''),
        canFlag: true,
        availableFlags: ['notify_moderators', 'notify_user'],
      );

      await tester.pumpWidget(
        _buildTestApp(
          child: _BoostFlagSheetHost(
            boost: boost,
            loadFlagTypes: () async => const [
              FlagType(
                id: 2,
                nameKey: 'notify_user',
                name: 'Message user',
                description: '提醒 %{username}',
                isFlag: true,
                position: 1,
              ),
              FlagType(
                id: 7,
                nameKey: 'notify_moderators',
                name: 'Other',
                description: '需要版主处理',
                isFlag: true,
                requireMessage: true,
                position: 2,
              ),
            ],
            submitFlag: (flagTypeId, message) async {
              submittedFlagTypeId = flagTypeId;
              submittedMessage = message;
            },
            onSuccess: () {
              successCalled = true;
            },
          ),
        ),
      );

      final hostState = tester.state<_BoostFlagSheetHostState>(
        find.byType(_BoostFlagSheetHost),
      );
      hostState.openSheet();

      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('举报 Boost'), findsOneWidget);
      expect(find.textContaining('@bob'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.byIcon(Icons.radio_button_off).last);
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), '请版主看一下');
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      await tester.tap(find.text('提交举报'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(submittedFlagTypeId, 7);
      expect(submittedMessage, '请版主看一下');
      expect(successCalled, isTrue);
    });
  });
}

Widget _buildTestApp({required Widget child}) {
  return TranslationProvider(
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocaleUtils.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

class _BoostFlagSheetHost extends StatefulWidget {
  final Boost boost;
  final BoostFlagTypesLoader loadFlagTypes;
  final BoostFlagSubmitter submitFlag;
  final VoidCallback onSuccess;

  const _BoostFlagSheetHost({
    required this.boost,
    required this.loadFlagTypes,
    required this.submitFlag,
    required this.onSuccess,
  });

  @override
  State<_BoostFlagSheetHost> createState() => _BoostFlagSheetHostState();
}

class _BoostFlagSheetHostState extends State<_BoostFlagSheetHost> {
  Future<void> openSheet() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => BoostFlagSheet(
        boost: widget.boost,
        loadFlagTypes: widget.loadFlagTypes,
        submitFlag: widget.submitFlag,
        onSuccess: widget.onSuccess,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand();
  }
}
