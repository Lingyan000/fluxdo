import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/audio/just_audio_gst.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// 记录调用并允许测试手动喂事件的 audioplayers 假实现。
class _FakeAudioplayers extends AudioplayersPlatformInterface {
  final calls = <String>[];
  final events = StreamController<AudioEvent>.broadcast(sync: true);
  int? durationMs = 5000;
  int? positionMs = 0;

  @override
  Future<void> create(String playerId) async => calls.add('create');

  @override
  Future<void> dispose(String playerId) async => calls.add('dispose');

  @override
  Future<void> pause(String playerId) async => calls.add('pause');

  @override
  Future<void> stop(String playerId) async => calls.add('stop');

  @override
  Future<void> resume(String playerId) async => calls.add('resume');

  @override
  Future<void> release(String playerId) async => calls.add('release');

  @override
  Future<void> seek(String playerId, Duration position) async =>
      calls.add('seek:${position.inMilliseconds}');

  @override
  Future<void> setBalance(String playerId, double balance) async {}

  @override
  Future<void> setVolume(String playerId, double volume) async =>
      calls.add('setVolume:$volume');

  @override
  Future<void> setReleaseMode(String playerId, ReleaseMode releaseMode) async =>
      calls.add('setReleaseMode:${releaseMode.name}');

  @override
  Future<void> setPlaybackRate(String playerId, double playbackRate) async =>
      calls.add('setPlaybackRate:$playbackRate');

  @override
  Future<void> setSourceUrl(
    String playerId,
    String url, {
    bool? isLocal,
    String? mimeType,
  }) async => calls.add('setSourceUrl:$url');

  @override
  Future<void> setSourceBytes(
    String playerId,
    Uint8List bytes, {
    String? mimeType,
  }) async {}

  @override
  Future<void> setAudioContext(
    String playerId,
    AudioContext audioContext,
  ) async {}

  @override
  Future<void> setPlayerMode(String playerId, PlayerMode playerMode) async {}

  @override
  Future<int?> getDuration(String playerId) async => durationMs;

  @override
  Future<int?> getCurrentPosition(String playerId) async => positionMs;

  @override
  Future<void> emitLog(String playerId, String message) async {}

  @override
  Future<void> emitError(String playerId, String code, String message) async {}

  @override
  Stream<AudioEvent> getEventStream(String playerId) => events.stream;
}

void main() {
  late _FakeAudioplayers fake;
  late JustAudioGst platform;

  setUp(() {
    fake = _FakeAudioplayers();
    AudioplayersPlatformInterface.instance = fake;
    platform = JustAudioGst();
  });

  Future<AudioPlayerPlatform> initPlayer() =>
      platform.init(InitRequest(id: 'p1'));

  LoadRequest urlRequest([String url = 'https://example.com/a.mp3']) =>
      LoadRequest(
        audioSourceMessage: ProgressiveAudioSourceMessage(
          id: 's1',
          uri: url,
          headers: null,
          tag: null,
        ),
      );

  test('init 创建播放器并设置 stop 释放模式(对齐 just_audio 播完语义)', () async {
    await initPlayer();
    expect(fake.calls, contains('create'));
    expect(fake.calls, contains('setReleaseMode:stop'));
  });

  test('load 等待 prepared 事件后返回时长', () async {
    final player = await initPlayer();
    final loading = player.load(urlRequest());

    // prepared 事件到达前 load 不应完成
    var done = false;
    unawaited(loading.then((_) => done = true));
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);

    fake.events.add(
      const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true),
    );
    final response = await loading;
    expect(response.duration, const Duration(seconds: 5));
  });

  test('complete 事件映射为 completed 且位置钉在末尾', () async {
    final player = await initPlayer();
    final loading = player.load(urlRequest());
    fake.events.add(
      const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true),
    );
    await loading;

    final completed = player.playbackEventMessageStream.firstWhere(
      (e) => e.processingState == ProcessingStateMessage.completed,
    );
    fake.events.add(const AudioEvent(eventType: AudioEventType.complete));
    final event = await completed;
    expect(event.updatePosition, const Duration(seconds: 5));
  });

  test('completed 后 seek 回 ready,可重新播放', () async {
    final player = await initPlayer();
    final loading = player.load(urlRequest());
    fake.events.add(
      const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true),
    );
    await loading;
    fake.events.add(const AudioEvent(eventType: AudioEventType.complete));

    final ready = player.playbackEventMessageStream.firstWhere(
      (e) => e.processingState == ProcessingStateMessage.ready,
    );
    await player.seek(SeekRequest(position: Duration.zero));
    final event = await ready;
    expect(event.updatePosition, Duration.zero);
    expect(fake.calls, contains('seek:0'));
  });

  test('加载失败经事件流错误抛出,而不是永久挂起', () async {
    final player = await initPlayer();
    final loading = player.load(urlRequest());
    fake.events.addError(Exception('gst error'));
    await expectLater(loading, throwsA(isA<Exception>()));
  });

  test('不支持的音源类型直接拒绝', () async {
    final player = await initPlayer();
    await expectLater(
      player.load(
        LoadRequest(
          audioSourceMessage: ConcatenatingAudioSourceMessage(
            id: 'list',
            children: const [],
            useLazyPreparation: false,
            shuffleOrder: const [],
          ),
        ),
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('disposePlayer 释放底层播放器,重复 id 可再创建', () async {
    await initPlayer();
    await platform.disposePlayer(DisposePlayerRequest(id: 'p1'));
    expect(fake.calls, contains('dispose'));
    // 释放后同 id 重新 init 不应抛"already exists"
    await initPlayer();
  });
}
