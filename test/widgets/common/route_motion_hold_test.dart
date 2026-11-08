import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/layout/pane_filmstrip.dart';

typedef _Data = ({String identity, int value});

class _List extends StatefulWidget {
  const _List(this.data);
  final _Data data;
  @override
  State<_List> createState() => _ListState();
}

class _ListState extends State<_List> with RouteMotionHoldMixin<_List, int> {
  @override
  Widget build(BuildContext context) => Text(
    'shown ${holdDuringRouteMotion(widget.data.value, identity: widget.data.identity)}',
  );
}

Widget _list(ValueNotifier<_Data> data) => ValueListenableBuilder<_Data>(
  valueListenable: data,
  builder: (_, value, _) => _List(value),
);

void main() {
  late ValueNotifier<_Data> data;
  late GlobalKey<NavigatorState> navigator;
  setUp(() {
    data = ValueNotifier((identity: 'account/query', value: 1));
    navigator = GlobalKey<NavigatorState>();
  });
  tearDown(() => data.dispose());

  Widget app() => MaterialApp(
    navigatorKey: navigator,
    home: Scaffold(body: _list(data)),
  );

  PageRoute<void> cover() =>
      MaterialPageRoute<void>(builder: (_) => const Scaffold());

  testWidgets('push/pop 期间保持列表，结束只展示最新结果', (tester) async {
    await tester.pumpWidget(app());
    navigator.currentState!.push(cover());
    await tester.pump();
    data.value = (identity: 'account/query', value: 2);
    await tester.pump(const Duration(milliseconds: 100));
    data.value = (identity: 'account/query', value: 3);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('shown 1'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('shown 3', skipOffstage: false), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pump();
    data.value = (identity: 'account/query', value: 4);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('shown 3'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('shown 4'), findsOneWidget);
  });

  testWidgets('返回手势暂停时仍保留，取消后立即释放', (tester) async {
    await tester.pumpWidget(app());
    navigator.currentState!.didStartUserGesture();
    data.value = (identity: 'account/query', value: 2);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('shown 1'), findsOneWidget);
    navigator.currentState!.didStopUserGesture();
    await tester.pumpAndSettle();
    expect(find.text('shown 2'), findsOneWidget);
  });

  testWidgets('转场中切换账号/查询立即丢弃旧值', (tester) async {
    await tester.pumpWidget(app());
    navigator.currentState!.push(cover());
    await tester.pump();
    data.value = (identity: 'other account/query', value: 99);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('shown 99'), findsOneWidget);
    data.value = (identity: 'other account/query', value: 100);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('shown 99'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('shown 100', skipOffstage: false), findsOneWidget);
  });

  testWidgets('pane 转场和预测返回拖动共用暂停信号', (tester) async {
    final panes = ValueNotifier<List<Widget>>([]);
    final drag = ValueNotifier(0.0);
    addTearDown(panes.dispose);
    addTearDown(drag.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<List<Widget>>(
            valueListenable: panes,
            builder: (_, value, _) => PaneFilmstrip(
              master: _list(data),
              panes: value,
              masterWidth: 300,
              viewportPanes: 2,
              bandDrag: drag,
            ),
          ),
        ),
      ),
    );
    panes.value = [const Text('detail', key: ValueKey('detail'))];
    await tester.pump();
    data.value = (identity: 'account/query', value: 2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('shown 1'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('shown 2'), findsOneWidget);
    drag.value = 0.5;
    await tester.pump();
    data.value = (identity: 'account/query', value: 3);
    await tester.pump();
    expect(find.text('shown 2'), findsOneWidget);
    drag.value = 0;
    await tester.pumpAndSettle();
    expect(find.text('shown 3'), findsOneWidget);
  });

  testWidgets('销毁待释放的页面不再触发 setState', (tester) async {
    await tester.pumpWidget(app());
    navigator.currentState!.didStartUserGesture();
    data.value = (identity: 'account/query', value: 2);
    await tester.pump();
    navigator.currentState!.didStopUserGesture();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('新页面进场期间暂存到达的数据', (tester) async {
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Scaffold()),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => Scaffold(body: _list(data))),
    );
    await tester.pump();
    data.value = (identity: 'account/query', value: 2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('shown 1'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('shown 2'), findsOneWidget);
  });

  testWidgets('嵌套 Navigator 内的列表也等待外层路由转场', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => Scaffold(body: _list(data)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push(cover());
    await tester.pump();
    data.value = (identity: 'account/query', value: 2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('shown 1'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('shown 2', skipOffstage: false), findsOneWidget);
  });

  testWidgets('内层 pane 静止时仍等待外层 pane 动画', (tester) async {
    final outerMoving = ValueNotifier(false);
    addTearDown(outerMoving.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: outerMoving,
          builder: (_, moving, child) =>
              PageMotionScope(moving: moving, child: child!),
          child: PageMotionScope(moving: false, child: _list(data)),
        ),
      ),
    );
    outerMoving.value = true;
    await tester.pump();
    data.value = (identity: 'account/query', value: 2);
    await tester.pump();
    expect(find.text('shown 1'), findsOneWidget);
    outerMoving.value = false;
    await tester.pumpAndSettle();
    expect(find.text('shown 2'), findsOneWidget);
  });

  testWidgets('Android 预测返回取消后释放最新值', (tester) async {
    Future<void> send(String method, [double? progress]) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(
              method,
              progress == null
                  ? null
                  : {
                      'touchOffset': <double>[10, 300],
                      'progress': progress,
                      'swipeEdge': 0,
                    },
            ),
          ),
          (_) {},
        );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android:
                  PredictiveBackCupertinoPageTransitionsBuilder(),
            },
          ),
        ),
        home: const Scaffold(),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => Scaffold(body: _list(data))),
    );
    await tester.pumpAndSettle();
    await send('startBackGesture', 0);
    await send('updateBackGestureProgress', 0.5);
    await tester.pump();
    data.value = (identity: 'account/query', value: 2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('shown 1'), findsOneWidget);
    await send('cancelBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('shown 2'), findsOneWidget);
    expect(navigator.currentState!.userGestureInProgress, isFalse);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
