import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../l10n/s.dart';
import '../pages/chat/channel/chat_channel_page.dart';
import '../pages/topic_detail_page/topic_detail_page.dart';
import '../utils/notification_navigation.dart';
import 'notification_avatar_loader.dart';

/// 全局 NavigatorKey，用于通知点击时导航
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// APK 更新通知的固定 ID，便于复用/取消同一条进度通知
const int apkUpdateNotificationId = 99001;

const String _apkUpdateChannelId = 'apk_update';

const MethodChannel _conversationShortcutChannel =
    MethodChannel('com.fluxdo/conversation_shortcut');

/// 系统通知所属的会话。
///
/// Android 11+ 据此发会话通知:发送者头像占左侧图标位、右下角叠应用
/// 角标;其他平台只用 [senderUsername] 取头像。
class NotificationConversation {
  const NotificationConversation({
    required this.id,
    required this.title,
    required this.senderUsername,
    required this.selfName,
    required this.isGroup,
  });

  /// 会话快捷方式 id。会话图标取自快捷方式,一个 id 只有一个图标,所以
  /// 要带上发送者:同一话题/频道里不同人的通知各自显示自己的头像。
  final String id;

  /// 通知首行标题(Android 会话通知取它,而非 show 的 title)。
  final String title;

  final String senderUsername;

  /// 当前用户名。MessagingStyle 要求「自己」有非空名字(不显示);为空
  /// 时退回普通通知样式。
  final String selfName;

