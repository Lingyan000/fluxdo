// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/metaverse_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/models/cdk_user_info.dart';
import 'package:fluxdo/models/ldc_user_info.dart';
import 'package:fluxdo/providers/cdk_providers.dart';
import 'package:fluxdo/providers/ldc_providers.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/network/exceptions/oauth_exception.dart';
import 'package:fluxdo/widgets/cdk_balance_card.dart';
import 'package:fluxdo/widgets/common/balance_card_action_button.dart';
import 'package:fluxdo/widgets/common/balance_card_cf_action.dart';
import 'package:fluxdo/widgets/ldc_balance_card.dart';
import 'package:m3e_ui/m3e_ui.dart';

mixin _ControlledBalance<T> on AsyncNotifier<T> {
  int retryCalls = 0;
  Completer<void>? retryCompleter;

  void fail(Object error) {
    state = AsyncError<T>(error, StackTrace.current);
  }

  Future<void> retry() async {
    retryCalls++;
    state = AsyncLoading<T>().copyWithPrevious(state);
    retryCompleter = Completer<void>();
    await retryCompleter!.future;
    fail(StateError('网络仍不可用'));
  }
}

class _LdcNotifier extends LdcUserInfoNotifier
    with _ControlledBalance<LdcUserInfo?> {
  @override
  Future<LdcUserInfo?> build() async => null;

  @override
  Future<void> refresh() => retry();
}

class _CdkNotifier extends CdkUserInfoNotifier
    with _ControlledBalance<CdkUserInfo?> {
  @override
  Future<CdkUserInfo?> build() async => null;

  @override
  Future<void> refresh() => retry();
}

class _PendingLdcNotifier extends LdcUserInfoNotifier {
  final loaded = Completer<LdcUserInfo?>();
  int refreshCalls = 0;
  @override
  Future<LdcUserInfo?> build() => loaded.future;
  @override
  Future<void> refresh() async => refreshCalls++;
}

class _PendingCdkNotifier extends CdkUserInfoNotifier {
  final loaded = Completer<CdkUserInfo?>();
  int refreshCalls = 0;
  @override
  Future<CdkUserInfo?> build() => loaded.future;
  @override
  Future<void> refresh() async => refreshCalls++;
}

Widget _app(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('zh'),
        supportedLocales: AppLocaleUtils.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: child),
      ),
    ),
  );
}

ButtonStyleButton _action(WidgetTester tester) {
  return tester.widget<ButtonStyleButton>(
    find.descendant(
      of: find.byType(BalanceCardActionButton),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    ),
  );
}

