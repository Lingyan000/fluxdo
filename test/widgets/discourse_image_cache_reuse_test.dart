import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/services/image_decode_spec_memo.dart';
import 'package:fluxdo/widgets/common/hero_image.dart';
import 'package:fluxdo/widgets/content/discourse_image.dart';

void main() {
  testWidgets('普通图片的 Hero 和查看器记录使用屏上图片的实际 provider', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    const url = 'https://test.invalid/cached-picture.jpg';
    final expected = ResizeImage(
      discourseImageProvider(url),
      width: 80,
      height: 60,
      policy: ResizeImagePolicy.fit,
    );
    final key = await expected.obtainKey(ImageConfiguration.empty);
    final pixels = (await tester.runAsync(
      () => createTestImage(width: 80, height: 60, cache: false),
    ))!;
    tester.binding.imageCache.putIfAbsent(
      key,
      () =>
          OneFrameImageStreamCompleter(Future.value(ImageInfo(image: pixels))),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: DiscourseImage(
            url: url,
            width: 80,
            height: 60,
            heroTag: 'cached-picture',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final source = tester.widget<Image>(find.byType(Image)).image;
    expect(
      tester.widget<HeroImage>(find.byType(HeroImage)).flightImage,
      same(source),
    );
    expect(ImageDecodeSpecMemo.peek(url), same(source));
    expect(await source.obtainKey(ImageConfiguration.empty), key);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.imageCache.evict(key);
  });
}
