import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:app_icons/app_icons.dart';
import 'package:ai_model_manager/ai_model_manager.dart';

import '../../l10n/s.dart';
import '../../providers/locale_provider.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../settings_model.dart';

SettingsModel buildLanguageSetting(BuildContext context) => CustomModel(
  id: 'language',
  title: '${context.l10n.appearance_language} / Language',
  builder: (context, ref) {
    final locale = ref.watch(localeProvider);
    return ListTile(
      leading: Icon(
        Symbols.translate_rounded,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: Text(
        context.l10n.appearance_language == 'Language'
            ? 'Language'
            : '${context.l10n.appearance_language} / Language',
      ),
      subtitle: Text(_localeLabel(context.l10n, locale)),
      trailing: const Icon(Symbols.chevron_right_rounded),
      onTap: () => _showLanguagePicker(context, ref, locale),
    );
  },
);

void _showLanguagePicker(
  BuildContext context,
  WidgetRef ref,
  Locale? currentLocale,
) {
  final l10n = context.l10n;
  final options = <(String, Locale?)>[
    (l10n.appearance_languageSystem, null),
    (l10n.appearance_languageZhCN, const Locale('zh', 'CN')),
    (l10n.appearance_languageZhTW, const Locale('zh', 'TW')),
    (l10n.appearance_languageZhHK, const Locale('zh', 'HK')),
    (l10n.appearance_languageEn, const Locale('en', 'US')),
  ];

  AppBottomSheet.show<void>(
    context: context,
    contentPadding: EdgeInsets.zero,
    builder: (sheetContext) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, locale) in options)
            ListTile(
              title: Text(label),
              trailing: _localeKey(locale) == _localeKey(currentLocale)
                  ? Icon(
                      Symbols.check_rounded,
                      color: sheetContext.emphasis.selected,
                    )
                  : null,
              onTap: () {
                ref.read(localeProvider.notifier).setLocale(locale);
                final effectiveLocale =
                    locale ?? WidgetsBinding.instance.platformDispatcher.locale;
                AiL10n.configureLocale(effectiveLocale);
                Navigator.pop(sheetContext);
              },
            ),
        ],
      );
    },
  );
}

String _localeLabel(AppLocalizations l10n, Locale? locale) {
  if (locale == null) return l10n.appearance_languageSystem;
  switch ('${locale.languageCode}_${locale.countryCode}') {
    case 'zh_CN':
      return l10n.appearance_languageZhCN;
    case 'zh_TW':
      return l10n.appearance_languageZhTW;
    case 'zh_HK':
      return l10n.appearance_languageZhHK;
    case 'en_US':
      return l10n.appearance_languageEn;
    default:
      return l10n.appearance_languageSystem;
  }
}

String _localeKey(Locale? locale) {
  if (locale == null) return 'system';
  return locale.countryCode != null
      ? '${locale.languageCode}_${locale.countryCode}'
      : locale.languageCode;
}
