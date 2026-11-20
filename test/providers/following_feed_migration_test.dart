import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/navigation/nav_action_bus.dart';
import 'package:fluxdo/providers/following_feed_migration_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('旧导航原位迁移、去重，新用户不自动添加入口', () {
    expect(
      NavEntryIds.migrateLegacyIds([
        'home',
        'seeking',
        'profile',
        'following_feed',
      ]),
      ['home', 'following_feed', 'profile'],
    );
    expect(NavEntryIds.migrateLegacyIds(['home', 'profile']), [
      'home',
      'profile',
    ]);
  });
  test('展示时同步结束引导，旧名单仍可读取', () async {
    SharedPreferences.setMockInitialValues({
      'seeking_config': '{"users":["alice","bob"]}',
    });
    final prefs = await SharedPreferences.getInstance();
    final notifier = FollowingFeedMigrationNotifier(prefs);
    addTearDown(notifier.dispose);
    expect(notifier.state.showGuide, true);
    final saving = notifier.markSeen();
    expect(notifier.state.showGuide, false);
    await saving;
    expect(notifier.state.users, ['alice', 'bob']);
    expect(prefs.getString('seeking_config'), '{"users":["alice","bob"]}');
    expect(FollowingFeedMigration.read(prefs).dismissed, true);
  });
  test('损坏的旧配置仍显示说明但不阻止页面，新用户不显示', () async {
    SharedPreferences.setMockInitialValues({'seeking_config': 'broken'});
    var prefs = await SharedPreferences.getInstance();
    expect(FollowingFeedMigration.read(prefs).showGuide, true);
    expect(FollowingFeedMigration.read(prefs).users, isEmpty);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    expect(FollowingFeedMigration.read(prefs).showGuide, false);
  });
}
