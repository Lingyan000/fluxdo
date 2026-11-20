import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/ldc_biometric_payment.dart';
import '../../services/ldc_oauth_service.dart';
import '../../services/ldc_payment_service.dart';
import '../../services/ldc_payment_session.dart';
import '../../services/network/exceptions/oauth_exception.dart';
import '../../services/storage/secret_store.dart';
import 'ldc_payment_sheet.dart';

/// 应用与插件共用收银台入口；商户保留自己的建单和交付查询。
Future<Map<String, Object?>?> requestLdcPayment(
  BuildContext context, {
  required Uri url,
  required String reference,
  required Object amount,
  required int accountId,
  required String username,
  required SecretStore secretStore,
  required SharedPreferences preferences,
  required Future<void> Function() checkSession,
}) async {
  await checkSession();
  final service = LdcPaymentService();
  try {
    final oauth = LdcOAuthService();
    var needsPassword = false;
    try {
      final user = await oauth.getUserInfo(expectedUsername: username);
      needsPassword = user?.isPayKey != true;
    } on OAuthExpiredException {
      await checkSession();
      if (!context.mounted || !await oauth.authorize(context)) return null;
      await checkSession();
      final user = await oauth.getUserInfo(expectedUsername: username);
      needsPassword = user?.isPayKey != true;
    }
    await checkSession();
    if (!context.mounted) return null;
    return await showLdcPaymentSheet(
      context,
      payment: LdcPaymentSession(
        service: service,
        paymentUrl: url,
        reference: reference,
        amount: amount,
        checkSession: checkSession,
      ),
      orderNo: reference,
      username: username,
      needsPassword: needsPassword,
      biometrics: LdcBiometricPayment(
        accountId: accountId,
        store: secretStore,
        preferences: preferences,
        checkSession: checkSession,
      ),
    );
  } finally {
    service.dispose();
  }
}
