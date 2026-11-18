import 'dart:convert';

import 'package:ai_model_manager/models/ai_chat_message.dart';
import 'package:ai_model_manager/models/ai_provider.dart';
import 'package:ai_model_manager/services/ai_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final (base, path) in [
    ('https://example.test', '/v1/messages'),
    ('https://example.test/proxy/v2', '/proxy/v2/messages'),
    ('https://example.test/custom#', '/custom/messages'),
  ]) {
    test('流式回复保留代理路径 $path、缓存标记和用量', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        expect(request.url, Uri.https('example.test', path));
        expect(request.headers['anthropic-version'], '2023-06-01');
        expect(request.headers['x-api-key'], 'test-key');
        final body = jsonDecode(request.body) as Map;
        expect(body['stream'], isTrue);
        expect(body['system'][0]['cache_control']['type'], 'ephemeral');
        expect(body['messages'][0]['content'][0]['text'], '上下文');
        final events = [
          {
            'type': 'message_start',
            'message': {
              'id': 'msg',
              'model': 'model',
              'content': [],
              'usage': {
                'input_tokens': 8,
                'output_tokens': 0,
                'cache_read_input_tokens': 5
              }
            }
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'thinking_delta', 'thinking': '思考'}
          },
          {
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'text_delta', 'text': '正文'}
          },
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 3}
          },
          {'type': 'message_stop'},
        ];
        final sse = events
            .map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n')
            .join();
        return http.Response.bytes(utf8.encode(sse), 200,
            headers: {'content-type': 'text/event-stream'});
      });
      final stats = ChatStreamStats();
      final chunks = await AiChatService(bridgedClient: client).sendChatStream(
        provider: AiProvider(
            id: 'local',
            name: '测试',
            type: AiProviderType.anthropic,
            baseUrl: base),
        model: 'model',
        apiKey: 'test-key',
        systemPrompt: '系统',
        stats: stats,
        messages: [
          AiChatMessage(
              id: 'context-user',
              role: ChatRole.user,
              content: '上下文',
              createdAt: DateTime.utc(2026))
        ],
      ).toList();
      expect(calls, 1);
      expect(chunks.whereType<ThinkingDelta>().single.text, '思考');
      expect(chunks.whereType<TextDelta>().single.text, '正文');
      final usage = chunks.whereType<UsageReport>().single;
      expect([usage.promptTokens, usage.responseTokens, usage.cachedTokens],
          [8, 3, 5]);
      expect(stats.httpStatus, 200);
      expect(stats.respBytes, greaterThan(0));
    });
  }
}
