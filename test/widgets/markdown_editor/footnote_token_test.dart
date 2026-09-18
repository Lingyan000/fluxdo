import 'package:fluxdo_render/semantic_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

import 'composer_token_codec_test.dart' show fullMockRaw;

import '../../helpers/discourse_cook_node.dart';

Future<Map<String, dynamic>> _parse(String raw) =>
    parseWithNode(raw, footnotes: true);
Future<String> _cook(String raw) => cookWithNode(raw, footnotes: true);

final codec = SemanticComposerCodec(cook: _cook, tokenize: _parse);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('行内脚注可导入并保持渲染', () async {
    const raw = '模拟正文^[模拟 **注释**]';
    final original = await _cook(raw);
    var current = raw;
    for (var round = 0; round < 3; round++) {
      final result = await codec.import(current);
      expect(result.failure, isNull);
      current = codec.export(result.document!);
      expect(await _cook(current), original);
    }
  });
  const note =
      '模拟引用[^mock]，重复[^mock]，第二条[^other]。\n\n'
      '[^mock]: 模拟 **粗体** 与 [链接](https://example.com) 和 `代码`\n'
      '[^other]: 模拟 *斜体*';
  for (final raw in [note, '$fullMockRaw\n\n$note']) {
    test('启用插件的真实 cook 严格三轮门禁 ${raw.length}', () async {
      final pipeline = codec;
      var current = raw;
      for (var round = 0; round < 3; round++) {
        final result = await pipeline.import(
          current,
          guarded: true,
          timeout: const Duration(seconds: 20),
        );
        expect(result.failure, isNull);
        final nodes = SemanticEditorProjection.project(result.document!).blocks
            .whereType<IslandBlock>()
            .map((b) => b.node)
            .toList();
        final section = nodes.whereType<FootnotesSectionNode>().single;
        expect(section.entries.length, raw.contains('[^mock]') ? 2 : 1);
        expect(
          section.entries.first.inlines.whereType<StrongRun>(),
          isNotEmpty,
        );
        final refs = SemanticEditorProjection.project(result.document!).blocks
            .whereType<TextBlock>()
            .expand((p) => p.content.toInlines())
            .whereType<FootnoteRefRun>()
            .toList();
        expect(refs.length, raw.contains('[^mock]') ? 3 : 1);
        expect(refs.first.fnId, section.entries.first.id);
        if (refs.length == 3) {
          expect(refs[1].fnId, refs[0].fnId);
          expect(refs.first.markdownLabel, 'mock');
          expect(section.entries.first.markdownLabel, 'mock');
        }
        current = codec.export(result.document!);
      }
    });
  }

  test('真实审计 fixture 恢复模型', () async {
    final fixture =
        (jsonDecode(
              File(
                'packages/fluxdo_render/test/fixtures/audit_token_matrix.json',
              ).readAsStringSync(),
            ) as Map)['footnote']
            as Map<String, dynamic>;
    final result = await SemanticComposerCodec(
      cook: _cook,
      tokenize: (_) => fixture,
    ).import(fixture['raw'] as String);
    expect(result.failure, isNull);
    expect(
      SemanticEditorProjection.project(result.document!).blocks
          .whereType<IslandBlock>()
          .map((b) => b.node)
          .whereType<FootnotesSectionNode>()
          .single
          .entries
          .single
          .number,
      '1',
    );
  });

  test('未定义引用保留字面正文', () async {
    const raw = '模拟缺定义[^missing]';
    final result = await codec.import(raw);
    expect(result.failure, isNull);
    expect(await _cook(codec.export(result.document!)), await _cook(raw));
  });

  test('复杂定义正式支持且严格保持多段及列表结构', () async {
    for (final body in ['模拟首段\n\n    模拟第二段', '模拟首段\n\n    - 模拟列表']) {
      final raw = '模拟[^mock]\n\n[^mock]: $body';
      final result = await codec.import(raw);
      expect(result.failure, isNull);
      final section = result.document!.content.singleWhere(
        (n) => n.type == 'footnote_block',
      );
      expect(section.content.single.content, hasLength(2));
      expect(
        section.content.single.content.last.type,
        body.contains('模拟列表') ? 'bullet_list' : 'paragraph',
      );
      expect(await _cook(codec.export(result.document!)), await _cook(raw));
    }
  });

  test('未知子 token 及缺定义 DTO 安全拒绝', () async {
    final dto = await _parse(note);
    final ts = dto['tokens'] as List;
    final start = ts.indexWhere((t) => t['type'] == 'footnote_open');
    final child = ts.skip(start).firstWhere((t) => t['type'] == 'inline');
    child['children'] = [
      {'type': 'mock_unknown', 'nesting': 0, 'content': '不能吞掉'},
    ];
    expect(
      (await SemanticComposerCodec(
        cook: _cook,
        tokenize: (_) => dto,
      ).import(note)).failure,
      isNotNull,
    );
    final missing = await _parse(note);
    final tokens = missing['tokens'] as List;
    tokens.removeRange(
      tokens.indexWhere((t) => t['type'] == 'footnote_block_open'),
      tokens.length,
    );
    expect(
      (await SemanticComposerCodec(
        cook: _cook,
        tokenize: (_) => missing,
      ).import(note)).failure,
      isNotNull,
    );
  });
}
