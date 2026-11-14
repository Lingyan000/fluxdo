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

  test('可见的浏览器栏吃掉自己那一侧，左右始终交给网页区域', () {
    const padding = EdgeInsets.fromLTRB(47, 44, 47, 21);
    expect(
      browserViewportUnsafeInsets(padding, topChrome: true, bottomChrome: true),
      const EdgeInsets.fromLTRB(47, 0, 47, 0),
    );
    expect(
      browserViewportUnsafeInsets(
        padding,
        topChrome: false,
        bottomChrome: false,
      ),
      padding,
    );
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
    addTearDown(BrowserSafeAreaPolicy.resetForTest);
    const cover = BrowserPageSafeArea(cover: true, env: EdgeInsets.zero);
    const plain = BrowserPageSafeArea(cover: false, env: EdgeInsets.zero);
    expect(BrowserSafeAreaPolicy.edgeToEdge(null), isFalse);
    expect(BrowserSafeAreaPolicy.edgeToEdge(plain), isFalse);
    expect(BrowserSafeAreaPolicy.edgeToEdge(cover), isTrue);
    BrowserSafeAreaPolicy.record(reliable: false);
    expect(BrowserSafeAreaPolicy.edgeToEdge(cover), isFalse);
  });
}