void main() {
  for (final isLdc in [true, false]) {
    final service = isLdc ? 'LDC' : 'CDK';
    for (final layout in ['full', 'compact', 'inline']) {
      late _LdcNotifier ldc;
      late _CdkNotifier cdk;
      late ProviderContainer container;

      Future<void> initialize(Object error) async {
        ldc = _LdcNotifier();
        cdk = _CdkNotifier();
        container = ProviderContainer(
          overrides: [
            ldcUserInfoProvider.overrideWith(() => ldc),
            cdkUserInfoProvider.overrideWith(() => cdk),
          ],
        );
        addTearDown(container.dispose);
        if (isLdc) {
          await container.read(ldcUserInfoProvider.future);
          ldc.fail(error);
        } else {
          await container.read(cdkUserInfoProvider.future);
          cdk.fail(error);
        }
      }

      Widget card({
        bool isProcessing = false,
        VoidCallback? onReauthorize,
        VoidCallback? onDisable,
      }) {
        return isLdc
            ? LdcBalanceCard(
                compact: layout == 'compact',
                inline: layout == 'inline',
                isProcessing: isProcessing,
                onReauthorize: onReauthorize,
                onDisable: onDisable,
              )
            : CdkBalanceCard(
                compact: layout == 'compact',
                inline: layout == 'inline',
                isProcessing: isProcessing,
                onReauthorize: onReauthorize,
                onDisable: onDisable,
              );
      }

      testWidgets('$service $layout 重新授权有进度、防重复点击，取消后可再次操作', (tester) async {
        await initialize(OAuthExpiredException(serviceName: service));
        var processing = false;
        var calls = 0;
        late StateSetter update;
        await tester.pumpWidget(
          _app(
            container,
            StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return card(
                  isProcessing: processing,
                  onDisable: () {},
                  onReauthorize: () {
                    calls++;
                    setState(() => processing = true);
                  },
                );
              },
            ),
          ),
        );

        final label = S.current.common_reAuth;
        expect(_action(tester).onPressed, isNotNull);
        await tester.tap(find.text(label));
        await tester.pump();

        expect(calls, 1);
        expect(find.text(label), findsOneWidget);
        expect(find.text(S.current.common_retry), findsNothing);
        expect(find.byType(LoadingSpinner), findsOneWidget);
        expect(_action(tester).onPressed, isNull);
        await tester.tap(find.text(label), warnIfMissed: false);
        expect(calls, 1);

        update(() => processing = false);
        await tester.pump();
        expect(find.byType(LoadingSpinner), findsNothing);
        expect(_action(tester).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$service $layout 重试期间显示进度，失败后恢复按钮', (tester) async {
        await initialize(StateError('网络不可用'));
        await tester.pumpWidget(_app(container, card()));
        final label = S.current.common_retry;

        await tester.tap(find.text(label));
        await tester.pump();

        expect(find.text(label), findsOneWidget);
        expect(find.byType(LoadingSpinner), findsOneWidget);
        expect(_action(tester).onPressed, isNull);
        await tester.tap(find.text(label), warnIfMissed: false);
        expect(isLdc ? ldc.retryCalls : cdk.retryCalls, 1);

        (isLdc ? ldc.retryCompleter : cdk.retryCompleter)!.complete();
        await tester.pump();
        expect(find.byType(LoadingSpinner), findsNothing);
        expect(_action(tester).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$service $layout CF 拦截显示验证入口，不提示重新授权', (tester) async {
        final options = RequestOptions(path: '/api/v1/oauth/user-info');
        await initialize(
          DioException(
            requestOptions: options,
            response: Response(
              requestOptions: options,
              statusCode: 403,
              headers: Headers.fromMap({
                'cf-mitigated': ['challenge'],
              }),
            ),
          ),
        );
        await tester.pumpWidget(_app(container, card(onReauthorize: () {})));

        expect(find.text(S.current.error_securityChallenge), findsOneWidget);
        expect(find.text(S.current.cf_manualVerifyAction), findsOneWidget);
        expect(find.text(S.current.common_reAuth), findsNothing);
        expect(find.byType(BalanceCardCfAction), findsOneWidget);
        expect(_action(tester).onPressed, isNotNull);
      });
    }
  }

  for (final isLdc in [true, false]) {
    testWidgets('${isLdc ? 'LDC' : 'CDK'} 初始化等待期间退出元宇宙，不再刷新已销毁页面', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'ldc_enabled': isLdc,
        'cdk_enabled': !isLdc,
      });
      final prefs = await SharedPreferences.getInstance();
      final ldc = _PendingLdcNotifier();
      final cdk = _PendingCdkNotifier();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ldcUserInfoProvider.overrideWith(() => ldc),
          cdkUserInfoProvider.overrideWith(() => cdk),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container, const MetaversePage()));
      await tester.pumpWidget(const SizedBox.shrink());
      if (isLdc) {
        ldc.loaded.complete(null);
      } else {
        cdk.loaded.complete(null);
      }
      await tester.pump();
      expect(ldc.refreshCalls + cdk.refreshCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('手动验证防止重复点击，并等待余额刷新完成才结束 loading', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final verified = Completer<bool?>();
    final refreshed = Completer<void>();
    var verifications = 0;
    var retries = 0;
    await tester.pumpWidget(
      _app(
        container,
        BalanceCardCfAction(
          isLoading: false,
          verify: (_) {
            verifications++;
            return verified.future;
          },
          onRetry: () {
            retries++;
            return refreshed.future;
          },
        ),
      ),
    );
    final label = S.current.cf_manualVerifyAction;
    await tester.tap(find.text(label));
    await tester.tap(find.text(label));
    await tester.pump();
    expect(verifications, 1);
    expect(_action(tester).onPressed, isNull);
    verified.complete(true);
    await tester.pump();
    expect(retries, 1);
    expect(find.byType(LoadingSpinner), findsOneWidget);
    refreshed.complete();
    await tester.pump();
    expect(find.byType(LoadingSpinner), findsNothing);
    expect(_action(tester).onPressed, isNotNull);
  });
}
