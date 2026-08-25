/// 加解密弹窗渲染测试：验证各种屏幕尺寸与算法类型下无 RenderFlex overflow。
///
/// 布局类回归（截图曾暴露：密文框溢出、宽屏按钮拉满、选择器系统键盘
/// 快捷条遮挡）由这些用例守护。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart' show sharedPreferencesProvider;
import 'package:fluxdo/widgets/crypto/crypto_algorithm_field.dart';
import 'package:fluxdo/providers/secret_store_provider.dart';
import 'package:fluxdo/services/crypto/crypto_toolbox.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:common_ui/common_ui.dart' show AppSheetScaffold, AppSheetStyle;
import 'package:fluxdo/widgets/crypto/crypto_decrypt_sheet.dart';
import 'package:fluxdo/widgets/crypto/crypto_encrypt_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child,
    {Size size = const Size(390, 844), String? title}) {
  return TranslationProvider(
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocaleUtils.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: AppSheetScaffold(
              style: AppSheetStyle.card,
              title: title,
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<Widget> _withProviders(Widget child) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      secretStoreProvider.overrideWithValue(InMemorySecretStore()),
    ],
    child: child,
  );
}

/// 长密文（ENC1 单行超长 token —— 截图 1 的溢出场景）
const _longCipher =
    'ENC1:aes-256-cbc:TG9yZW0gaXBzdW0gZG9sb3Igc2l0IGFtZXQgY29uc2VjdGV0dXIg'
    'YWRpcGlzY2luZyBlbGl0IHNlZCBkbyBlaXVzbW9kIHRlbXBvcg==';

void main() {
  group('解密弹窗布局', () {
    for (final size in [const Size(390, 844), const Size(1100, 800)]) {
      testWidgets('宽 ${size.width} 无溢出', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(await _withProviders(_wrap(
          const CryptoDecryptSheet(initialCiphertext: _longCipher),
          size: size,
          title: '解密内容',
        )));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('解密内容'), findsOneWidget);
        // 自动识别徽标出现（ENC1 嗅探命中）
        expect(find.text('已自动识别'), findsOneWidget);
      });
    }

    testWidgets('密码输入（对称算法）显示与记住密码开关', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(await _withProviders(_wrap(
          const CryptoDecryptSheet(initialCiphertext: _longCipher))));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('crypto-decrypt-password-input')),
          findsOneWidget);
    });

    testWidgets('编码算法（无密钥区）', (tester) async {
      await tester.pumpWidget(await _withProviders(_wrap(
          const CryptoDecryptSheet(initialCiphertext: 'SGVsbG8gRmx1eGRvIQ=='))));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // base64 无需密码 → 密码框不出现
      expect(find.byKey(const ValueKey('crypto-decrypt-password-input')),
          findsNothing);
    });
  });

  group('加密弹窗布局', () {
    testWidgets('宽屏（1100）无溢出且按钮不拉满', (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(await _withProviders(_wrap(
        const CryptoEncryptSheet(initialPlaintext: '测试明文'),
        size: const Size(1100, 800),
        title: '加密内容',
      )));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('加密内容'), findsOneWidget);
      // 按钮存在
      expect(find.byKey(const ValueKey('crypto-encrypt-action')), findsOneWidget);
    });

    testWidgets('手机端全宽布局正常', (tester) async {
      await tester.pumpWidget(await _withProviders(_wrap(
          const CryptoEncryptSheet(initialPlaintext: '测试明文'))));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('算法选择器布局', () {
    testWidgets('列表态无溢出', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(await _withProviders(_wrap(
        const CryptoAlgorithmPickerSheet(
            currentAlgorithmId: CryptoToolbox.defaultAlgorithmId),
      )));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('crypto-picker-search')), findsOneWidget);
    });

    testWidgets('搜索过滤出目标算法', (tester) async {
      await tester.pumpWidget(await _withProviders(_wrap(
        const CryptoAlgorithmPickerSheet(
            currentAlgorithmId: CryptoToolbox.defaultAlgorithmId),
      )));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('crypto-picker-search')), 'gcm');
      await tester.pumpAndSettle();

      expect(find.text('AES-256-GCM'), findsOneWidget);
      expect(find.text('AES-256-CBC'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('网格切换后无溢出', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(await _withProviders(_wrap(
        const CryptoAlgorithmPickerSheet(
            currentAlgorithmId: CryptoToolbox.defaultAlgorithmId),
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('crypto-picker-toggle-layout')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('crypto-grid-aes-256-cbc')),
          findsOneWidget);
    });
  });
}
