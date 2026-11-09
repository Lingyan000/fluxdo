import 'dart:async';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';

import '../l10n/s.dart';
import '../services/apk_download_service.dart';
import '../services/local_notification_service.dart';
import '../services/update_service.dart';

/// APK 更新下载的全局状态
class ApkUpdateState {
  final ApkDownloadStatus status;
  final int progress;
  final ApkAsset? asset;
  final String? error;

  const ApkUpdateState({
    this.status = ApkDownloadStatus.idle,
    this.progress = 0,
    this.asset,
    this.error,
  });

  bool get isActive =>
      status == ApkDownloadStatus.downloading ||
      status == ApkDownloadStatus.verifying ||
      status == ApkDownloadStatus.installing;
}

/// 全局唯一的 APK 更新下载控制器。
///
/// 持有 [ApkDownloadService] 的 Stream 订阅，并把状态变化同步到系统通知栏，
/// 让弹窗关闭后下载仍能在后台继续并展示通知。
class ApkUpdateNotifier extends StateNotifier<ApkUpdateState> {
  ApkUpdateNotifier({
    ApkDownloadService? service,
    LocalNotificationService? notification,
  })  : _service = service ?? ApkDownloadService(),
        _notification = notification ?? LocalNotificationService(),
        super(const ApkUpdateState());

  final ApkDownloadService _service;
  final LocalNotificationService _notification;
  StreamSubscription<ApkDownloadProgress>? _sub;

  int _lastNotifiedProgress = -1;
  ApkDownloadStatus? _lastNotifiedStatus;

  /// 启动下载。如果当前正在下载同一个 asset，则直接复用（不重启）。
  Future<void> start(ApkAsset asset) async {
    if (state.isActive && state.asset?.name == asset.name) return;

    await _stopInternal(clearNotification: false);
    _resetNotificationCache();
    state = ApkUpdateState(asset: asset);

    _sub = _service.downloadAndInstall(asset).listen(
      (progress) => _emit(progress, asset),
      onError: (Object error, StackTrace _) {
        _emit(
          ApkDownloadProgress(
            status: ApkDownloadStatus.error,
            error: error.toString(),
          ),
          asset,
        );
      },
    );
  }

  /// 用户主动取消：关闭通知、清空状态
  Future<void> cancel() async {
    await _stopInternal(clearNotification: true);
    _resetNotificationCache();
    state = const ApkUpdateState();
  }

  /// 清空状态（仅在非 active 时有效，例如错误确认后回到初始）
  void reset() {
    if (state.isActive) return;
    _resetNotificationCache();
    unawaited(_notification.cancelNotification(apkUpdateNotificationId));
    state = const ApkUpdateState();
  }

  Future<void> _stopInternal({required bool clearNotification}) async {
    await _service.cancelDownload();
    await _sub?.cancel();
    _sub = null;
    if (clearNotification) {
      await _notification.cancelNotification(apkUpdateNotificationId);
    }
  }

  void _resetNotificationCache() {
    _lastNotifiedProgress = -1;
    _lastNotifiedStatus = null;
  }

  void _emit(ApkDownloadProgress p, ApkAsset asset) {
    state = ApkUpdateState(
      status: p.status,
      progress: p.progress,
      asset: asset,
      error: p.error,
    );
    _syncNotification();
  }

  void _syncNotification() {
    final s = state.status;
    final name = state.asset?.name;

    switch (s) {
      case ApkDownloadStatus.idle:
        return;

      case ApkDownloadStatus.completed:
        _lastNotifiedStatus = s;
        unawaited(
          _notification.showApkComplete(
            title: S.current.update_notification_ready,
            body: name ?? '',
          ),
        );
        return;

      case ApkDownloadStatus.error:
        _lastNotifiedStatus = s;
        unawaited(
          _notification.cancelNotification(apkUpdateNotificationId),
        );
        return;

      case ApkDownloadStatus.verifying:
      case ApkDownloadStatus.installing:
        if (_lastNotifiedStatus == s) return;
        _lastNotifiedStatus = s;
        unawaited(
          _notification.showApkProgress(
            title: S.current.update_notification_downloading,
            body: name,
            indeterminate: true,
          ),
        );
        return;

      case ApkDownloadStatus.downloading:
        final p = state.progress;
        final delta = (p - _lastNotifiedProgress).abs();
        if (_lastNotifiedStatus != s || delta >= 2 || p == 100) {
          _lastNotifiedStatus = s;
          _lastNotifiedProgress = p;
          unawaited(
            _notification.showApkProgress(
              title: S.current.update_notification_downloading,
              body: name,
              progress: p,
              indeterminate: false,
            ),
          );
        }
        return;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final apkUpdateProvider =
    StateNotifierProvider<ApkUpdateNotifier, ApkUpdateState>((ref) {
  return ApkUpdateNotifier();
});
