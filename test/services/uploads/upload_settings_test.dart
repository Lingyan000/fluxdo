import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/services/uploads/upload_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('默认跟随站点，仅明确开启时分片', () async {
    for (final value in [true, false, null]) {
      expect(
        await UploadSettings.shouldUseMultipart(
          loadSiteSettings: () async => {'enable_direct_s3_uploads': value},
        ),
        value == true,
      );
    }
  });

  test('本地关闭持久保存并跳过站点能力查询，恢复后重新跟随站点', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(UploadSettings.forceDisableMultipartKey, true);
    expect(
      UploadSettings.forceDisabled(await SharedPreferences.getInstance()),
      true,
    );
    expect(
      await UploadSettings.shouldUseMultipart(
        loadSiteSettings: () async => throw StateError('不应读取配置'),
      ),
      false,
    );
    await prefs.setBool(UploadSettings.forceDisableMultipartKey, false);
    expect(
      await UploadSettings.shouldUseMultipart(
        loadSiteSettings: () async => {'enable_direct_s3_uploads': true},
      ),
      true,
    );
  });

  test('配置等待期间关闭分片也应生效', () async {
    expect(
      await UploadSettings.shouldUseMultipart(
        loadSiteSettings: () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(UploadSettings.forceDisableMultipartKey, true);
          return {'enable_direct_s3_uploads': true};
        },
      ),
      false,
    );
  });
}
