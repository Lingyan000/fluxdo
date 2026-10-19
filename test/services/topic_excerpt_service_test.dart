import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/topic_excerpt_service.dart';

class _Discourse extends Fake implements DiscourseService {
  int calls = 0;
  Future<String?> Function(int)? loader;

  @override
  Future<String?> getTopicFirstPostCooked(int id) {
    calls++;
    return loader?.call(id) ??
        Future.value('<p>完整首楼内容</p><img src="/uploads/photo.jpg">');
  }
}

void main() {
  final excerpts = TopicExcerptService();
  late _Discourse api;
  setUp(() {
    excerpts.clear();
    api = _Discourse();
  });

  test('隐藏文字、隐藏图片及嵌套引用不会出现在摘要里', () {
    const cooked =
        '<p>可见正文 &amp; &#x1F600;</p>'
        '<span class="spoiler">隐藏答案</span>'
        '<div class="spoiler"><p>隐藏段落</p>'
        '<img src="/uploads/hidden.jpg"></div>'
        '<aside class="quote"><div>引用<aside class="quote">嵌套引用</aside>'
        '</div><img src="/uploads/quoted.jpg"></aside>'
        '<p>尾段</p><img src="/uploads/visible.jpg">';
    final text = TopicExcerptService.cleanExcerpt(cooked);
    expect(text, contains('可见正文 & 😀'));
    expect(text, contains('尾段'));
    expect(text, isNot(contains('隐藏')));
    expect(text, isNot(contains('引用')));
    final images = TopicExcerptService.extractImages(cooked);
    expect(images, hasLength(1));
    expect(images.single, endsWith('/uploads/visible.jpg'));
  });

  test('图片过滤不受属性顺序、引号、多个 class 和 SVG 参数影响', () {
    const cooked =
        '<img src="/uploads/custom.png" class="emoji extra">'
        "<img src='/uploads/avatar.png' class='avatar'>"
        '<img class="site-icon extra" src="/uploads/icon.png">'
        '<img src="/uploads/logo.SVG?v=1">'
        '<img src="/uploads/photo.jpg">'
        '<img src="/uploads/photo.jpg">';
    final images = TopicExcerptService.extractImages(cooked);
    expect(images, hasLength(1));
    expect(images.single, endsWith('/uploads/photo.jpg'));
  });

  test('未授权补充请求时，有无列表摘要都不会调用接口', () async {
    expect(await excerpts.getOrFetchExcerpt(1, service: api), isNull);
    final fallback = await excerpts.getOrFetchExcerpt(
      2,
      fallbackRaw: '列表摘要',
      service: api,
    );
    expect(fallback?.text, '列表摘要');
    expect(api.calls, 0);
  });

  test('列表首图无需额外请求即可显示', () async {
    final data = await excerpts.getOrFetchExcerpt(
      1,
      fallbackImageUrl: '/uploads/cover.jpg',
      service: api,
    );
    expect(data?.text, isEmpty);
    expect(data?.imageUrls.single, endsWith('/uploads/cover.jpg'));
    expect(api.calls, 0);
  });

  test('额外请求用完整正文和多图替换列表摘要与单图', () async {
    api.loader = (_) async => '<p>完整正文</p><img src="/uploads/first.jpg"><img src="/uploads/second.jpg">';
    final data = await excerpts.getOrFetchExcerpt(
      1,
      fallbackRaw: '短摘要',
      fallbackImageUrl: '/uploads/cover.jpg',
      service: api,
      allowFetch: true,
    );
    expect(data?.text, '完整正文');
    expect(data?.imageUrls.map((url) => Uri.parse(url).path), [
      '/uploads/first.jpg',
      '/uploads/second.jpg',
    ]);
    expect(api.calls, 1);
    expect(
      excerpts.getCached(1, fallbackImageUrl: '/uploads/cover.jpg')?.imageUrls,
      data?.imageUrls,
    );
  });

  test('额外请求失败保留列表摘要与单图', () async {
    api.loader = (_) => Future.error(StateError('offline'));
    final data = await excerpts.getOrFetchExcerpt(
      1,
      fallbackRaw: '短摘要',
      fallbackImageUrl: '/uploads/cover.jpg',
      service: api,
      allowFetch: true,
    );
    expect(data?.text, '短摘要');
    expect(data?.imageUrls.single, endsWith('/uploads/cover.jpg'));
  });

  test('显式开启后短摘要可以补齐正文和图片，并复用完整缓存', () async {
    expect(excerpts.getCached(1, fallbackRaw: '短摘要')?.text, '短摘要');
    final data = await excerpts.getOrFetchExcerpt(
      1,
      fallbackRaw: '短摘要',
      service: api,
      allowFetch: true,
    );
    expect(data?.text, '完整首楼内容');
    expect(data?.imageUrls, hasLength(1));
    await excerpts.getOrFetchExcerpt(1, service: api, allowFetch: true);
    expect(api.calls, 1);
  });

  test('列表摘要变化不会被旧的短摘要缓存覆盖', () {
    excerpts.getCached(1, fallbackRaw: '旧摘要');
    expect(excerpts.getCached(1, fallbackRaw: '新摘要')?.text, '新摘要');
  });

  test('请求失败时保留列表摘要，冷却期内不重复请求', () async {
    api.loader = (_) => Future.error(StateError('offline'));
    for (var i = 0; i < 2; i++) {
      final data = await excerpts.getOrFetchExcerpt(
        1,
        fallbackRaw: '可读的列表摘要',
        service: api,
        allowFetch: true,
      );
      expect(data?.text, '可读的列表摘要');
    }
    expect(api.calls, 1);
  });

  test('同一话题的在途请求去重', () async {
    final loaded = Completer<String?>();
    api.loader = (_) => loaded.future;
    final first = excerpts.getOrFetchExcerpt(1, service: api, allowFetch: true);
    final second = excerpts.getOrFetchExcerpt(
      1,
      service: api,
      allowFetch: true,
    );
    expect(api.calls, 1);
    loaded.complete('<p>正文</p>');
    final result = await Future.wait([first, second]);
    expect(result.map((data) => data?.text), ['正文', '正文']);
  });

  test('补充首楼请求最多同时执行四个', () async {
    final pending = <int, Completer<String?>>{};
    var running = 0;
    var peak = 0;
    api.loader = (id) async {
      running++;
      if (running > peak) peak = running;
      final loaded = pending[id] = Completer<String?>();
      try {
        return await loaded.future;
      } finally {
        running--;
      }
    };
    final requests = [
      for (var id = 0; id < 6; id++)
        excerpts.getOrFetchExcerpt(id, service: api, allowFetch: true),
    ];
    expect(api.calls, 4);
    for (var id = 0; id < 6; id++) {
      pending[id]!.complete('<p>正文 $id</p>');
      await Future<void>.delayed(Duration.zero);
    }
    await Future.wait(requests);
    expect(api.calls, 6);
    expect(peak, 4);
  });
}
