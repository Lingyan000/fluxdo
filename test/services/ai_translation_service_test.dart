import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/ai_translation_service.dart';

void main() {
  test('从 cooked HTML 提取可翻译文本并保留图片 alt', () {
    final text = AiTranslationService.extractPlainText(
      '<p>Hello <strong>world</strong></p><p><img alt=":wave:"></p>',
    );

    expect(text, contains('Hello world'));
    expect(text, contains(':wave:'));
  });

  test('系统提示包含目标语言和只输出译文约束', () {
    final prompt = AiTranslationService.buildSystemPrompt('日本語');

    expect(prompt, contains('日本語'));
    expect(prompt, contains('只输出译文本身'));
  });
}
