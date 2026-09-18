import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';

import 'composer_token_codec_test.dart' show parseWithNode, cookWithNode;

void main() {
  final codec = SemanticComposerCodec(
    tokenize: parseWithNode,
    cook: cookWithNode,
  );
  final auditFixtures = jsonDecode(
    File('packages/fluxdo_render/test/fixtures/audit_token_matrix.json')
        .readAsStringSync(),
  ) as Map;
  test('完整审计矩阵保留全部 34 例', () {
    expect(auditFixtures, hasLength(34), reason: '不得排除旧编辑器可切换的语法');
  });
  for (final entry in auditFixtures.entries) {
    test('audit 正式 cook 门禁：${entry.key}', () async {
      final result = await codec.import(entry.value['raw'] as String);
      expect(result.failure, isNull, reason: entry.key);
    });
  }
  test('真实完整用户 mock 与常用块通过正式 cook 等价门禁', () async {
    final fixtures = jsonDecode(
      File('packages/fluxdo_render/test/fixtures/semantic_block_bundle.json')
          .readAsStringSync(),
    ) as Map;
    for (final entry in fixtures.entries) {
      final result = await codec.import(entry.value['raw'] as String);
      expect(result.failure, isNull, reason: entry.key);
    }
  });
}
