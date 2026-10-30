import 'package:fluxdo_render/semantic_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/semantic_composer_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

import '../../helpers/discourse_cook_node.dart';
import 'composer_token_codec_test.dart' show fullMockRaw;

final codec = SemanticComposerCodec(
  cook: cookWithNode,
  tokenize: parseWithNode,
);

void main() {
  final cases = <String, String>{
    '相对改扩展名': '<video width="640" height="360" controls><source src="/uploads/mock.xz" type="video/mp4"></video>',
    '直链无尺寸': '<video src="https://mock.example/video.mp4" controls poster="/mock.png"></video>',
    '多源属性': '<video controls="controls" preload="none" width="100%" loop poster="/mock.png" data-test="mock"><source src="/mock.xz" type="video/mp4" media="(min-width: 1px)"><source src="/mock.webm" type="video/webm"><track src="/mock.vtt" kind="captions"></video>',
    '音频': '<audio controls preload="metadata"><source src="https://mock.example/audio.mp3" type="audio/mpeg"><source src="/mock.ogg" type="audio/ogg"><a href="https://mock.example/audio.mp3">模拟下载</a></audio>',
  };
  for (final entry in cases.entries) {
    test('真实 token 媒体模型与门禁：${entry.key}', () async {
      final raw = entry.value;
      final pipeline = codec;
      final result = await pipeline.import(
        raw,
        guarded: true,
        timeout: const Duration(seconds: 20),
      );
      expect(result.failure, isNull);
      expect(result.document, isA<SemanticNode>());
      final node = SemanticEditorProjection.project(result.document!).blocks
          .whereType<IslandBlock>()
          .single
          .node;
      expect(node, entry.key == '音频' ? isA<AudioNode>() : isA<VideoNode>());
      expect(codec.export(result.document!), '$raw\n\n');
      expect(
        await cookWithNode(codec.export(result.document!)),
        await cookWithNode(raw),
      );
      if (entry.key == '相对改扩展名') {
        final video = node as VideoNode;
        expect(video.src, '/uploads/mock.xz');
        expect(video.mime, 'video/mp4');
        expect(video.width, 640);
        expect(video.height, 360);
      }
    });
  }
  test('全模拟正文保持两个真实媒体块', () async {
    final result = await codec.import(fullMockRaw);
    expect(result.failure, isNull);
    expect(result.document, isA<SemanticNode>());
    final nodes = SemanticEditorProjection.project(result.document!).blocks
        .whereType<IslandBlock>()
        .map((b) => b.node);
    expect(nodes.whereType<VideoNode>(), hasLength(2));
    expect(nodes.whereType<CodeBlockNode>().where((n) => n.rawHtml), isEmpty);
  });
  for (final raw in [
    '${cases.values.first}\n**模拟尾巴**',
    '<div>${cases.values.first}</div>',
    '<video src="/mock.mp4"><div>模拟嵌套</div></video>',
    '<video src="javascript:alert(1)"></video>',
    '<video src="/mock.mp4">',
  ]) {
    test('复杂 token 保整源不吞内容：$raw', () async {
      final result = await codec.import(raw);
      expect(result.failure, isNull);
      expect(result.document, isA<SemanticNode>());
      expect(
        SemanticEditorProjection.project(result.document!).blocks
            .whereType<IslandBlock>()
            .single
            .node,
        isA<CodeBlockNode>(),
      );
      expect(codec.export(result.document!), '$raw\n\n');
      expect(
        await cookWithNode(codec.export(result.document!)),
        await cookWithNode(raw),
      );
    });
  }
  test('Markdown 容器中的媒体仍为媒体', () async {
    final raw = '> ${cases.values.first}';
    final result = await codec.import(raw);
    expect(result.failure, isNull);
    expect(result.document, isA<SemanticNode>());
    expect(result.document!.content.single.type, 'blockquote');
    final media = SemanticEditorProjection.project(result.document!).blocks
        .whereType<IslandBlock>()
        .single;
    expect(media.node, isA<VideoNode>());
    expect(result.document!.content.single.content.single.type, 'html_block');
    expect(
      await cookWithNode(codec.export(result.document!)),
      await cookWithNode(raw),
    );
  });
  test('音频编辑命令替换源并保持媒体 HTML', () async {
    final raw = cases['音频']!;
    final result = await codec.import(raw);
    final session = SemanticEditorSession(result.document!);
    addTearDown(session.dispose);
    final state = session.editor;

    final island = state.blocks.whereType<IslandBlock>().single;
    final node = island.node as AudioNode;
    state.updateIslandNode(
      island.id,
      AudioNode(
        id: node.id,
        src: 'https://mock.example/changed.mp3',
        mime: 'audio/mpeg',
        title: '新音频',
        rawHtml: node.rawHtml,
        rawHtmlSignature: node.rawHtmlSignature,
      ),
    );
    final serialized = codec.export(session.exportTree());
    expect(serialized, contains('<audio'));
    expect(serialized, contains('https://mock.example/changed.mp3'));
    expect(serialized, contains('新音频'));
    expect(serialized, isNot(contains('/mock.ogg')));
    expect(serialized, isNot(contains('https://mock.example/audio.mp3')));
    state.undo();
    expect(codec.export(session.exportTree()).trim(), raw);
  });
  test('媒体编辑命令与撤销不复用旧源', () async {
    final raw = cases['多源属性']!;
    final result = await codec.import(raw);
    final session = SemanticEditorSession(result.document!);
    addTearDown(session.dispose);
    final state = session.editor;

    final island = state.blocks.whereType<IslandBlock>().single;
    final node = island.node as VideoNode;
    state.updateIslandNode(
      island.id,
      VideoNode(
        id: node.id,
        src: '/changed.mp4',
        mime: 'video/mp4',
        poster: '/changed.png',
        width: 320,
        height: 180,
        rawHtml: node.rawHtml,
        rawHtmlSignature: node.rawHtmlSignature,
      ),
    );
    final serialized = codec.export(session.exportTree());
    expect(serialized, contains('/changed.mp4'));
    expect(serialized, contains('/changed.png'));
    expect(serialized, contains('controls='));
    expect(serialized, contains('preload="none"'));
    expect(serialized, contains('/mock.vtt'));
    expect(serialized, isNot(contains('/mock.xz')));
    expect(serialized, isNot(contains('/mock.webm')));
    state.undo();
    expect(codec.export(session.exportTree()).trim(), raw);
  });
}
