import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tag_notification_level.dart';
import 'core_providers.dart';

/// 同一标签在各页面共享订阅状态，切换账号后重新读取。
final tagNotificationLevelProvider = AsyncNotifierProvider.autoDispose
    .family<TagNotificationLevelNotifier, TagNotificationLevel?, String>(
      TagNotificationLevelNotifier.new,
    );

class TagNotificationLevelNotifier
    extends AsyncNotifier<TagNotificationLevel?> {
  TagNotificationLevelNotifier(this.tagName);

  final String tagName;
  int _generation = 0;

  @override
  FutureOr<TagNotificationLevel?> build() {
    _generation++;
    final userId = ref.watch(
      currentUserProvider.select((user) => user.value?.id),
    );
    if (userId == null) return null;

    return ref.watch(discourseServiceProvider).getTagNotificationLevel(tagName);
  }

  Future<void> setLevel(TagNotificationLevel level) async {
    final previous = state;
    if (previous.isLoading ||
        previous.value == null ||
        previous.value == level) {
      return;
    }

    final generation = _generation;
    state = const AsyncLoading<TagNotificationLevel?>();
    try {
      await ref
          .read(discourseServiceProvider)
          .setTagNotificationLevel(tagName, level);
      if (ref.mounted && generation == _generation) {
        state = AsyncData(level);
      }
    } catch (_) {
      if (ref.mounted && generation == _generation) {
        state = previous;
      }
      rethrow;
    }
  }
}
