import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/blob_image_cache.dart';

void main() {
  // 与 Telegram ImageLoader.getHttpUrlExtension 同款的规则:
  // 取最后一段路径里最后一个 '.' 的后缀;为空、长度 >4 或含非字母数字
  // 时回退默认值。缓存文件名靠它带扩展名,系统分享/保存才能按后缀定型。
  group('BlobImageCache.httpUrlExtension', () {
    test('常规图片 URL 提取扩展名并小写化', () {
      expect(
        BlobImageCache.httpUrlExtension(
          'https://example.com/uploads/a/b/Photo.JPEG',
        ),
        'jpeg',
      );
      expect(
        BlobImageCache.httpUrlExtension('https://example.com/x/y.gif'),
        'gif',
      );
      expect(
        BlobImageCache.httpUrlExtension('https://example.com/x/y.webp'),
        'webp',
      );
    });

    test('query / fragment 不影响提取', () {
      expect(
        BlobImageCache.httpUrlExtension(
          'https://example.com/a/b.png?v=123&w=100#frag',
        ),
        'png',
      );
    });

    test('最后一段无点时回退默认 jpg', () {
      expect(
        BlobImageCache.httpUrlExtension('https://example.com/uploads/short-url'),
        'jpg',
      );
      expect(BlobImageCache.httpUrlExtension('https://example.com/'), 'jpg');
      expect(BlobImageCache.httpUrlExtension('not a url'), 'jpg');
    });

    test('不会把域名后缀误吞成扩展名', () {
      // 单字符尾段触发整串回退搜索时,'.io/x' 含 '/' 必须被拒绝。
      expect(BlobImageCache.httpUrlExtension('https://a.io/x'), 'jpg');
    });

    test('后缀长度 >4 或含非字母数字时回退默认', () {
      expect(
        BlobImageCache.httpUrlExtension('https://example.com/a/b.html5'),
        'jpg',
      );
      expect(
        BlobImageCache.httpUrlExtension('https://example.com/a/b.c=d'),
        'jpg',
      );
    });

    test('支持自定义回退值', () {
      expect(
        BlobImageCache.httpUrlExtension('https://example.com/a/b', 'png'),
        'png',
      );
    });
  });
}
