import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/s.dart';
import '../providers/theme_provider.dart';
import '../services/toast_service.dart';
import '../theme/theme_spec.dart';

/// 节日期间首次打开应用时的问候提示（每个节日窗口只问候一次）。
class FestivalGreeting {
  FestivalGreeting._();

  static const String greetedKey = 'festival_greeted';

  static void maybeShow(BuildContext context, WidgetRef ref) {
    final state = ref.read(themeProvider);
    final festival = state.activeFestival;
    if (festival == null || !state.festivalGreetingEnabled) return;
    final prefs = ref.read(sharedPreferencesProvider);
    final greeted = prefs.getStringList(greetedKey) ?? const [];
    if (greeted.contains(festival.key)) return;
    // 只保留最近若干条，避免无限增长
    final kept = [...greeted, festival.key];
    prefs.setStringList(
      greetedKey,
      kept.length > 20 ? kept.sublist(kept.length - 20) : kept,
    );

    final l10n = context.l10n;
    final greeting = localizedName(
      festival.festival.greeting,
      Localizations.localeOf(context),
      festival.festival.id,
    );
    final notifier = ref.read(themeProvider.notifier);
    ToastService.show(
      '${festival.festival.emojiChar} $greeting · '
      '${l10n.appearance_festivalApplied}',
      duration: const Duration(seconds: 5),
      actionLabel: l10n.appearance_festivalSkip,
      onAction: notifier.skipCurrentFestival,
    );
  }
}
