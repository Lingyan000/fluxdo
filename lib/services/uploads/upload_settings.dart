import 'package:shared_preferences/shared_preferences.dart';

import 'upload_trace.dart';

/// 本地否决优先于站点能力；一次上传只在开始时选择通道。
abstract final class UploadSettings {
  static const forceDisableMultipartKey = 'pref_force_disable_multipart_upload';

  static bool forceDisabled(SharedPreferences prefs) =>
      prefs.getBool(forceDisableMultipartKey) ?? false;

  static Future<bool> shouldUseMultipart({
    required Future<Map<String, dynamic>?> Function() loadSiteSettings,
    UploadTrace? trace,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (forceDisabled(prefs)) {
      trace?.event(
        'upload_route',
        fields: {'mode': 'standard', 'reason': 'local_disabled'},
      );
      return false;
    }
    final settings = await loadSiteSettings();
    final disabled = forceDisabled(prefs);
    final direct = !disabled && settings?['enable_direct_s3_uploads'] == true;
    trace?.event(
      'upload_route',
      fields: {
        'mode': direct ? 'multipart' : 'standard',
        'reason': disabled
            ? 'local_disabled'
            : direct
            ? 'site_enabled'
            : 'site_disabled_or_missing',
      },
    );
    return direct;
  }
}
