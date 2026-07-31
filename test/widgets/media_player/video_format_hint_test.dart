import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/media_player/video/video_player_session.dart';
import 'package:video_player/video_player.dart';

void main() {
  group('videoFormatHintFromMime', () {
    test('普通容器 → other(强制 progressive,不信任伪装后缀)', () {
      expect(videoFormatHintFromMime('video/mp4'), VideoFormat.other);
      expect(videoFormatHintFromMime('video/webm'), VideoFormat.other);
      expect(videoFormatHintFromMime('audio/mpeg'), VideoFormat.other);
      // 带参数与大小写
      expect(videoFormatHintFromMime('Video/MP4; codecs="avc1"'),
          VideoFormat.other);
    });

    test('流媒体协议映射', () {
      expect(videoFormatHintFromMime('application/dash+xml'),
          VideoFormat.dash);
      expect(videoFormatHintFromMime('application/vnd.apple.mpegurl'),
          VideoFormat.hls);
      expect(
          videoFormatHintFromMime('application/x-mpegurl'), VideoFormat.hls);
      expect(videoFormatHintFromMime('application/vnd.ms-sstr+xml'),
          VideoFormat.ss);
    });

    test('空/未知 → null', () {
      expect(videoFormatHintFromMime(null), isNull);
      expect(videoFormatHintFromMime(''), isNull);
      expect(videoFormatHintFromMime('application/octet-stream'), isNull);
    });
  });
}
