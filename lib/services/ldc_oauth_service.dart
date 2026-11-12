import '../l10n/s.dart';
import '../models/ldc_user_info.dart';
import 'linux_do_connect_oauth_service.dart';

/// LDC（credit.linux.do）授权。
class LdcOAuthService extends LinuxDoConnectOAuthService {
  static const String baseUrl = 'https://credit.linux.do';

  LdcOAuthService({super.dio, super.sessionClient})
    : super(
        baseUrl: baseUrl,
        serviceName: 'LDC',
        confirmTitle: (context) => context.l10n.auth_ldcConfirmTitle,
        confirmMessage: (context) => context.l10n.auth_ldcConfirmMessage,
      );

  Future<LdcUserInfo?> getUserInfo({String? expectedUsername}) async {
    return LdcUserInfo.fromJson(
      await getUserInfoData(expectedUsername: expectedUsername),
    );
  }
}
