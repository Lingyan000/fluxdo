import 'package:dio/dio.dart';
import 'package:ota_update/ota_update.dart';

import '../l10n/s.dart';
import 'update_service.dart';

/// APK 下载状态
enum ApkDownloadStatus {
  idle,
  downloading,
  verifying,
  installing,
  completed,
  error,
}

/// APK 下载进度
class ApkDownloadProgress {
  final ApkDownloadStatus status;
  final int progress; // 0-100
  final String? error;

  ApkDownloadProgress({
    required this.status,
    this.progress = 0,
    this.error,
  });
}

/// APK 下载安装服务
class ApkDownloadService {
  final Dio _dio;
  bool _cancelled = false;

  ApkDownloadService({Dio? dio}) : _dio = dio ?? Dio();

  /// 下载并安装 APK
  ///
  /// 返回进度 Stream
  Stream<ApkDownloadProgress> downloadAndInstall(ApkAsset asset) async* {
    _cancelled = false;

    // 应用用户配置的 GitHub 反代前缀（未配置时保持直连）
    final githubProxy = await UpdateService.getGithubProxy();
    final downloadUrl =
        UpdateService.applyGithubProxy(asset.downloadUrl, githubProxy);

    // 阶段 1：获取 SHA256 校验和（如果有）
    String? expectedSha256;
    if (asset.sha256Url != null) {
      yield ApkDownloadProgress(
        status: ApkDownloadStatus.verifying,
        progress: 0,
      );

      try {
        expectedSha256 = await _fetchSha256Checksum(
          UpdateService.applyGithubProxy(asset.sha256Url!, githubProxy),
        );
      } catch (e) {
        // SHA256 获取失败不影响下载
      }
    }

    if (_cancelled) return;

    // 阶段 2：使用 ota_update 下载并安装 APK
    yield ApkDownloadProgress(
      status: ApkDownloadStatus.downloading,
      progress: 0,
    );

    try {
      final otaEvent = OtaUpdate().execute(
        downloadUrl,
        destinationFilename: asset.name,
        sha256checksum: expectedSha256,
      );

      await for (final event in otaEvent) {
        if (_cancelled) {
          return;
        }

        switch (event.status) {
          case OtaStatus.DOWNLOADING:
            final progress = int.tryParse(event.value ?? '0') ?? 0;
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.downloading,
              progress: progress,
            );
            break;

          case OtaStatus.INSTALLING:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.installing,
              progress: 100,
            );
            break;

          case OtaStatus.ALREADY_RUNNING_ERROR:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.error,
              error: S.current.download_alreadyInProgress,
            );
            break;

          case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.error,
              error: S.current.download_noInstallPermission,
            );
            break;

          case OtaStatus.INTERNAL_ERROR:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.error,
              error: event.value ?? S.current.download_internalError,
            );
            break;

          case OtaStatus.DOWNLOAD_ERROR:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.error,
              error: S.current.download_failedWithError(event.value ?? S.current.error_unknown),
            );
            break;

          case OtaStatus.CHECKSUM_ERROR:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.error,
              error: S.current.download_checksumFailed,
            );
            break;

          case OtaStatus.INSTALLATION_DONE:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.completed,
              progress: 100,
            );
            break;

          case OtaStatus.INSTALLATION_ERROR:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.error,
              error: S.current.download_installFailed(event.value ?? S.current.error_unknown),
            );
            break;

          case OtaStatus.CANCELED:
            // 用户取消，不需要额外处理
            return;
        }
      }
    } catch (e) {
      yield ApkDownloadProgress(
        status: ApkDownloadStatus.error,
        error: S.current.download_failed('$e'),
      );
    }
  }

  /// 获取 SHA256 校验和
  Future<String?> _fetchSha256Checksum(String url) async {
    try {
      final response = await _dio.get<String>(url);
      if (response.statusCode == 200 && response.data != null) {
        // SHA256 文件格式通常为："hash  filename" 或仅 "hash"
        final content = response.data!.trim();
        final parts = content.split(RegExp(r'\s+'));
        return parts.first;
      }
    } catch (e) {
      // 忽略获取 SHA256 失败
    }
    return null;
  }

  /// 取消下载
  void cancelDownload() {
    _cancelled = true;
  }
}
