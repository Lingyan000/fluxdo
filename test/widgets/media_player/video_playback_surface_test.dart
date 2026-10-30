import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:fluxdo/widgets/media_player/video/video_playback_surface.dart';

void main() {
  testWidgets('原生表面屏外卸载，回到视口重挂，控制器不变', (tester) async {
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.test/video.mp4'),
      viewType: VideoViewType.platformView,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          height: 200,
          child: VideoPlaybackSurface(controller: controller),
        ),
      ),
    );
    final detector = tester.widget<VisibilityDetector>(
      find.byType(VisibilityDetector),
    );
    expect(find.byType(VideoPlayer), findsOneWidget);
    detector.onVisibilityChanged!(
      VisibilityInfo(key: detector.key!, size: const Size(200, 200)),
    );
    await tester.pump();
    expect(find.byType(VideoPlayer), findsNothing);
    detector.onVisibilityChanged!(
      VisibilityInfo(
        key: detector.key!,
        size: const Size(200, 200),
        visibleBounds: const Rect.fromLTWH(0, 0, 200, 200),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<VideoPlayer>(find.byType(VideoPlayer)).controller,
      same(controller),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    VisibilityDetectorController.instance.notifyNow();
    await controller.dispose();
  });
}
