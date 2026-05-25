import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import '../../../services/cf_challenge_service.dart';
import '../../../services/toast_service.dart';

/// Cloudflare 验证独立卡片
class CfVerifyCard extends StatelessWidget {
  const CfVerifyCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: const Icon(Icons.security),
        title: Text(context.l10n.cf_securityVerifyTitle),
        subtitle: Text(context.l10n.error_securityChallenge),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: () => _showManualVerify(context),
      ),
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
