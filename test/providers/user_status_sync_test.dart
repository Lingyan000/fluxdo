import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/message_bus_service_provider.dart';
import 'package:fluxdo/providers/message_bus/session_channel_providers.dart';
import 'package:fluxdo/providers/message_bus/topic_tracking_providers.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/message_bus_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';

class _NoMessageBusInit extends MessageBusInitNotifier {
  @override
  void build() {}
}

class _Bus implements MessageBusService {
  final callbacks = <String, MessageBusCallback>{};
  final cursors = <String, int>{};
  @override
  void subscribe(
    String channel,
    MessageBusCallback callback, {
    int lastMessageId = -1,
  }) {
    callbacks[channel] = callback;
    cursors[channel] = lastMessageId;
  }

  @override
  void unsubscribe(String channel, [MessageBusCallback? callback]) {
    if (callback == null || callbacks[channel] == callback) {
      callbacks.remove(channel);
    }
  }

  void send(Map<String, dynamic> data) => callbacks['/user-status']!(
    MessageBusMessage(channel: '/user-status', messageId: 12, data: data),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Service implements DiscourseService {
  @override
  final currentUserNotifier = ValueNotifier<User?>(null);
  final response = Completer<User?>();
  @override
  Future<User?> getCurrentUser() => response.future;
  @override
  Future<bool> isLoggedIn() async => false;
  @override
  Future<User?> getPreloadedCurrentUser() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _Bus bus;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PreloadedDataService().debugSeed(
      currentUser: {
        'id': 1,
        'username': 'me',
        'avatar_template': '/old.png',
        'status': {
          'description': '原状态',
          'emoji': 'coffee',
          'message_bus_last_id': 7,
        },
      },
      loaded: true,
    );
    bus = _Bus();
    container = ProviderContainer(
      overrides: [
        discourseServiceProvider.overrideWithValue(_Service()),
        messageBusServiceProvider.overrideWithValue(bus),
        messageBusInitProvider.overrideWith(_NoMessageBusInit.new),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    PreloadedDataService().debugSeed(loaded: false);
  });

  test('按服务端游标订阅，广播更新当前用户和其他用户，清除覆盖旧快照', () async {
    await container.read(currentUserProvider.future);
    final old = UserStatus(description: '旧快照', emoji: 'coffee');
    final other = userStatusForProvider((userId: 2, initial: old));
    final listener = container.listen(other, (_, _) {});
    expect(listener.read(), same(old));
    expect(bus.cursors['/user-status'], 7);
    bus.send({
      '1': {'description': '跨端更新', 'emoji': 'smile'},
      '2': {'description': '新状态', 'emoji': 'star'},
    });
    expect(
      container.read(currentUserProvider).value!.status!.description,
      '跨端更新',
    );
    expect(container.read(other)!.description, '新状态');
    bus.send({'1': null, '2': null, '3': '无效数据'});
    expect(container.read(currentUserProvider).value!.status, isNull);
    expect(container.read(other), isNull);
    expect(container.read(userStatusProvider).containsKey(3), false);
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(
      (jsonDecode(prefs.getString('current_user_cache')!) as Map)['status'],
      isNull,
    );
    expect(PreloadedDataService().currentUserSync!['status'], isNull);
    listener.close();
    container.invalidate(currentUserProvider);
    await container.pump();
    expect(bus.callbacks.keys, ['/user-status']);
  });

  test('退出登录时取消状态订阅并清空广播缓存', () async {
    await container.read(currentUserProvider.future);
    container.read(userStatusProvider);
    bus.send({
      '2': {'description': '在线', 'emoji': 'coffee'},
    });
    expect(container.read(userStatusProvider), isNotEmpty);
    PreloadedDataService().debugSeed(loaded: true);
    container.invalidate(currentUserProvider);
    await container.read(currentUserProvider.future);
    await container.pump();
    expect(container.read(userStatusProvider), isEmpty);
    expect(bus.callbacks, isEmpty);
  });

  test('本地保存更新可见状态，当前用户与其他用户状态到期自动消失', () async {
    await container.read(currentUserProvider.future);
    final own = userStatusForProvider((userId: 1, initial: null));
    final ownListener = container.listen(own, (_, _) {});
    final deadline = DateTime.now().add(const Duration(milliseconds: 100));
    final status = UserStatus(
      description: '短暂状态',
      emoji: 'coffee',
      endsAt: deadline,
    );
    await container
        .read(currentUserProvider.notifier)
        .updateIdentity('me', status: status);
    expect(container.read(own), same(status));
    final other = userStatusForProvider((userId: 2, initial: status));
    final otherListener = container.listen(other, (_, _) {});
    expect(otherListener.read(), same(status));
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(container.read(currentUserProvider).value!.status, isNull);
    expect(container.read(own), isNull);
    expect(container.read(other), isNull);
    ownListener.close();
    otherListener.close();
  });

  test('新状态替换旧的到期任务，头像标识清除同步到会话缓存', () async {
    await container.read(currentUserProvider.future);
    final notifier = container.read(currentUserProvider.notifier);
    await notifier.updateIdentity(
      'me',
      status: UserStatus(
        description: '临时',
        emoji: 'coffee',
        endsAt: DateTime.now().add(const Duration(milliseconds: 60)),
      ),
    );
    final replacement = UserStatus(description: '长期', emoji: 'star');
    await notifier.updateIdentity('me', status: replacement);
    final identity = User(
      id: 1,
      username: 'me',
      trustLevel: 1,
      avatarTemplate: '/new.png',
      flairUrl: 'star',
      flairGroupId: 3,
    );
    await notifier.updateIdentity('me', identity: identity);
    expect(container.read(currentUserProvider).value!.flairUrl, 'star');
    await notifier.updateIdentity(
      'me',
      identity: User(
        id: 1,
        username: 'me',
        trustLevel: 1,
        avatarTemplate: '/new.png',
      ),
    );
    expect(container.read(currentUserProvider).value!.flairUrl, isNull);
    expect(PreloadedDataService().currentUserSync!['flair_url'], isNull);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(
      container.read(currentUserProvider).value!.status,
      same(replacement),
    );
  });
}
