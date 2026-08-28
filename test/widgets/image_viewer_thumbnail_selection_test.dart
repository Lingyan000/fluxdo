import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';

void main() {
  group('图片查看器缩略图选择', () {
    test('初始页优先复用点击入口实际显示的 srcset URL', () {
      final result = ImageViewerPage.debugThumbnailUrlForIndex(
        index: 2,
        initialIndex: 2,
        thumbnailUrl: 'https://cdn.example.com/image_2x.webp',
        thumbnailUrls: const [
          'https://cdn.example.com/image-0.jpg',
          'https://cdn.example.com/image-1.jpg',
          'https://cdn.example.com/image-default.jpg',
        ],
      );

      expect(result, 'https://cdn.example.com/image_2x.webp');
    });

    test('非初始页使用画廊对应的缩略图 URL', () {
      final result = ImageViewerPage.debugThumbnailUrlForIndex(
        index: 1,
        initialIndex: 2,
        thumbnailUrl: 'https://cdn.example.com/image-2.webp',
        thumbnailUrls: const [
          'https://cdn.example.com/image-0.jpg',
          'https://cdn.example.com/image-1.jpg',
          'https://cdn.example.com/image-default.jpg',
        ],
      );

      expect(result, 'https://cdn.example.com/image-1.jpg');
    });
  });
}
