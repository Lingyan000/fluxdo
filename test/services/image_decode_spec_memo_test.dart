import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/services/image_decode_spec_memo.dart';

void main() {
  test('源图复用保留头像 bucket、倍率、缩放策略和物理尺寸', () async {
    const url = 'https://test.invalid/avatar.png';
    final source = ResizeImage(
      const BlobImageProvider(
        url,
        bucket: BlobImageCache.avatarBucket,
        scale: 2,
      ),
      width: 144,
      height: 144,
      policy: ResizeImagePolicy.fit,
    );
    ImageDecodeSpecMemo.remember(url, source);
    final reused = ImageDecodeSpecMemo.peek(url)!;
    expect(reused, same(source));
    expect(
      await reused.obtainKey(ImageConfiguration.empty),
      await source.obtainKey(ImageConfiguration.empty),
    );
    expect(
      await reused.obtainKey(ImageConfiguration.empty),
      isNot(
        await discourseImageProvider(url).obtainKey(ImageConfiguration.empty),
      ),
    );
  });

  test('相同 URL 新尺寸覆盖旧记录，LRU 不无限保留 provider', () {
    const source = BlobImageProvider('test', bucket: 'test');
    final first = ResizeImage(source, width: 20);
    ImageDecodeSpecMemo.remember('memo-0', first);
    for (var i = 1; i < 512; i++) {
      ImageDecodeSpecMemo.remember('memo-$i', source);
    }
    expect(ImageDecodeSpecMemo.peek('memo-0'), same(first));
    ImageDecodeSpecMemo.remember('memo-512', source);
    expect(ImageDecodeSpecMemo.peek('memo-1'), isNull);
    final resized = ResizeImage(source, width: 40);
    ImageDecodeSpecMemo.remember('memo-0', resized);
    expect(ImageDecodeSpecMemo.peek('memo-0'), same(resized));
  });
}
