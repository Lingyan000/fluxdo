import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:workmanager/workmanager.dart';

import '../../l10n/s.dart';
import 'notification_task_handler.dart';
import 'ios_background_fetch.dart';

/// 后台通知统一管理入口
///
/// 根据平台选择不同的后台保活策略：
/// - Android: 前台服务保活进程，主 Isolate 的 MessageBus 长轮询继续运行
/// - iOS: BGTaskScheduler 定期唤醒，单次 HTTP 拉取检查新通知
/// - 桌面: 无需特殊处理
class BackgroundNotificationService {
  static final BackgroundNotificationService _instance =
      BackgroundNotificationService._internal();
  factory BackgroundNotificationService() => _instance;
  BackgroundNotificationService._internal();

  bool _enabled = false;
  bool _androidInited = false;

  /// 初始化（在 main() 中调用一次）
  Future<void> initialize() async {
    if (Platform.isIOS || Platform.isAndroid) {
      await (_workmanagerReady ??= Workmanager().initialize(callbackDispatcher));
    }
  }

  /// 启用后台通知（App 切后台时调用）
  Future<void> enable(int userId) async {
    if (_enabled) return;
    _enabled = true;
    debugPrint('[BackgroundNotification] 启用后台通知, userId=$userId');

    if (Platform.isAndroid) {
      await _startAndroidForegroundService();
    } else if (Platform.isIOS) {
      await _registerIOSPeriodicTask(userId);
    }
    // 桌面平台无需操作
  }

  /// 禁用后台通知（App 回前台时调用）
  Future<void> disable() async {
    if (!_enabled) return;
    _enabled = false;
    debugPrint('[BackgroundNotification] 禁用后台通知');

    if (Platform.isAndroid) {
      await _stopAndroidForegroundService();
    } else if (Platform.isIOS) {
      await _cancelIOSTasks();
    }
  }

  bool get isEnabled => _enabled;

  // ==================== Android ====================

  void _initAndroidForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'foreground_service',
        channelName: S.current.notification_channelBackground,
        channelDescription: S.current.notification_channelBackgroundDesc,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        // 使用应用默认图标
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // 不需要周期性事件，主 Isolate 的 MessageBus 已在轮询
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _startAndroidForegroundService() async {
    // 延迟到首次启动服务时初始化，此时 navigatorKey.currentContext 已可用
    if (!_androidInited) {
      _androidInited = true;
      _initAndroidForegroundTask();
    }

    final serviceRunning = await FlutterForegroundTask.isRunningService;
    if (serviceRunning) {
      debugPrint('[BackgroundNotification] Android 前台服务已在运行');
      return;
    }

    await FlutterForegroundTask.startService(
      serviceId: 200,
      notificationTitle: 'FluxDO',
      notificationText: S.current.notification_backgroundRunning,
      callback: startNotificationTaskHandler,
    );
    debugPrint('[BackgroundNotification] Android 前台服务已启动');
  }

  Future<void> _stopAndroidForegroundService() async {
    final serviceRunning = await FlutterForegroundTask.isRunningService;
    if (!serviceRunning) return;

    await FlutterForegroundTask.stopService();
    debugPrint('[BackgroundNotification] Android 前台服务已停止');
  }

  // ==================== iOS ====================

  Future<void>? _workmanagerReady;
  Future<void> _pluginWakeQueue = Future.value();
  bool? _pluginWake;

  Future<void> setPluginWake(bool enabled) {
    if (!Platform.isIOS && !Platform.isAndroid) return Future.value();
    final next = _pluginWakeQueue.then((_) async {
      if (_pluginWake == enabled) return;
      await initialize();
      if (enabled) {
        await Workmanager().registerPeriodicTask(kMetaverseWakeTask, kMetaverseWakeTask,
          frequency: const Duration(minutes: 15), initialDelay: const Duration(minutes: 15),
          constraints: Constraints(networkType: NetworkType.connected), existingWorkPolicy: ExistingPeriodicWorkPolicy.keep);
      } else {
        await Workmanager().cancelByUniqueName(kMetaverseWakeTask);
      }
      _pluginWake = enabled;
    });
    _pluginWakeQueue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _registerIOSPeriodicTask(int userId) async {
    // 先保存 userId 供独立 Isolate 使用
    await saveBackgroundUserId(userId);

    await Workmanager().registerPeriodicTask(
      kNotificationPollTask,
      kNotificationPollTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );
    debugPrint('[BackgroundNotification] iOS 定期任务已注册');
  }

  Future<void> _cancelIOSTasks() async {
    await Workmanager().cancelByUniqueName(kNotificationPollTask);
    debugPrint('[BackgroundNotification] iOS 定期任务已取消');
  }
}
