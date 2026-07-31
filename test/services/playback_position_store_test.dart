import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/media/playback_position_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const url = 'https://cdn.example.com/uploads/video.mp4?sig=abc123';
  const urlOtherSig = 'https://cdn.example.com/uploads/video.mp4?sig=zzz999';
  const longDuration = Duration(minutes: 10);

  test('保存后可恢复,签名 query 不同视为同一视频', () async {
    final store = PlaybackPositionStore.instance;
    await store.save(url, const Duration(minutes: 3), longDuration);
    // 同 path 不同签名 → 命中同一条记忆
    final restored = await store.restore(urlOtherSig);
    expect(restored, const Duration(minutes: 3));
  });

  test('短视频不记忆', () async {
    final store = PlaybackPositionStore.instance;
    await store.save(url, const Duration(seconds: 20),
        const Duration(seconds: 50)); // 总长 < 60s
    expect(await store.restore(url), isNull);
  });

  test('片头/片尾豁免区删除记忆', () async {
    final store = PlaybackPositionStore.instance;
    await store.save(url, const Duration(minutes: 3), longDuration);
    expect(await store.restore(url), isNotNull);

    // 播到距片尾 10s 内 → 视为看完,删除
    await store.save(
        url, longDuration - const Duration(seconds: 5), longDuration);
    expect(await store.restore(url), isNull);

    // 重新记一条,再回到片头 5s 内 → 删除
    await store.save(url, const Duration(minutes: 3), longDuration);
    await store.save(url, const Duration(seconds: 2), longDuration);
    expect(await store.restore(url), isNull);
  });

  test('flush 落盘后新实例可读回(持久化往返)', () async {
    final store = PlaybackPositionStore.instance;
    await store.save(url, const Duration(minutes: 7), longDuration);
    await store.flush();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('media_playback_positions');
    expect(raw, isNotNull);
    expect(raw, contains('"p":420000'));
  });

  test('remove 删除记忆', () async {
    final store = PlaybackPositionStore.instance;
    await store.save(url, const Duration(minutes: 3), longDuration);
    await store.remove(url);
    expect(await store.restore(url), isNull);
  });
}
