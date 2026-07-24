import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/s.dart';
import '../../../providers/preferences_provider.dart';
import '../../../services/cf_challenge_service.dart';
import '../../../services/toast_service.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// Cloudflare 验证独立卡片：自动验证开关 + 立即验证入口
class CfVerifyCard extends ConsumerWidget {
  const CfVerifyCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final autoEnabled = ref.watch(
      preferencesProvider.select((p) => p.autoCfChallenge),
    );

    return SegmentedCardGroup(
      children: [
        SwitchListTile(
          secondary: const Icon(Symbols.shield_rounded),
          title: Text(context.l10n.cfVerify_autoTitle),
          subtitle: Text(context.l10n.cfVerify_autoDesc),
          value: autoEnabled,
          onChanged: (value) => ref
              .read(preferencesProvider.notifier)
              .setAutoCfChallenge(value),
        ),
        ListTile(
          leading: const Icon(Symbols.security_rounded),
          title: Text(context.l10n.cf_securityVerifyTitle),
          subtitle: Text(context.l10n.error_securityChallenge),
          trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
          onTap: () => _showManualVerify(context),
        ),
      ],
    );
  }

  Future<void> _showManualVerify(BuildContext context) async {
    final result = await CfChallengeService().showManualVerifyNow(
      context,
      true,
    );

    if (!context.mounted) return;

    if (result == true) {
      ToastService.showSuccess(S.current.common_success);
    } else if (result == false) {
      ToastService.showError(S.current.cf_failedRetry);
    } else {
      ToastService.showError(S.current.cf_cannotOpenVerifyPage);
    }
  }
}
