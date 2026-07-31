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

  test('超长内容截断到段落边界并标记 truncated', () {
    final paragraph = '${'字' * 799}\n';
    final long = paragraph * 25; // 20000 字符,超过 16000 上限

    final clamped = AiTranslationService.clampForTranslation(long);

    expect(clamped.truncated, isTrue);
    expect(
      clamped.text.length,
      lessThanOrEqualTo(AiTranslationService.maxTranslateChars),
    );
    // 截在换行处,不劈开句子
    expect(clamped.text, endsWith('字'));
    expect(long.substring(clamped.text.length, clamped.text.length + 1), '\n');
  });

  test('未超限内容原样返回', () {
    final clamped = AiTranslationService.clampForTranslation('短内容');
    expect(clamped.truncated, isFalse);
    expect(clamped.text, '短内容');
  });

  test('系统提示包含目标语言和只输出译文约束', () {
    final prompt = AiTranslationService.buildSystemPrompt('日本語');

    expect(prompt, contains('日本語'));
    expect(prompt, contains('只输出译文本身'));
  });
}
