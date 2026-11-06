@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/core/net_core_service.dart';

void main() {
  final skip = Platform.environment['FLUXDO_LIVE'] != '1'
      ? '需要本机核心，FLUXDO_LIVE=1'
      : false;
  test('手动档跨平台精确生效，恢复自动时重新按平台选择', () async {
    final core = NetCoreService.instance;
    try {
      for (final id in ['android-webview133', 'ios-safari26']) {
        expect(await core.start(NetCoreConfig(fingerprintPreset: id)), true);
        expect(core.status.templateMode, 'preset');
        expect(core.status.templatePreset, id);
      }
      expect(await core.start(const NetCoreConfig()), true);
      expect(core.status.templateMode, 'auto');
      expect(core.status.templatePreset, 'macos-safari26');
    } finally {
      await core.stop();
    }
  }, skip: skip);
  test('真实核心冷启动选择预置，同时保持真实采样待完成状态', () async {
    final core = NetCoreService.instance;
    try {
      expect(
        await core.start(
          const NetCoreConfig(
            fingerprintUserAgent:
                'Mozilla/5.0 AppleWebKit/605.1.15 Version/26.0 Safari/605.1.15',
          ),
        ),
        true,
      );
      expect(core.status.templateSource, 'builtin');
      expect(core.status.templatePreset, 'macos-safari26');
      expect(core.status.templateReady, false);
      expect(core.status.userAgent, isNull);
    } finally {
      await core.stop();
    }
  }, skip: skip);
}
