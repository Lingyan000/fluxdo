/// 聊天气泡布局回归 —— 锁住「消息肉眼不可见」的根因。
///
/// 气泡曾用 `IntrinsicWidth` 求「按内容自适应宽度」，而正文渲染子树里图片 /
/// iframe / 视频等 builder 内部有 `LayoutBuilder`，不支持 dry layout 与内在
/// 尺寸；纯文本路径也会因段落布局缓存的宽度桶被喂 infinity 而抛异常。任一条
/// 触发，整条消息布局失败 → 气泡一个像素都画不出来。
///
/// 正确姿势：整条链路都不横向拉伸（Column 非 stretch + `stretchBlocks: false`），
/// 由 `maxWidth` 约束负责换行。本测试复刻 `_ChatMessageBubble` 的布局骨架
/// （该类是私有的），覆盖主项目 callbacks 注入的真实 builder。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/fluxdo_render_callbacks.dart';

const double _screenWidth = 400;
const double _maxBubbleWidth = _screenWidth * 0.75;

/// 复刻气泡骨架：Row(min) → Container(maxWidth) → Column(start) → 装饰 Container。
Widget bubble(String cooked) {
  return MaterialApp(
    home: Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Scaffold(
          body: ListView(
            reverse: true,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    key: const ValueKey('bubble'),
                    constraints: const BoxConstraints(
                      maxWidth: _maxBubbleWidth,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FluxdoRenderCallbacks.generic(
                                heroTagNamespace: 'chat_msg_1',
                              ).render(
                                cookedHtml: cooked,
                                baseTextStyle:
                                    theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurface,
                                ),
                                selectionEnabled: true,
                                compact: true,
                                trimTopMargin: true,
                                trimBottomMargin: true,
                                stretchBlocks: false,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// 渲染一条消息，返回 (气泡尺寸, 捕获到的异常)。
Future<(Size?, Object?)> render(WidgetTester tester, String cooked) async {
  tester.view.physicalSize = const Size(_screenWidth * 3, 800 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  Object? caught;
  final prev = FlutterError.onError;
  FlutterError.onError = (details) => caught ??= details.exception;
  await tester.pumpWidget(bubble(cooked));
  await tester.pump(const Duration(milliseconds: 50));
  FlutterError.onError = prev;

  Size? size;
  try {
    size = tester.getSize(find.byKey(const ValueKey('bubble')));
  } catch (e) {
    caught ??= e;
  }
  return (size, caught);
}

void main() {
  // 覆盖 Discourse chat cooked 的典型形态；图片 / onebox 走主项目 builder
  // （内部含 LayoutBuilder），是原崩溃链路里最脆的一环。
  const cases = <String, String>{
    '纯文本': '<p>hello</p>',
    '中文长文本':
        '<p>这是一条相当长的聊天消息，长到必须在气泡的最大宽度处换行才能放下。</p>',
    'mention': '<p><a class="mention" href="/u/steve">@steve</a> 在吗</p>',
    'emoji':
        '<p>hi <img src="/images/emoji/twitter/tada.png?v=12" '
        'title=":tada:" class="emoji" alt=":tada:" width="20" height="20"></p>',
    '图片':
        '<p><img src="https://example.com/uploads/a.png" alt="a" '
        'width="690" height="388"></p>',
    '代码块':
        '<pre data-code-wrap="ruby"><code class="lang-ruby">puts 1\n</code></pre>',
    '引用':
        '<aside class="quote no-group" data-username="a">'
        '<blockquote><p>被引用的内容</p></blockquote></aside>',
  };

  cases.forEach((name, cooked) {
    testWidgets('$name：气泡有可见尺寸且不抛布局异常', (tester) async {
      final (size, err) = await render(tester, cooked);
      expect(err, isNull, reason: '布局异常会让整条消息画不出来');
      expect(size, isNotNull);
      expect(size!.width, greaterThan(0));
      expect(size.height, greaterThan(0));
      expect(size.width, lessThanOrEqualTo(_maxBubbleWidth));
    });
  });

  testWidgets('短消息气泡按内容收缩，不撑满最大宽度', (tester) async {
    final (size, err) = await render(tester, '<p>hi</p>');
    expect(err, isNull);
    expect(size!.width, lessThan(_maxBubbleWidth));
  });

  testWidgets('长消息气泡在最大宽度处换行', (tester) async {
    final (short, _) = await render(tester, '<p>hi</p>');
    final (long, err) = await render(
      tester,
      '<p>这是一条相当长的聊天消息，长到必须在气泡的最大宽度处换行才能放下。</p>',
    );
    expect(err, isNull);
    expect(long!.width, greaterThan(short!.width));
    expect(long.width, lessThanOrEqualTo(_maxBubbleWidth));
    expect(long.height, greaterThan(short.height));
  });
}
