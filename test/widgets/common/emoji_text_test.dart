import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/emoji_text.dart';

void main() {
  testWidgets('editable emoji spans preserve source text length', (tester) async {
    late BuildContext capturedContext;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    const text = ':smile:abc';
    final spans = EmojiText.buildEmojiSpans(
      capturedContext,
      text,
      const TextStyle(fontSize: 14),
      preserveSourceLength: true,
    );

    expect(TextSpan(children: spans).toPlainText(), hasLength(text.length));
  });
}
