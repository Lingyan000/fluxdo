import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluxdo/services/sticker_market_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'uses canonical filename when group id already has group prefix',
    () async {
      SharedPreferences.setMockInitialValues({});
      final paths = <String>[];
      final prefs = await SharedPreferences.getInstance();
      final service = StickerMarketService(prefs, dio: _buildDio(paths));

      await service.getGroupDetail('group-123');

      expect(paths, ['/assets/market/group-123.json']);
    },
  );

  test('adds group prefix for legacy bare group ids', () async {
    SharedPreferences.setMockInitialValues({});
    final paths = <String>[];
    final prefs = await SharedPreferences.getInstance();
    final service = StickerMarketService(prefs, dio: _buildDio(paths));

    await service.getGroupDetail('123');

    expect(paths, ['/assets/market/group-123.json']);
  });
}

Dio _buildDio(List<String> paths) {
  return Dio()..httpClientAdapter = _RecordingAdapter(paths);
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.paths);

  final List<String> paths;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
    return ResponseBody.fromString(
      jsonEncode({
        'id': 'group-123',
        'name': 'test',
        'icon': '🙂',
        'emojis': [],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
