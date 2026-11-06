import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/network_settings_page/widgets/fingerprint_preset_dialog.dart';
import 'package:fluxdo/services/network/fingerprint/fingerprint_presets.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';

import 'ech_settings_card_test.dart' show host;

void main() {
  test('选项与原生模板清单一致，未知旧值回到自动，复制其他设置保留选择', () {
    final manifest = jsonDecode(
      File('core/net_core/presets/manifest.json').readAsStringSync(),
    ) as Map;
    expect(
      FingerprintPreset.values.map((p) => p.id).toSet(),
      (manifest['presets'] as List).map((p) => p['id']).toSet(),
    );
    expect(FingerprintPreset.normalize('missing'), FingerprintPreset.automatic);
    const settings = NetworkSettings(
      dohEnabled: false,
      selectedServerUrl: '',
      customServers: [],
      proxyPort: null,
      fingerprintPreset: 'ios-safari26',
    );
    expect(
      settings.copyWith(dohEnabled: true).fingerprintPreset,
      'ios-safari26',
    );
  });

  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    for (final dark in [false, true]) {
      testWidgets('模板选择可滚动并返回精确 ID：$size dark=$dark', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? result;
        await tester.pumpWidget(
          host(
            Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    builder: (_) =>
                        const FingerprintPresetDialog(selected: 'auto'),
                  );
                },
                child: const Text('open'),
              ),
            ),
            dark: dark,
            scale: 2,
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
        final last = find.text('Windows · Edge 154');
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(last);
        await tester.pumpAndSettle();
        expect(result, 'windows-edge154');
      });
    }
  }
  testWidgets('从指定档切回自动并返回 auto', (tester) async {
    String? result;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<String>(
                context: context,
                builder: (_) =>
                    const FingerprintPresetDialog(selected: 'ios-safari26'),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(FingerprintPresetDialog));
    await tester.tap(find.text(context.l10n.fingerprintPreset_auto));
    await tester.pumpAndSettle();
    expect(result, 'auto');
  });
}
