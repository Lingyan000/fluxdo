import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The summary endpoint is queried for the profile being viewed, not only
    // for the currently authenticated user.
    FlutterSecureStorage.setMockInitialValues({
      'linux_do_username': 'signed-in-user',
    });
  });

  test(
    'loads another user summary while signed in as a different user',
    () async {
      final service = DiscourseService();
      service.dio.httpClientAdapter = _SummaryAdapter();

      final summary = await service.getUserSummary(
        'another-user',
        forceRefresh: true,
      );

      expect(summary.daysVisited, 7);
    },
  );
}

class _SummaryAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.path, '/u/another-user/summary.json');
    return ResponseBody.fromString(
      jsonEncode({
        'user_summary': {'days_visited': 7},
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
