import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:html/parser.dart' as html_parser;

/// 帖子内容 AI 翻译服务。
class AiTranslationService {
  AiTranslationService({required AiChatService chatService})
    : _chatService = chatService;

  final AiChatService _chatService;

  /// 流式翻译 [text] 到 [targetLanguage]，每个事件是一段增量文本。
  Stream<String> translateStream({
    required AiProvider provider,
    required AiModel model,
    required String apiKey,
    required String text,
    required String targetLanguage,
  }) async* {
    final stream = _chatService.sendChatStream(
      provider: provider,
      model: model.id,
      apiKey: apiKey,
      systemPrompt: buildSystemPrompt(targetLanguage),
      messages: [
        AiChatMessage(
          id: 'translate-request',
          role: ChatRole.user,
          content: text,
          createdAt: DateTime.now(),
        ),
      ],
      thinkingConfig: const ThinkingConfig(),
    );
    await for (final chunk in stream) {
      if (chunk is TextDelta) yield chunk.text;
    }
  }

  static String buildSystemPrompt(String targetLanguage) {
    return '''
你是一名专业翻译。把用户发来的论坛帖子内容完整翻译成目标语言：$targetLanguage。

要求：
1. 只输出译文本身，不要任何前言、解释或“以下是翻译”之类的话。
2. 保留原文的段落结构与列表结构。
3. 代码块、命令、URL、@用户名、专有名词（软件名/型号等）保持原样不翻译。
4. 语气与原文一致（口语保持口语，技术表达保持准确）。
5. 如果原文已经是目标语言，原样输出并在末尾另起一行注明「（原文即目标语言）」。
''';
  }

  /// 单次送翻的字符上限。超长帖(转录、日志贴)整篇塞给模型会超出上下文
  /// 或烧掉大量 token(用的是用户自己的 API Key),超限截到段落边界,
  /// UI 侧注明只翻译了开头部分。
  static const int maxTranslateChars = 16000;

  /// 超过 [maxTranslateChars] 时截断,尽量截在换行处避免劈开句子。
  static ({String text, bool truncated}) clampForTranslation(String text) {
    if (text.length <= maxTranslateChars) {
      return (text: text, truncated: false);
    }
    var cut = text.lastIndexOf('\n', maxTranslateChars);
    if (cut < maxTranslateChars ~/ 2) cut = maxTranslateChars;
    return (text: text.substring(0, cut).trimRight(), truncated: true);
  }

  /// cooked HTML 转为供翻译的纯文本。
  static String extractPlainText(String cookedHtml) {
    final document = html_parser.parse(cookedHtml);
    for (final img in document.querySelectorAll('img')) {
      final alt = img.attributes['alt'];
      img.replaceWith(
        html_parser.parseFragment(alt != null && alt.isNotEmpty ? alt : ''),
      );
    }
    final text = document.body?.text ?? cookedHtml;
    return text
        .replaceAll(RegExp(r'\r\n?'), '\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}
