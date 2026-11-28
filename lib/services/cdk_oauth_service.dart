import '../l10n/s.dart';
import '../models/cdk_user_info.dart';
import 'linux_do_connect_oauth_service.dart';

/// CDK（cdk.linux.do）授权。
class CdkOAuthService extends LinuxDoConnectOAuthService {
  static const String baseUrl = 'https://cdk.linux.do';

  CdkOAuthService({super.dio, super.sessionClient})
    : super(
        baseUrl: baseUrl,
        serviceName: 'CDK',
        confirmTitle: (context) => context.l10n.auth_cdkConfirmTitle,
        confirmMessage: (context) => context.l10n.auth_cdkConfirmMessage,
      );

  Future<CdkUserInfo?> getUserInfo({String? expectedUsername}) async {
    return CdkUserInfo.fromJson(
      await getUserInfoData(expectedUsername: expectedUsername),
    );
  }
}
