import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/s.dart';
import '../navigation/nav_action_bus.dart';
import '../pages/topic_detail_page/topic_detail_page.dart';
import '../providers/selected_topic_provider.dart';
import '../widgets/layout/master_detail_layout.dart';

/// 全局 NavigatorKey，用于通知点击时导航
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// APK 更新通知的固定 ID，便于复用/取消同一条进度通知
const int apkUpdateNotificationId = 99001;

const String _apkUpdateChannelId = 'apk_update';

/// 本地系统通知服务
class LocalNotificationService {
  static final LocalNotificationService _instance = LocalNotificationService._internal();
  factory LocalNotificationService() => _instance;
  LocalNotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _permissionGranted = false;

  /// 初始化通知服务
  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const linuxSettings = LinuxInitializationSettings(defaultActionName: 'Open');
    const windowsSettings = WindowsInitializationSettings(
      appName: 'FluxDO',
      appUserModelId: 'Com.FluxDO.FluxDO',
      guid: 'e965ef8c-b676-47c1-b6e7-297d63942974',
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
      linux: linuxSettings,
      windows: windowsSettings,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
    _initialized = true;
    debugPrint('[LocalNotification] 初始化完成');
    
    // 请求通知权限 (Android 13+)
    await _requestPermission();
  }

  /// 通知点击回调
  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('[LocalNotification] 通知被点击: payload=${response.payload}');

    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    // payload 格式: "topic:{topicId}[:{postNumber}]" 或
    // "message:{topicId}[:{postNumber}]"(私信,走私信平行视界栈)。
    final isMessage = payload.startsWith('message:');
    if (!isMessage && !payload.startsWith('topic:')) return;
    final parts = payload.substring(isMessage ? 8 : 6).split(':');
    final topicId = int.tryParse(parts[0]);
    final postNumber = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (topicId == null) return;

    debugPrint(
      '[LocalNotification] 跳转到${isMessage ? "私信" : "话题"}: $topicId, 帖子: $postNumber',
    );

    // 宽屏走平行视界(跟应用内点通知/点列表一致的左右栏表现)。
    // 两种情况退化成独立全屏路由:
    // - 拿不到 context(冷启动时通知先于根 widget 树就绪);
    // - 窄屏单栏——select() 写栈后没有任何东西会推出详情页
    //   (TopicsScreen 只在宽→窄切换/tab 重新激活时补 push,已在目标
    //   tab 上时 requestNavDestination 又是 no-op),必须直接开全屏页。
    final context = navigatorKey.currentContext;
    if (context != null &&
        context.mounted &&
        MasterDetailLayout.canShowBothPanesFor(context)) {
      final container = ProviderScope.containerOf(context);
      if (isMessage) {
        container
            .read(selectedMessageProvider.notifier)
            .select(topicId: topicId, scrollToPostNumber: postNumber);
        container.read(navDestinationRequestProvider.notifier).state =
            NavDestinationRequest(
              targetId: NavEntryIds.messages,
              nonce: DateTime.now().millisecondsSinceEpoch,
            );
      } else {
        container
            .read(selectedTopicProvider.notifier)
            .select(topicId: topicId, scrollToPostNumber: postNumber);
        container.read(navDestinationRequestProvider.notifier).state =
            NavDestinationRequest(
              targetId: NavEntryIds.home,
              nonce: DateTime.now().millisecondsSinceEpoch,
            );
      }
      return;
    }

    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topicId,
          scrollToPostNumber: postNumber,
          // 中途拉宽窗口时自动收回对应的平行视界栈,私信必须回私信栏
          autoSwitchToMasterDetail: true,
          stackProvider: isMessage
              ? selectedMessageProvider
              : selectedTopicProvider,
        ),
      ),
    );
  }

  /// 请求通知权限
  Future<void> _requestPermission() async {
    // Android 平台请求权限
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      final granted = await androidPlugin.requestNotificationsPermission();
      _permissionGranted = granted ?? false;
      debugPrint('[LocalNotification] Android 权限: $_permissionGranted');
    } else {
      // 非 Android 平台默认已授权
      _permissionGranted = true;
    }
  }

  /// 显示通知
  Future<void> show({
    required String title,
    required String body,
    int? id,
    int? topicId,
    int? postNumber,
    bool isPrivateMessage = false,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    if (!_permissionGranted) {
      debugPrint('[LocalNotification] 权限未授予，跳过通知');
      return;
    }

    final androidDetails = AndroidNotificationDetails(
      'discourse_notifications',
      S.current.notification_channelDiscourse,
      channelDescription: S.current.notification_channelDiscourseDesc,
      importance: Importance.high,
      priority: Priority.high,
    );

    const darwinDetails = DarwinNotificationDetails();

    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      windows: const WindowsNotificationDetails(),
    );

    final notificationId = id ?? DateTime.now().millisecondsSinceEpoch.remainder(100000);
    
    // 构建 payload 用于点击回调:私信用 message: 前缀,走私信自己的
    // 平行视界栈,不能跟普通话题共用 topic: 前缀(否则左栏会显示信息流)。
    String? payload;
    if (topicId != null) {
      final prefix = isPrivateMessage ? 'message' : 'topic';
      payload = postNumber != null
          ? '$prefix:$topicId:$postNumber'
          : '$prefix:$topicId';
    }
    
    await _plugin.show(id: notificationId, title: title, body: body, notificationDetails: details, payload: payload);
    debugPrint('[LocalNotification] 已发送: $title, payload=$payload');
  }

  /// 显示 APK 下载进度通知（持续更新同一条）。
  ///
  /// indeterminate=true 时显示无限循环进度条（用于"连接中/校验中"等阶段）。
  Future<void> showApkProgress({
    required String title,
    String? body,
    int progress = 0,
    bool indeterminate = false,
    int id = apkUpdateNotificationId,
  }) async {
    if (!_initialized) {
      await initialize();
    }
    if (!_permissionGranted) return;

    final androidDetails = AndroidNotificationDetails(
      _apkUpdateChannelId,
      S.current.update_notification_channel,
      channelDescription: S.current.update_notification_channelDesc,
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: 100,
      progress: progress,
      indeterminate: indeterminate,
      ongoing: true,
      onlyAlertOnce: true,
      channelShowBadge: false,
      playSound: false,
      enableVibration: false,
    );

    final details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  /// 显示 APK 下载完成通知（点击触发安装由 ota_update 自行发起 intent，
  /// 这里只是给用户一个可点击的入口拉起 App，不需要 payload）。
  Future<void> showApkComplete({
    required String title,
    required String body,
    int id = apkUpdateNotificationId,
  }) async {
    if (!_initialized) {
      await initialize();
    }
    if (!_permissionGranted) return;

    final androidDetails = AndroidNotificationDetails(
      _apkUpdateChannelId,
      S.current.update_notification_channel,
      channelDescription: S.current.update_notification_channelDesc,
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
    );

    final details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  /// 取消指定通知
  Future<void> cancelNotification(int id) async {
    await _plugin.cancel(id: id);
  }
}
