import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/toast_service.dart';

/// 入场 560ms、退场 300ms，多给一点余量
const _enter = Duration(milliseconds: 700);
const _exit = Duration(milliseconds: 400);

Future<void> _pumpHost(WidgetTester tester, {bool glass = true}) {
  return tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      builder: (context, child) => GlassSettingsScope(
        settings: GlassSettings(enabled: glass),
        child: child!,
      ),
      home: const Scaffold(body: SizedBox.expand()),
    ),
  );
}

void main() {
  testWidgets('普通 Toast 展开后按时长自动收起', (tester) async {
    await _pumpHost(tester);

    ToastService.showSuccess('已复制到剪贴板');
    await tester.pump();
    await tester.pump(_enter);
    expect(find.text('已复制到剪贴板'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(_exit);
    expect(find.text('已复制到剪贴板'), findsNothing);
  });

  testWidgets('新 Toast 直接替换旧 Toast', (tester) async {
    await _pumpHost(tester);

    ToastService.showInfo('第一条');
    await tester.pump();
    ToastService.showError('第二条');
    await tester.pump();
    await tester.pump(_enter);
    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(_exit);
  });

  testWidgets('下载完成在原位变成带操作的成功提示', (tester) async {
    await _pumpHost(tester);

    final handle = ToastService.showDownload('FluxDO.apk');
    await tester.pump();
    await tester.pump(_enter);
    handle.updateProgress(0.5);
    await tester.pump();
    expect(find.text('FluxDO.apk'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);

    // 下载进行中：普通提示不再被丢弃，而是排在进度胶囊下方让位
    ToastService.showInfo('下载时也能看到');
    await tester.pump();
    await tester.pump(_enter);
    final progressTop = tester.getTopLeft(
      find.ancestor(
        of: find.text('FluxDO.apk'),
        matching: find.byType(GlassSurfaceFrame),
      ),
    ).dy;
    final noticeTop = tester.getTopLeft(
      find.ancestor(
        of: find.text('下载时也能看到'),
        matching: find.byType(GlassSurfaceFrame),
      ),
    ).dy;
    expect(noticeTop, greaterThan(progressTop + 40));

    // 让它按自己的时长消失，后面的断言只针对下载胶囊
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(_exit);
    expect(find.text('下载时也能看到'), findsNothing);

    final overlayChild = find.ancestor(
      of: find.text('FluxDO.apk'),
      matching: find.byType(GlassSurfaceFrame),
    );
    final frameBefore = tester.element(overlayChild);

    var viewed = false;
    handle.complete(
      '下载完成',
      duration: const Duration(seconds: 5),
      actionLabel: '查看',
      onAction: () => viewed = true,
    );
    await tester.pump();
    await tester.pump(_enter);
    expect(handle.isActive, isFalse);
    expect(find.text('FluxDO.apk'), findsNothing);
    expect(find.text('50%'), findsNothing);
    expect(find.text('下载完成'), findsOneWidget);
    // 同一个外壳元素：原位变身而不是重新弹出
    expect(
      tester.element(
        find.ancestor(
          of: find.text('下载完成'),
          matching: find.byType(GlassSurfaceFrame),
        ),
      ),
      same(frameBefore),
    );

    await tester.tap(find.text('查看'));
    await tester.pump();
    await tester.pump(_exit);
    expect(viewed, isTrue);
    expect(find.text('下载完成'), findsNothing);

    // 完成后普通 Toast 恢复可用
    ToastService.showInfo('可以显示了');
    await tester.pump();
    expect(find.text('可以显示了'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(_exit);
  });

  testWidgets('下载 Toast 被关闭后 complete 退化为新的成功提示', (tester) async {
    await _pumpHost(tester);

    final handle = ToastService.showDownload('a.zip');
    await tester.pump();
    handle.dismiss();
    await tester.pump(_exit);
    expect(find.text('a.zip'), findsNothing);

    handle.complete('同步成功');
    await tester.pump();
    await tester.pump(_enter);
    expect(find.text('同步成功'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(_exit);
  });

  testWidgets('玻璃开关决定是否模糊背景', (tester) async {
    await _pumpHost(tester, glass: false);
    ToastService.showSuccess('实色');
    await tester.pump();
    await tester.pump(_enter);
    expect(find.text('实色'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(_exit);

    await _pumpHost(tester);
    ToastService.showSuccess('玻璃');
    await tester.pump();
    await tester.pump(_enter);
    expect(find.byType(BackdropFilter), findsWidgets);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(_exit);
  });

  testWidgets('进度胶囊退场时插入新提示，排在下方且不重叠', (tester) async {
    await _pumpHost(tester);

    final handle = ToastService.showDownload('a.apk');
    await tester.pump();
    await tester.pump(_enter);
    expect(find.byType(GlassSurfaceFrame), findsOneWidget);

    handle.dismiss();
    ToastService.showError('下载失败');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 退场中的进度胶囊还在，新提示排在它下面 —— 重叠在同一位置才是 bug
    final leavingTop = tester.getTopLeft(
      find.ancestor(
        of: find.text('a.apk'),
        matching: find.byType(GlassSurfaceFrame),
      ),
    ).dy;
    final arrivingTop = tester.getTopLeft(
      find.ancestor(
        of: find.text('下载失败'),
        matching: find.byType(GlassSurfaceFrame),
      ),
    ).dy;
    expect(arrivingTop, greaterThan(leavingTop + 40));

    // 退场结束：只剩新提示，并且升回顶部
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widgetList(find.byType(GlassSurfaceFrame)).length, 1);
    expect(find.text('a.apk'), findsNothing);
    final settledTop = tester.getTopLeft(
      find.ancestor(
        of: find.text('下载失败'),
        matching: find.byType(GlassSurfaceFrame),
      ),
    ).dy;
    expect(settledTop, lessThan(arrivingTop));

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(_exit);
    expect(find.text('下载失败'), findsNothing);
  });

  testWidgets('失败时进度 Toast 原位变成错误提示', (tester) async {
    await _pumpHost(tester);

    final handle = ToastService.showDownload('a.apk');
    await tester.pump();
    await tester.pump(_enter);
    final surface = tester.element(
      find.ancestor(
        of: find.text('a.apk'),
        matching: find.byType(GlassSurfaceFrame),
      ),
    );

    handle.complete('下载失败', type: ToastType.error);
    await tester.pump();
    await tester.pump(_enter);
    expect(handle.isActive, isFalse);
    expect(find.text('a.apk'), findsNothing);
    expect(find.text('下载失败'), findsOneWidget);
    // 同一个外壳元素：原位变色而不是重新弹出
    expect(
      tester.element(
        find.ancestor(
          of: find.text('下载失败'),
          matching: find.byType(GlassSurfaceFrame),
        ),
      ),
      same(surface),
    );

    // 错误提示默认 5s，3s 时还在
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(_exit);
    expect(find.text('下载失败'), findsNothing);
  });

  testWidgets('退场未完成时整棵树被替换，不会打到已释放的控制器', (tester) async {
    await _pumpHost(tester);

    final handle = ToastService.showDownload('a.apk');
    await tester.pump();
    await tester.pump(_enter);
    handle.dismiss();
    await tester.pump(const Duration(milliseconds: 100)); // 倒放进行中

    // 模拟上层整体替换 widget 树（例如登出、切换 navigator）
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(GlassSurfaceFrame), findsNothing);

    // 残留状态要能自愈：换回正常树后，新 Toast 仍可用
    await _pumpHost(tester);
    ToastService.showInfo('之后仍可用');
    await tester.pump();
    await tester.pump(_enter);
    expect(find.text('之后仍可用'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(_exit);
  });

  testWidgets('下载中普通提示下移让位，下载结束后升回原位', (tester) async {
    await _pumpHost(tester);

    final handle = ToastService.showDownload('a.apk');
    await tester.pump();
    await tester.pump(_enter);

    ToastService.showInfo('下载中的提示');
    await tester.pump();
    await tester.pump(_enter);
    expect(tester.widgetList(find.byType(GlassSurfaceFrame)).length, 2);
    final stackedTop = tester.getTopLeft(
      find.ancestor(
        of: find.text('下载中的提示'),
        matching: find.byType(GlassSurfaceFrame),
      ),
    ).dy;

    handle.dismiss();
    await tester.pump();
    await tester.pump(_exit); // 胶囊退场
    await tester.pump(const Duration(milliseconds: 400)); // 让位动画走完
    expect(tester.widgetList(find.byType(GlassSurfaceFrame)).length, 1);
    final liftedTop = tester.getTopLeft(
      find.ancestor(
        of: find.text('下载中的提示'),
        matching: find.byType(GlassSurfaceFrame),
      ),
    ).dy;
    expect(liftedTop, lessThan(stackedTop));

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(_exit);
  });

  testWidgets('下载中连续两条提示只保留最后一条', (tester) async {
    await _pumpHost(tester);

    final handle = ToastService.showDownload('a.apk');
    await tester.pump();
    await tester.pump(_enter);

    ToastService.showInfo('第一条提示');
    await tester.pump();
    ToastService.showSuccess('第二条提示');
    await tester.pump();
    await tester.pump(_enter);
    expect(find.text('第一条提示'), findsNothing);
    expect(find.text('第二条提示'), findsOneWidget);
    expect(tester.widgetList(find.byType(GlassSurfaceFrame)).length, 2);

    handle.dismiss();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(_exit);
  });

  testWidgets('重复触发同一提示只重置计时，不重播入场', (tester) async {
    await _pumpHost(tester);

    ToastService.showSuccess('已复制到剪贴板');
    await tester.pump();
    await tester.pump(_enter);
    final before = tester.element(
      find.ancestor(
        of: find.text('已复制到剪贴板'),
        matching: find.byType(GlassSurfaceFrame),
      ),
    );

    await tester.pump(const Duration(milliseconds: 1500));
    ToastService.showSuccess('已复制到剪贴板');
    await tester.pump();
    // 还是同一个外壳：没有从头展开
    expect(
      tester.element(
        find.ancestor(
          of: find.text('已复制到剪贴板'),
          matching: find.byType(GlassSurfaceFrame),
        ),
      ),
      same(before),
    );

    // 计时被重置：累计 3.1s（原本 3s 就该消失）时还在
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.text('已复制到剪贴板'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(_exit);
    expect(find.text('已复制到剪贴板'), findsNothing);
  });

  testWidgets('错误提示默认停留 5s', (tester) async {
    await _pumpHost(tester);

    ToastService.showError('下载失败');
    await tester.pump();
    await tester.pump(_enter);

    await tester.pump(const Duration(milliseconds: 3500));
    expect(find.text('下载失败'), findsOneWidget); // 3s 时不该消失

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(_exit);
    expect(find.text('下载失败'), findsNothing);
  });

  testWidgets('先有普通提示再开始下载，提示下移让位且下载照常', (tester) async {
    await _pumpHost(tester);

    ToastService.showInfo('先来的提示');
    await tester.pump();
    await tester.pump(_enter);

    // 下载开始时，已有的提示挪到下方让位，而不是被收掉
    final handle = ToastService.showDownload('a.apk');
    await tester.pump();
    await tester.pump(_enter);
    expect(find.text('先来的提示'), findsOneWidget);
    expect(tester.widgetList(find.byType(GlassSurfaceFrame)).length, 2);
    final noticeTop = tester.getTopLeft(
      find.ancestor(
        of: find.text('先来的提示'),
        matching: find.byType(GlassSurfaceFrame),
      ),
    ).dy;
    final progressTop = tester.getTopLeft(
      find.ancestor(
        of: find.text('a.apk'),
        matching: find.byType(GlassSurfaceFrame),
      ),
    ).dy;
    expect(noticeTop, greaterThan(progressTop + 40));

    // 进度照常更新
    handle.updateProgress(0.4);
    await tester.pump();
    expect(find.text('40%'), findsOneWidget);

    // 下载结束：提示升回顶部
    handle.dismiss();
    await tester.pump();
    await tester.pump(_exit);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widgetList(find.byType(GlassSurfaceFrame)).length, 1);
    final liftedTop = tester.getTopLeft(
      find.ancestor(
        of: find.text('先来的提示'),
        matching: find.byType(GlassSurfaceFrame),
      ),
    ).dy;
    expect(liftedTop, lessThan(noticeTop));

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(_exit);
  });
}
