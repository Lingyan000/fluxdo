import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/notification_providers.dart';

/// 通知计数 provider:冷启动渐进 emit(缓存用户无计数 → 接口终态带
/// 计数)下徽章不得被首个 emit 钉死;实时更新后服务端旧值不得回刷。
class _FakeCurrentUser extends CurrentUserNotifier {
  _FakeCurrentUser(this._initial);
  final User? _initial;

  @override
  Future<User?> build() async => _initial;

  void emit(User? user) => state = AsyncValue.data(user);
}

User _user({required int id, int allUnread = 0}) => User(
  id: id,
  username: 'u$id',
  trustLevel: 1,
  allUnreadNotificationsCount: allUnread,
  unreadNotifications: allUnread,
);

void main() {
  test('冷启动渐进 emit:缓存用户(计数0)后到达的真实计数生效', () async {
    final fake = _FakeCurrentUser(_user(id: 1, allUnread: 0));
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWith(() => fake)],
    );
    addTearDown(container.dispose);

    await container.read(currentUserProvider.future);
    expect(
      container.read(notificationCountStateProvider).allUnread,
      0,
    );

    // 同一 id,接口终态带真实计数(渐进 emit 第二拍)
    fake.emit(_user(id: 1, allUnread: 7));
    await container.pump();
    expect(container.read(notificationCountStateProvider).allUnread, 7);
  });

  test('实时更新后,服务端过期值不再回刷徽章', () async {
    final fake = _FakeCurrentUser(_user(id: 1, allUnread: 3));
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWith(() => fake)],
    );
    addTearDown(container.dispose);

    await container.read(currentUserProvider.future);
    expect(container.read(notificationCountStateProvider).allUnread, 3);

    // MessageBus 实时推送 5
    container
        .read(notificationCountStateProvider.notifier)
        .update(allUnread: 5);
    expect(container.read(notificationCountStateProvider).allUnread, 5);

    // refreshSilently 带过期值 3 → 不得覆盖实时值
    fake.emit(_user(id: 1, allUnread: 3));
    await container.pump();
    expect(container.read(notificationCountStateProvider).allUnread, 5);
  });

  test('markAllRead 后服务端旧值不复活徽章;换账号重置', () async {
    final fake = _FakeCurrentUser(_user(id: 1, allUnread: 9));
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWith(() => fake)],
    );
    addTearDown(container.dispose);

    await container.read(currentUserProvider.future);
    container.read(notificationCountStateProvider.notifier).markAllRead();
    expect(container.read(notificationCountStateProvider).allUnread, 0);

    fake.emit(_user(id: 1, allUnread: 9));
    await container.pump();
    expect(container.read(notificationCountStateProvider).allUnread, 0);

    // 切换账号:新账号服务端计数生效
    fake.emit(_user(id: 2, allUnread: 4));
    await container.pump();
    expect(container.read(notificationCountStateProvider).allUnread, 4);
  });
}