  /// 群聊排版在正文前显示发送者名,单聊排版不显示。
  final bool isGroup;
}

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
    // "message:{topicId}[:{postNumber}]"(私信,走私信平行视界栈)或
    // "chat:{channelId}"(聊天,直达聊天窗)。
    if (payload.startsWith('chat:')) {
      final channelId = int.tryParse(payload.substring(5));
      if (channelId == null) return;
      final chatPage = ChatChannelPage(channelId: channelId);
      final chatContext = navigatorKey.currentContext;
      if (chatContext != null && chatContext.mounted) {
        openNotificationPage(chatContext, chatPage);
        return;
      }
      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => chatPage),
      );
      return;
    }
    final isMessage = payload.startsWith('message:');
    if (!isMessage && !payload.startsWith('topic:')) return;
    final parts = payload.substring(isMessage ? 8 : 6).split(':');
    final topicId = int.tryParse(parts[0]);
    final postNumber = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (topicId == null) return;

    debugPrint(
      '[LocalNotification] 跳转到${isMessage ? "私信" : "话题"}: $topicId, 帖子: $postNumber',
    );

    // 与应用内通知落点一致:大屏页面弹窗、窄屏全屏路由(私信/话题
    // 同一入口,不再写工作区栈/切 tab)。拿不到 context(冷启动时通知
    // 先于根 widget 树就绪)退化为直接 push。
    final page = TopicDetailPage(
      topicId: topicId,
      scrollToPostNumber: postNumber,
    );
    final context = navigatorKey.currentContext;
    if (context != null && context.mounted) {
      openNotificationPage(context, page);
      return;
    }
    navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => page),
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
  ///
  /// [conversation] 通知所属会话,用于显示发送者头像;头像加载失败或
  /// 超时则发无头像通知。
  Future<void> show({
    required String title,
    required String body,
    int? id,
    int? topicId,
    int? postNumber,
    bool isPrivateMessage = false,
    int? chatChannelId,
    NotificationConversation? conversation,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    if (!_permissionGranted) {
      debugPrint('[LocalNotification] 权限未授予，跳过通知');
      return;
    }

    final avatar = conversation == null
        ? null
        : await NotificationAvatarLoader.load(conversation.senderUsername);
    // 「自己」名字为空时 MessagingStyle 会在原生侧抛异常、连通知一起丢,
    // 宁可退回普通样式。
    final asConversation = conversation != null &&
        conversation.selfName.isNotEmpty &&
        Platform.isAndroid &&
        await _pushConversationShortcut(conversation, avatar);
    final details = await _buildDetails(
      avatar,
      body: body,
      conversation: asConversation ? conversation : null,
      altText: conversation?.senderUsername,
    );

    final notificationId = id ?? DateTime.now().millisecondsSinceEpoch.remainder(100000);
    
    // 构建 payload 用于点击回调:私信用 message: 前缀,走私信自己的
    // 平行视界栈,不能跟普通话题共用 topic: 前缀(否则左栏会显示信息流)。
    // chat 通知用 chat: 前缀直达聊天窗。
    String? payload;
    if (chatChannelId != null) {
      payload = 'chat:$chatChannelId';
    } else if (topicId != null) {
      final prefix = isPrivateMessage ? 'message' : 'topic';
      payload = postNumber != null
          ? '$prefix:$topicId:$postNumber'
          : '$prefix:$topicId';
    }
    
    try {
      await _plugin.show(id: notificationId, title: title, body: body, notificationDetails: details, payload: payload);
    } finally {
      if (asConversation) await _removeConversationShortcut(conversation.id);
    }
    debugPrint('[LocalNotification] 已发送: $title, payload=$payload');
  }

  /// 发布会话快捷方式(Android 11+),成功才能以会话通知呈现。
  Future<bool> _pushConversationShortcut(
    NotificationConversation conversation,
    NotificationAvatar? avatar,
  ) async {
    try {
      final ok = await _conversationShortcutChannel.invokeMethod<bool>('push', {
        'id': conversation.id,
        'label': conversation.title,
        'senderName': conversation.senderUsername,
        'senderKey': conversation.senderUsername.toLowerCase(),
        'icon': avatar?.png,
      });
      return ok ?? false;
    } catch (e) {
      debugPrint('[LocalNotification] 会话快捷方式发布失败: $e');
      return false;
    }
  }

  /// 通知发出后撤掉动态快捷方式:系统发通知时已同步缓存了它,撤掉只是
  /// 不让话题堆进桌面图标的长按菜单。
  Future<void> _removeConversationShortcut(String id) async {
    try {
      await _conversationShortcutChannel.invokeMethod<void>('remove', {'id': id});
    } catch (e) {
      debugPrint('[LocalNotification] 会话快捷方式撤销失败: $e');
    }
  }

  /// 构建 Discourse 通知的各平台参数,[avatar] 按各平台能力挂上:
  /// - Android:传入 [conversation](会话快捷方式已发布)时发会话通知,
  ///   头像占左侧图标位;否则作右侧 largeIcon;
  /// - iOS/macOS:通知附件缩略图(只认文件,且会被系统移走);
  /// - Windows:替换应用图标位(只认文件路径);
  /// - Linux:DBus image-data(原始像素直传)。
  Future<NotificationDetails> _buildDetails(
    NotificationAvatar? avatar, {
    required String body,
    NotificationConversation? conversation,
    String? altText,
  }) async {
    List<DarwinNotificationAttachment>? darwinAttachments;
    var windowsImages = const <WindowsImage>[];
    LinuxNotificationIcon? linuxIcon;
    if (avatar != null) {
      try {
        if (Platform.isIOS || Platform.isMacOS) {
          final file = await avatar.writeFile(unique: true);
          darwinAttachments = [DarwinNotificationAttachment(file.path)];
        } else if (Platform.isWindows) {
          final file = await avatar.writeFile(unique: false);
          windowsImages = [
            WindowsImage(
              Uri.file(file.path, windows: true),
              altText: altText ?? '',
              placement: WindowsImagePlacement.appLogoOverride,
            ),
          ];
        } else if (Platform.isLinux && avatar.rgba != null) {
          linuxIcon = ByteDataLinuxIcon(
            LinuxRawIconData(
              data: avatar.rgba!,
              width: avatar.side,
              height: avatar.side,
              channels: 4,
              hasAlpha: true,
            ),
          );
        }
      } catch (e) {
        debugPrint('[LocalNotification] 头像落盘失败: $e');
      }
    }

    final androidDetails = AndroidNotificationDetails(
      'discourse_notifications',
      S.current.notification_channelDiscourse,
      channelDescription: S.current.notification_channelDiscourseDesc,
      importance: Importance.high,
      priority: Priority.high,
      // 会话通知的头像由快捷方式图标承担,不再设 largeIcon,免得左右
      // 各显示一份。
      largeIcon: avatar != null && conversation == null
          ? ByteArrayAndroidBitmap(avatar.png)
          : null,
      styleInformation: conversation == null
          ? null
          : MessagingStyleInformation(
              Person(name: conversation.selfName),
              conversationTitle: conversation.title,
              groupConversation: conversation.isGroup,
              messages: [
                Message(
                  body,
                  DateTime.now(),
                  Person(
                    name: conversation.senderUsername,
                    key: conversation.senderUsername.toLowerCase(),
                    icon: avatar != null ? ByteArrayAndroidIcon(avatar.png) : null,
                  ),
                ),
              ],
            ),
      shortcutId: conversation?.id,
    );

    final darwinDetails = DarwinNotificationDetails(
      attachments: darwinAttachments,
    );

    return NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      windows: WindowsNotificationDetails(images: windowsImages),
      linux: linuxIcon != null ? LinuxNotificationDetails(icon: linuxIcon) : null,
    );
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
