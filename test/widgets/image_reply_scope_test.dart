import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/widgets/post/image_reply_scope.dart';
import 'package:fluxdo/widgets/post/quote_image_scope.dart';

void main() {
  final post = Post.fromJson({
    'id': 42,
    'post_number': 8,
    'username': 'user',
    'created_at': '2026-11-23T00:00:00Z',
    'updated_at': '2026-11-23T00:00:00Z',
  });

  testWidgets('图片编辑结果使用当前页面回调并回复打开图片时的楼层', (tester) async {
    ValueChanged<String>? reply;
    final received = <(String, Post)>[];
    final callbacks = <void Function(String, Post)>[
      (_, _) => fail('不能调用过期页面的回调'),
      (markdown, target) => received.add((markdown, target)),
    ];
    Future<void> pump(int handler) => tester.pumpWidget(
      QuoteImageScope(
        handler: callbacks[handler],
        child: ImageReplyScope(
          post: post,
          child: Builder(
            builder: (context) {
              reply ??= ImageReplyScope.resolve(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await pump(0);
    await pump(1);
    reply!('![edited](upload://example.png)');
    expect(received, [('![edited](upload://example.png)\n', post)]);
    await tester.pumpWidget(const SizedBox());
    reply!('不应发送');
    expect(received, hasLength(1));
  });

  testWidgets('当前页面不可回复时不回落到缓存中的回调', (tester) async {
    ValueChanged<String>? reply;
    await tester.pumpWidget(
      QuoteImageScope(
        handler: null,
        child: ImageReplyScope(
          post: post,
          fallbackHandler: (_, _) => fail('不可回复'),
          child: Builder(
            builder: (context) {
              reply = ImageReplyScope.resolve(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(reply, isNull);
  });
}
