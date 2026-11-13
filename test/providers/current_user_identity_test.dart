import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';

class _CurrentUser extends CurrentUserNotifier {
  @override
  User build() => User(
    id: 1,
    trustLevel: 0,
    username: 'tester',
    avatarTemplate: '/old.png',
  );
}

class _Service implements DiscourseService {
  final response = Completer<User?>();
  @override
  final currentUserNotifier = ValueNotifier<User?>(null);
  @override
  Future<User?> getPreloadedCurrentUser() async =>
      User.fromJson(PreloadedDataService().currentUserSync!);
  @override
  Future<User?> getCurrentUser() async {
    final user = await response.future;
    currentUserNotifier.value = user;
    return user;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('成功保存立即更新会话和磁盘缓存，旧刷新不能回写', () async {
    PreloadedDataService().debugSeed(
      currentUser: {
        'id': 1,
        'username': 'tester',
        'avatar_template': '/old.png',
      },
      loaded: true,
    );
    addTearDown(() => PreloadedDataService().debugSeed(loaded: false));
    final service = _Service();
    final container = ProviderContainer(
      overrides: [
        discourseServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWith(_CurrentUser.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(currentUserProvider.future);
    final notifier = container.read(currentUserProvider.notifier);
    final refresh = notifier.refreshSilently(force: true);
    await Future<void>.delayed(Duration.zero);
    final status = UserStatus(
      description: '专注中',
      emoji: 'headphones',
      endsAt: DateTime.utc(2027),
    );
    await notifier.updateIdentity(
      'tester',
      avatarTemplate: '/new.png',
      status: status,
    );
    expect(
      container.read(currentUserProvider).value!.avatarTemplate,
      '/new.png',
    );
    expect(service.currentUserNotifier.value!.status, same(status));
    service.response.complete(
      User(
        id: 1,
        trustLevel: 0,
        username: 'tester',
        avatarTemplate: '/old.png',
        status: UserStatus(description: '旧状态', emoji: 'coffee'),
      ),
    );
    await refresh;
    expect(container.read(currentUserProvider).value!.status, same(status));
    expect(service.currentUserNotifier.value!.status, same(status));
    expect(
      PreloadedDataService().currentUserSync!['avatar_template'],
      '/new.png',
    );
    expect(
      PreloadedDataService().currentUserSync!['status']['description'],
      '专注中',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('current_user_cache'),
      contains('2027-01-01T00:00:00.000Z'),
    );
    await notifier.updateIdentity('someone_else', clearStatus: true);
    expect(container.read(currentUserProvider).value!.status, same(status));
    // 保存后才发起的刷新也可能读到旧资料，状态应继续使用当前会话值。
    await notifier.refreshSilently(force: true, preserveStatus: true);
    expect(
      container.read(currentUserProvider).value!.status?.description,
      status.description,
    );
    expect(service.currentUserNotifier.value!.status?.description,
        status.description);
    await notifier.updateIdentity('tester', clearStatus: true);
    expect(container.read(currentUserProvider).value!.status, isNull);
    expect(service.currentUserNotifier.value!.status, isNull);
    expect(PreloadedDataService().currentUserSync!['status'], isNull);
    await notifier.refreshSilently(force: true, preserveStatus: true);
    expect(container.read(currentUserProvider).value!.status, isNull);
    expect(service.currentUserNotifier.value!.status, isNull);
    // 主动刷新仍可以获取其他端修改后的状态。
    await notifier.refreshSilently(force: true);
    expect(container.read(currentUserProvider).value!.status?.description,
        '旧状态');
  });
}
