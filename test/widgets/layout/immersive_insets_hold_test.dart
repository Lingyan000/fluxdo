import 'package:fluxdo/widgets/layout/immersive_insets_hold.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const size = Size(400, 800);
  const normal = EdgeInsets.only(top: 24, bottom: 34);

  MediaQueryData mediaWith(EdgeInsets viewPadding, {Size s = size}) =>
      MediaQueryData(size: s, viewPadding: viewPadding, padding: viewPadding);

  late ValueNotifier<MediaQueryData> outer;
  late MediaQueryData seen;

  Future<void> pumpScope(WidgetTester tester) async {
    outer = ValueNotifier(mediaWith(normal));
    await tester.pumpWidget(
      ValueListenableBuilder<MediaQueryData>(
        valueListenable: outer,
        builder: (context, data, _) => MediaQuery(
          data: data,
          child: ImmersiveInsetsHoldScope(
            child: Builder(
              builder: (context) {
                seen = MediaQuery.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('沉浸期间与恢复过渡期保持原安全区,真实值回来后解除', (tester) async {
    await pumpScope(tester);
    ImmersiveInsetsHold.begin(outer.value);

    outer.value = mediaWith(EdgeInsets.zero);
    await tester.pump();
    expect(seen.viewPadding, normal);
    expect(seen.padding, normal);

    // 恢复已发起,系统栏还没回来
    ImmersiveInsetsHold.release();
    await tester.pump();
    expect(seen.viewPadding, normal);

    outer.value = mediaWith(normal);
    await tester.pump();
    await tester.pump();
    expect(seen.viewPadding, normal);

    // 已解除:之后真实变小不再顶替
    outer.value = mediaWith(const EdgeInsets.only(bottom: 10));
    await tester.pump();
    expect(seen.viewPadding, const EdgeInsets.only(bottom: 10));
  });

  testWidgets('系统栏迟迟不回来时超时解除', (tester) async {
    await pumpScope(tester);
    ImmersiveInsetsHold.begin(outer.value);
    outer.value = mediaWith(EdgeInsets.zero);
    ImmersiveInsetsHold.release();
    await tester.pump();
    expect(seen.viewPadding, normal);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(seen.viewPadding, EdgeInsets.zero);
  });

  testWidgets('窗口尺寸变化时不顶替', (tester) async {
    await pumpScope(tester);
    ImmersiveInsetsHold.begin(outer.value);
    outer.value = mediaWith(EdgeInsets.zero, s: const Size(800, 400));
    await tester.pump();
    expect(seen.viewPadding, EdgeInsets.zero);
    await tester.pump();
  });

  testWidgets('键盘弹起时 padding 扣除 viewInsets', (tester) async {
    await pumpScope(tester);
    ImmersiveInsetsHold.begin(outer.value);
    outer.value = const MediaQueryData(
      size: size,
      viewInsets: EdgeInsets.only(bottom: 300),
    );
    await tester.pump();
    expect(seen.viewPadding, normal);
    expect(seen.padding, const EdgeInsets.only(top: 24));
    ImmersiveInsetsHold.release();
    await tester.pump(const Duration(seconds: 1));
  });
}
