import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/ccswitch/ccswitch_credentials.dart';

void main() {
  group('parseNewApiClipboard', () {
    test('parses labeled url + sk key', () {
      const text = '''
Base URL: https://api.example.com/v1
API Key: sk-test-key-12345678
Name: Demo Provider
''';
      final creds = parseNewApiClipboard(text);
      expect(creds, isNotNull);
      expect(creds!.baseUrl, 'https://api.example.com/v1');
      expect(creds.apiKey, 'sk-test-key-12345678');
      expect(creds.name, 'Demo Provider');
    });

    test('parses free-form url and key lines', () {
      const text = '''
https://relay.example.org
sk-abcdefghi1234567890
''';
      final creds = parseNewApiClipboard(text);
      expect(creds, isNotNull);
      expect(creds!.baseUrl, 'https://relay.example.org');
      expect(creds.apiKey, 'sk-abcdefghi1234567890');
    });

    test('parses JSON env style', () {
      const text = '''
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://claude.example.com",
    "ANTHROPIC_AUTH_TOKEN": "sk-json-key-abcdefgh"
  },
  "name": "Claude Relay"
}
''';
      final creds = parseNewApiClipboard(text);
      expect(creds, isNotNull);
      expect(creds!.baseUrl, 'https://claude.example.com');
      expect(creds.apiKey, 'sk-json-key-abcdefgh');
      expect(creds.name, 'Claude Relay');
    });

    test('decodes base64 sk key', () {
      // sk-base64demo123 is base64 "c2stYmFzZTY0ZGVtbzEyMw=="
      const text = '''
https://api.example.com
c2stYmFzZTY0ZGVtbzEyMw==
''';
      final creds = parseNewApiClipboard(text);
      expect(creds, isNotNull);
      expect(creds!.apiKey, 'sk-base64demo123');
    });

    test('partial when only url', () {
      final partial = parseNewApiClipboardPartial('https://only-url.example.com');
      expect(partial, isNotNull);
      expect(partial!.baseUrl, 'https://only-url.example.com');
      expect(partial.apiKey, isNull);
      expect(parseNewApiClipboard('https://only-url.example.com'), isNull);
    });

    test('detects from cooked HTML', () {
      const html = '''
<p>endpoint: https://html.example.com/v1</p>
<code>sk-htmlkey-12345678</code>
''';
      final creds = detectCredentialsFromCooked(html);
      expect(creds, isNotNull);
      expect(creds!.isComplete, isTrue);
      expect(creds.baseUrl, 'https://html.example.com/v1');
      expect(creds.apiKey, 'sk-htmlkey-12345678');
    });
  });

  group('deeplink', () {
    test('builds ccswitch provider deeplink', () {
      const creds = CcswitchCredentials(
        baseUrl: 'https://api.example.com',
        apiKey: 'sk-test-key-12345678',
        name: 'Demo',
      );
      final link = buildCcswitchDeeplink(
        CcswitchImportApp.codex,
        creds,
        name: 'Demo',
        now: DateTime(2026, 1, 2, 3, 4),
      );
      expect(link.startsWith('ccswitch://v1/import?'), isTrue);
      expect(link.contains('resource=provider'), isTrue);
      expect(link.contains('app=codex'), isTrue);
      expect(link.contains('endpoint='), isTrue);
      expect(link.contains('apiKey='), isTrue);
      expect(link.contains('configFormat=json'), isTrue);
      expect(link.contains('config='), isTrue);
    });

    test('all mode expands to three apps', () {
      const creds = CcswitchCredentials(
        baseUrl: 'https://api.example.com',
        apiKey: 'sk-test-key-12345678',
      );
      final links = buildCcswitchDeeplinks(CcswitchImportApp.all, creds);
      expect(links, hasLength(3));
      expect(links[0].contains('app=claude'), isTrue);
      expect(links[1].contains('app=codex'), isTrue);
      expect(links[2].contains('app=gemini'), isTrue);
    });

    test('maskApiKey hides middle', () {
      expect(maskApiKey('sk-1234567890abcd'), 'sk-123…abcd');
    });
  });
}
