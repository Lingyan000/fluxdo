import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/network_settings_page/widgets/network_connection_overview.dart';

import 'ech_settings_card_test.dart' show host;

Widget overview({
  ConnectionPhase phase = ConnectionPhase.running,
  bool compatibility = false,
  bool viaCore = false,
  FutureOr<void> Function()? restart,
  ValueChanged<String>? configure,
  String? connectivity,
  bool failed = false,
}) => NetworkConnectionOverview(
  phase: phase,
  engine: phase == ConnectionPhase.fallback ? '应急路径（Dart IO）' : '网络核心',
  connectivitySummary: connectivity,
  connectivityFailed: failed,
  dns: phase == ConnectionPhase.fallback ? '系统 DNS' : '阿里云 · DoH',
  outbound: phase == ConnectionPhase.fallback ? '系统网络' : '直连',
  webViewOutbound: '应用代理',
  compatibility: compatibility,
  webViewViaCore: viaCore,
  templateName: '自动',
  templateDetail: '当前生效：浏览器采样缓存',
  onRestart: restart ?? () {},
  onTemplate: () => configure?.call('core'),
  onDns: () => configure?.call('dns'),
  onProxy: () => configure?.call('outbound'),
  onCompatibility: () => configure?.call('webview'),
);

void main() {
  testWidgets('请求失败与核心运行分别展示，重启仍可直接使用', (tester) async {
    var restarted = false;
    await tester.pumpWidget(
      host(
        overview(
          connectivity: 'forum.test 请求失败 · 12 次',
          failed: true,
          restart: () => restarted = true,
        ),
      ),
    );
    expect(find.text('网络核心运行中'), findsOneWidget);
    expect(find.text('forum.test 请求失败 · 12 次'), findsOneWidget);
    await tester.tap(find.byTooltip('重启网络核心'));
    await tester.pumpAndSettle();
    expect(restarted, isTrue);
    await tester.tap(find.byTooltip('切换普通展示'));
    await tester.pumpAndSettle();
    expect(find.text('forum.test 请求失败 · 12 次'), findsOneWidget);
  });
  testWidgets('重启期间保持图形高度、禁止连点并在完成后恢复', (tester) async {
    final completion = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      host(
        overview(
          restart: () {
            calls++;
            return completion.future;
          },
        ),
      ),
    );
    final before = tester.getSize(find.byType(NetworkConnectionOverview));
    await tester.tap(find.byTooltip('重启网络核心'));
    await tester.pump();
    expect(find.text('正在重启网络核心…'), findsOneWidget);
    expect(tester.getSize(find.byType(NetworkConnectionOverview)), before);
    await tester.tap(find.byTooltip('重启网络核心'));
    expect(calls, 1);
    completion.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('network-map-core')), findsOneWidget);
  });

  testWidgets('可切回普通列表且两种展示共用配置入口', (tester) async {
    final actions = <String>[];
    await tester.pumpWidget(host(overview(configure: actions.add)));
    await tester.tap(find.byTooltip('切换普通展示'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(4));
    await tester.tap(find.text('DNS / ECH'));
    expect(actions, ['dns']);
    await tester.tap(find.byTooltip('切换图形展示'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('network-map-core')), findsOneWidget);
  });

  testWidgets('四个图节点可点击且有辅助功能动作，重启直接可用', (tester) async {
    final actions = <String>[];
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      host(
        overview(configure: actions.add, restart: () => actions.add('restart')),
      ),
    );
    for (final name in ['core', 'dns', 'outbound', 'webview']) {
      await tester.tap(find.byKey(ValueKey('network-map-$name')));
      await tester.pump();
    }
    await tester.tap(find.byTooltip('重启网络核心'));
    expect(actions, ['core', 'dns', 'outbound', 'webview', 'restart']);
    expect(find.bySemanticsLabel('网络核心，自动'), findsOneWidget);
    expect(find.text('DNS / ECH'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('兼容分流与独立出口随快照更新', (tester) async {
    var compatibility = false;
    var viaCore = false;
    late StateSetter update;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return overview(compatibility: compatibility, viaCore: viaCore);
          },
        ),
      ),
    );
    expect(find.text('已关闭'), findsOneWidget);
    update(() => compatibility = true);
    await tester.pumpAndSettle();
    expect(find.text('系统网络'), findsOneWidget);
    update(() => viaCore = true);
    await tester.pumpAndSettle();
    expect(find.text('WebView 经核心'), findsOneWidget);
    expect(find.text('系统网络'), findsNothing);
  });

  testWidgets('设置应用中不展示未生效路径且禁用重启', (tester) async {
    await tester.pumpWidget(host(overview(phase: ConnectionPhase.applying)));
    expect(find.text('阿里云 · DoH'), findsNothing);
    expect(find.byKey(const ValueKey('network-map-dns')), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == '重启网络核心',
            ),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('备用连接与 WebView 核心出口独立展示', (tester) async {
    await tester.pumpWidget(
      host(
        overview(
          phase: ConnectionPhase.fallback,
          compatibility: true,
          viaCore: true,
        ),
      ),
    );
    expect(find.text('正在使用备用连接'), findsOneWidget);
    expect(find.text('系统网络'), findsOneWidget);
    expect(find.text('应用代理'), findsNothing);
    expect(find.text('论坛'), findsNothing);
    expect(find.text('CDN 图片'), findsNothing);
    expect(find.text('应急路径（Dart IO）'), findsOneWidget);
  });

  for (final size in [
    const Size(375, 812),
    const Size(812, 375),
    const Size(768, 1024),
  ]) {
    for (final dark in [false, true]) {
      testWidgets('窄屏/横屏/平板大字体无溢出 $size dark=$dark', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          host(
            SingleChildScrollView(
              child: overview(
                compatibility: true,
                viaCore: true,
                connectivity: 'very-long-image-host.example.com 请求失败 · 12 次',
                failed: true,
              ),
            ),
            dark: dark,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('network-map-outbound')),
        );
        expect(tester.takeException(), isNull);
        expect(tester.binding.transientCallbackCount, 0);
      });
    }
  }
}
