/// 生产富文本宿主的语义文档编解码入口。
library;

import 'dart:async';

import 'package:fluxdo_render/semantic_editor.dart';

import '../../../services/discourse_cook_service.dart';
import 'composer_import_pipeline.dart';

/// 可注入真实引擎或测试引擎，所有阶段共享原有导入预算与严格门禁。
class SemanticComposerCodec {
  SemanticComposerCodec({
    FutureOr<String?> Function(String)? cook,
    FutureOr<Map<String, dynamic>?> Function(String)? tokenize,
  }) : _cook = cook ?? DiscourseCookService().cook,
       _tokenize = tokenize ?? DiscourseCookService().parseForEditor;

  final FutureOr<String?> Function(String) _cook;
  final FutureOr<Map<String, dynamic>?> Function(String) _tokenize;
  static const _codec = SemanticDocumentCodec();

  Future<ComposerImportResult<SemanticNode>> import(
    String raw, {
    Duration timeout = const Duration(seconds: 10),
    bool guarded = true,
  }) => ComposerTokenImportPipeline<SemanticNode>(
    cook: _cook,
    parseForEditor: _tokenize,
    convert: (_, dto) {
      if (dto['version'] != 1 || dto['tokens'] is! List) return null;
      try {
        return _codec.parseTokens(dto['tokens'] as List);
      } on SemanticCodecUnsupported {
        return null;
      }
    },
    serialize: export,
    emptyDocument: () =>
        SemanticNode('doc', content: [SemanticNode('paragraph')]),
  ).import(raw, timeout: timeout, guarded: guarded);

  String export(SemanticNode tree) => _codec.serialize(tree);
}
