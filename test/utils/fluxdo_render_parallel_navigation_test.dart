import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/selected_topic_provider.dart';
import 'package:fluxdo/utils/fluxdo_render_callbacks.dart';

void main() {
  testWidgets('正文站内链接压入当前平行视界栈', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedMessageProvider.notifier).select(topicId: 1);
    final callbacks = FluxdoRenderCallbacks.generic(
      heroTagNamespace: 'parallel_link_test',
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: EmbeddedStackScope(
            stackProvider: selectedMessageProvider,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => callbacks.linkHandler(
                  context,
                  'https://linux.do/t/topic/42/7',
                ),
                child: const Text('打开站内链接'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开站内链接'));
    await tester.pump();

    final state = container.read(selectedMessageProvider);
    expect(state.stack, hasLength(2));
    expect(state.topicId, 42);
    expect(state.scrollToPostNumber, 7);
    expect(container.read(selectedTopicProvider).hasSelection, isFalse);
  });

  testWidgets('master 预览里的正文链接替换右栏而不继续叠层', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedTopicProvider.notifier).select(topicId: 1);
    container.read(selectedTopicProvider.notifier)
      ..pushProfile('alice')
      ..push(topicId: 2);
    final callbacks = FluxdoRenderCallbacks.generic(
      heroTagNamespace: 'parallel_truncate_test',
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: EmbeddedStackScope(
            stackProvider: selectedTopicProvider,
            truncateOnPush: true,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => callbacks.linkHandler(
                  context,
                  'https://linux.do/t/topic/99',
                ),
                child: const Text('替换右栏'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('替换右栏'));
    await tester.pump();

    final state = container.read(selectedTopicProvider);
    expect(state.stack, hasLength(3));
    expect(state.stack[0].topicId, 1);
    expect(state.stack[1].username, 'alice');
    expect(state.stack[2].topicId, 99);
  });

  testWidgets('@提及在当前平行视界栈打开用户资料', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedSeekingProvider.notifier).select(topicId: 1);
    final callbacks = FluxdoRenderCallbacks.generic(
      heroTagNamespace: 'parallel_mention_test',
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: EmbeddedStackScope(
            stackProvider: selectedSeekingProvider,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => callbacks.mentionTapHandler(
                  context,
                  'fallback',
                  '/u/alice',
                ),
                child: const Text('打开提及用户'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开提及用户'));
    await tester.pump();

    final state = container.read(selectedSeekingProvider);
    expect(state.stack, hasLength(2));
    expect(state.kind, PaneKind.profile);
    expect(state.username, 'alice');
    expect(container.read(selectedTopicProvider).hasSelection, isFalse);
  });
}
