import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/s.dart';
import '../../../providers/preferences_provider.dart';
import '../../../services/cf_challenge_service.dart';
import '../../../services/toast_service.dart';
import '../../../widgets/common/cloudflare_mark.dart';

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
          secondary: Icon(
            Symbols.shield_rounded,
            color: autoEnabled
                ? context.emphasis.selected
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          title: Text(context.l10n.cfVerify_autoTitle),
          subtitle: Text(context.l10n.cfVerify_autoDesc),
          value: autoEnabled,
          onChanged: (value) => ref
              .read(preferencesProvider.notifier)
              .setAutoCfChallenge(value),
        ),
        ListTile(
          leading: const ExcludeSemantics(child: CloudflareMark.icon()),
          title: Text(context.l10n.cfVerify_title),
          subtitle: Text(context.l10n.error_securityChallenge),
          trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
          onTap: () => _showManualVerify(context),
        ),
      ],
    );
  }

  Future<void> _showManualVerify(BuildContext context) async {
    final result = await CfChallengeService().verifyPage(
      context: context,
      userInitiated: true,
    );

    if (!context.mounted) return;

    if (result?.stage == CfVerificationStage.noChallengeObserved) {
      ToastService.showInfo(S.current.cf_noChallengeTitle);
    } else if (result?.reachedOrigin == true) {
      ToastService.showSuccess(S.current.cfVerify_success);
    } else if (result != null) {
      ToastService.showError(result.label(context.l10n));
    } else {
      ToastService.showError(S.current.cf_cannotOpenVerifyPage);
    }
  }
}
