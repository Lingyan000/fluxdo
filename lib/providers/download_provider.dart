import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/download_item.dart';
import '../pages/download_list_page.dart';
import '../services/download_service.dart';
import '../services/toast_service.dart';
import '../l10n/s.dart';
import 'theme_provider.dart'; // sharedPreferencesProvider

/// 下载记录状态管理
class DownloadNotifier extends StateNotifier<List<DownloadItem>> {
  static const String _storageKey = 'download_items';

  final SharedPreferences _prefs;

  /// 正在进行中的下载 CancelToken，key = item.id
  final Map<String, CancelToken> _cancelTokens = {};

  /// Dio 的下载进度回调可能按网络分片高频触发。若每次都发布 Riverpod 状态，
  /// 下载页会反复重建整份列表，进度 Toast 也会在同一帧收到多次通知。
  final Map<String, int> _lastProgressPublishMicros = {};
  static const int _progressPublishIntervalMicros = 100000;

  DownloadNotifier(this._prefs) : super(_load(_prefs));

  /// 从 SharedPreferences 加载列表
  static List<DownloadItem> _load(SharedPreferences prefs) {
    final jsonStr = prefs.getString(_storageKey);
    if (jsonStr == null) return [];
    try {
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => DownloadItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 发起下载
  Future<void> startDownload({
    required String url,
    String? suggestedFilename,
    String? mimeType,
    int? contentLength,
  }) async {
    // 快速解析初始文件名（不等待网络），立即反馈用户
    final initialFileName = DownloadService.resolveFileName(
      url,
      suggestedFilename: suggestedFilename,
    );

    // 获取下载目录，处理重名
    final dir = await _getDownloadDir();
    var reservation = DownloadService.reserveAvailableDownload(
      directory: dir,
      fileName: initialFileName,
    );
    var savePath = reservation.savePath;
    // 实际文件名可能带编号（如 "file (1).pdf"）
    var actualFileName = p.basename(savePath);

    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final item = DownloadItem(
      id: id,
      url: url,
      fileName: actualFileName,
      savePath: savePath,
      fileSize: contentLength ?? 0,
      createdAt: DateTime.now(),
      mimeType: mimeType,
    );

    // 插入列表头部
    state = [item, ...state];
    _save();

    // 立即显示下载进度 Toast（不等待 HEAD 请求）
    final toastHandle = ToastService.showDownload(actualFileName);

    // 从文件名改进到实际下载均由同一个异常处理覆盖，避免中途失败遗留预留文件。
    final cancelToken = CancelToken();
    _cancelTokens[id] = cancelToken;

    try {
      // 没有建议文件名时，通过 HEAD 请求获取更准确的文件名（作为下载 loading 的一部分）
      if (suggestedFilename == null || suggestedFilename.isEmpty) {
        final headerName = await DownloadService.instance
            .fetchFileNameFromHeader(url);
        if (headerName != null && headerName.isNotEmpty) {
          final safeHeaderName = DownloadService.sanitizeFileName(headerName);
          if (safeHeaderName != null &&
              safeHeaderName != reservation.requestedFileName) {
            final betterReservation = DownloadService.reserveAvailableDownload(
              directory: dir,
              fileName: safeHeaderName,
            );
            try {
              await reservation.release();
            } catch (_) {
              await betterReservation.release();
              rethrow;
            }
            reservation = betterReservation;
            savePath = betterReservation.savePath;
            actualFileName = p.basename(savePath);
            _updateItem(id, fileName: actualFileName, savePath: savePath);
            toastHandle.updateFileName(actualFileName);
          }
        }
      }

      await DownloadService.instance.download(
        url: url,
        reservation: reservation,
        cancelToken: cancelToken,
        onProgress: (received, total) {
          final progress = total > 0 ? received / total : -1.0;
          final now = DateTime.now().microsecondsSinceEpoch;
          final last = _lastProgressPublishMicros[id];
          if (last != null &&
              now - last < _progressPublishIntervalMicros &&
              progress < 1.0) {
            return;
          }
          _lastProgressPublishMicros[id] = now;
          toastHandle.updateProgress(progress);
          _updateItem(
            id,
            progress: total > 0 ? received / total : 0.0,
            fileSize: total > 0 ? total : null,
          );
        },
      );
      _updateItem(id, status: DownloadItemStatus.completed, progress: 1.0);
      toastHandle.dismiss();
      // 显示完成 Toast，带"查看"按钮跳转下载列表
      ToastService.show(
        S.current.myBrowser_downloadComplete,
        type: ToastType.success,
        duration: const Duration(seconds: 5),
        actionLabel: S.current.myBrowser_viewDownload,
        onAction: () => DownloadListPage.navigateTo(highlightItemId: id),
      );
    } on DioException catch (e) {
      await _releaseQuietly(reservation);
      toastHandle.dismiss();
      if (e.type == DioExceptionType.cancel) {
        debugPrint('[DownloadProvider] 下载已取消: $actualFileName');
      } else {
        debugPrint('[DownloadProvider] 下载失败: $e');
        _updateItem(id, status: DownloadItemStatus.failed);
        ToastService.showError(S.current.myBrowser_downloadFailed);
      }
    } catch (e) {
      await _releaseQuietly(reservation);
      toastHandle.dismiss();
      debugPrint('[DownloadProvider] 下载异常: $e');
      _updateItem(id, status: DownloadItemStatus.failed);
      ToastService.showError(S.current.myBrowser_downloadFailed);
    } finally {
      _cancelTokens.remove(id);
      _lastProgressPublishMicros.remove(id);
    }
  }

  Future<void> _releaseQuietly(DownloadReservation reservation) async {
    try {
      await reservation.release();
    } catch (e) {
      debugPrint('[DownloadProvider] 清理下载临时文件失败: $e');
    }
  }

  /// 重试下载
  Future<void> retry(DownloadItem item) async {
    // 删除旧记录
    removeById(item.id);
    // 重新下载
    await startDownload(
      url: item.url,
      suggestedFilename: item.fileName,
      mimeType: item.mimeType,
    );
  }

  /// 取消下载
  void cancel(String id) {
    _cancelTokens[id]?.cancel();
    _cancelTokens.remove(id);
    _updateItem(id, status: DownloadItemStatus.failed);
  }

  /// 删除记录（同时删除本地文件）
  void removeById(String id) {
    _cancelTokens[id]?.cancel();
    _cancelTokens.remove(id);
    final item = state.firstWhere((e) => e.id == id, orElse: () => state.first);
    _deleteSavedFile(item);
    state = state.where((e) => e.id != id).toList();
    _save();
  }

  /// 删除记录对应的下载文件（下载始终落在应用目录里，是真实路径）。
  void _deleteSavedFile(DownloadItem item) {
    try {
      final file = File(item.savePath);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// 清除已完成的记录
  void clearCompleted() {
    // 删除已完成的本地文件
    for (final item in state) {
      if (item.status == DownloadItemStatus.completed) {
        _deleteSavedFile(item);
      }
    }
    state = state
        .where((e) => e.status != DownloadItemStatus.completed)
        .toList();
    _save();
  }

  void _updateItem(
    String id, {
    String? fileName,
    String? savePath,
    DownloadItemStatus? status,
    double? progress,
    int? fileSize,
  }) {
    state = [
      for (final item in state)
        if (item.id == id)
          item.copyWith(
            fileName: fileName,
            savePath: savePath,
            status: status,
            progress: progress,
            fileSize: fileSize,
          )
        else
          item,
    ];
    // 只在状态变更或文件名更新时持久化，避免进度更新频繁写入
    if (status != null || fileName != null) _save();
  }

  /// 持久化到 SharedPreferences
  void _save() {
    final jsonStr = jsonEncode(state.map((e) => e.toJson()).toList());
    _prefs.setString(_storageKey, jsonStr);
  }

  /// 获取下载目录（与其它保存入口共用同一套解析/回退逻辑）
  Future<Directory> _getDownloadDir() =>
      DownloadService.resolveDownloadDirectory();
}

final downloadProvider =
    StateNotifierProvider<DownloadNotifier, List<DownloadItem>>((ref) {
      final prefs = ref.watch(sharedPreferencesProvider);
      return DownloadNotifier(prefs);
    });
