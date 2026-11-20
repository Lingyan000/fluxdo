import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/browser_safe_area.dart';

void main() {
  test('解析上报：非法结构丢弃，全透明或缺失底色为 null', () {
    expect(BrowserPageSafeArea.tryParse(null), isNull);
    expect(
      BrowserPageSafeArea.tryParse({
        'env': [0, 0, 0],
      }),
      isNull,
    );
    expect(
      BrowserPageSafeArea.tryParse({
        'env': [0, -1, 0, 0],
      }),
      isNull,
    );
    expect(
      BrowserPageSafeArea.tryParse({
        'cover': true,
        'env': [47, 0, 47.5, 21],
        'background': [18, 18, 18, 0.5],
        'canvas': [255, 255, 255, 1],
      }),
      const BrowserPageSafeArea(
        cover: true,
        env: EdgeInsets.fromLTRB(47, 0, 47.5, 21),
        background: Color(0xff121212),
        canvas: Color(0xffffffff),
      ),
    );
    expect(
      BrowserPageSafeArea.tryParse({
        'env': [0, 0, 0, 0],
        'background': null,
      })!.background,
      isNull,
    );
  });

  group('按实际网页边界计算安全区', () {
    const window = Rect.fromLTWH(0, 0, 390, 844);
    const padding = EdgeInsets.only(top: 44, bottom: 24);
    EdgeInsets measure(Rect viewport) => BrowserViewportGeometry(
      viewport: viewport,
      window: window,
      padding: padding,
    ).unsafe;

    test('上下栏、仅顶栏、仅底栏和全屏四种布局', () {
      expect(measure(const Rect.fromLTRB(0, 110, 390, 764)), EdgeInsets.zero);
      expect(
        measure(const Rect.fromLTRB(0, 0, 390, 764)),
        const EdgeInsets.only(top: 44),
      );
      expect(
        measure(const Rect.fromLTRB(0, 110, 390, 844)),
        const EdgeInsets.only(bottom: 24),
      );
      expect(measure(window), padding);
    });
    test('工具栏动画只交给网页剩余的遮挡，不按显隐二选一', () {
      expect(
        measure(const Rect.fromLTRB(0, 20, 390, 832)),
        const EdgeInsets.only(top: 24, bottom: 12),
      );
    });
    test('横屏刘海与浮动窗口使用同一坐标系', () {
      expect(
        const BrowserViewportGeometry(
          viewport: Rect.fromLTRB(120, 50, 924, 440),
          window: Rect.fromLTRB(100, 50, 944, 440),
          padding: EdgeInsets.only(left: 47, right: 47),
        ).unsafe,
        const EdgeInsets.only(left: 27, right: 27),
      );
    });
    test('空区域或窗口外不产生安全边距', () {
      expect(measure(Rect.zero), EdgeInsets.zero);
      expect(measure(const Rect.fromLTRB(400, 0, 500, 844)), EdgeInsets.zero);
    });
    test('隐藏系统栏后仍保留实际刘海区域', () {
      expect(
        const BrowserViewportGeometry(
          viewport: window,
          window: window,
          padding: EdgeInsets.only(top: 28),
        ).unsafe,
        const EdgeInsets.only(top: 28),
      );
    });
  });

  test('全零样本不证明可靠，但没有遮挡时的非零 env 必须识别', () {
    expect(
      BrowserSafeAreaPolicy.matches(EdgeInsets.zero, EdgeInsets.zero),
      isNull,
    );
    expect(
      BrowserSafeAreaPolicy.matches(
        EdgeInsets.zero,
        const EdgeInsets.only(top: 44, bottom: 24),
      ),
      isFalse,
    );
    const expected = EdgeInsets.fromLTRB(47, 0, 47, 0);
    expect(
      BrowserSafeAreaPolicy.matches(
        expected,
        const EdgeInsets.fromLTRB(47.5, 0, 46, 0),
      ),
      isTrue,
    );
    expect(BrowserSafeAreaPolicy.matches(expected, EdgeInsets.zero), isFalse);
  });

  test('只有声明 cover 且原生 env 未被证伪时才铺满', () {
    final policy = BrowserSafeAreaPolicy();
    const cover = BrowserPageSafeArea(cover: true, env: EdgeInsets.zero);
    const plain = BrowserPageSafeArea(cover: false, env: EdgeInsets.zero);
    expect(policy.edgeToEdge(null), isFalse);
    expect(policy.edgeToEdge(plain), isFalse);
    expect(policy.edgeToEdge(cover), isTrue);
    policy.record(reliable: false);
    expect(policy.edgeToEdge(cover), isFalse);
    expect(BrowserSafeAreaPolicy().edgeToEdge(cover), isTrue);
    policy.reset();
    expect(policy.edgeToEdge(cover), isTrue);
  });
}
