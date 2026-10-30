import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../services/discourse/discourse_service.dart';
import '../../../services/uploads/upload_progress.dart';

export '../../../services/uploads/upload_progress.dart';

typedef UploadExecutor = Future<UploadResult> Function(
  CancelToken cancelToken,
  UploadProgressCallback onProgress,
);
typedef UploadCompleted = FutureOr<void> Function(
  UploadTask task,
  UploadResult result,
);

enum UploadTaskPhase { queued, uploading, succeeded, failed, cancelled }

/// 一个文件的注册信息。执行器每次重试均会收到新的取消令牌。
class UploadTaskRequest {
  const UploadTaskRequest({
    required this.path,
    required this.name,
    required this.execute,
    this.isImage = false,
    this.onCompleted,
  });

  final String path;
  final String name;
  final UploadExecutor execute;
  final bool isImage;
  final UploadCompleted? onCompleted;
}

/// 只读任务快照；真实路径仅用于执行和本地缩略图，不应写入日志。
@immutable
class UploadTask {
  const UploadTask({
    required this.id,
    required this.path,
    required this.name,
    required this.isImage,
    required this.phase,
    this.progress,
    this.error,
    this.result,
  });

  final String id;
  final String path;
  final String name;
  final bool isImage;
  final UploadTaskPhase phase;
  final UploadProgress? progress;

  /// 原始错误仅供调用方分类，不应直接展示或记录（可能含敏感路径）。
  final Object? error;
  final UploadResult? result;

  bool get isPending =>
      phase == UploadTaskPhase.queued ||
      phase == UploadTaskPhase.uploading ||
      phase == UploadTaskPhase.failed;
}

class _TaskEntry {
  _TaskEntry(this.task, this.execute, this.onCompleted);
  UploadTask task;
  final UploadExecutor execute;
  final UploadCompleted? onCompleted;
  CancelToken? token;
  int generation = 0;
  bool delivered = false;
}

/// 每个编辑器应创建独立实例，并在销毁时 dispose。
///
/// 整批任务先注册、通知，再启动执行；失败任务仍属于未处理任务。
class UploadTaskController extends ChangeNotifier {
  UploadTaskController({this.onCompleted});

  final UploadCompleted? onCompleted;
  final Map<String, _TaskEntry> _entries = {};
  int _nextId = 0;
  bool _disposed = false;

  List<UploadTask> get tasks =>
      List.unmodifiable(_entries.values.map((entry) => entry.task));
  bool get hasPending => _entries.values.any((entry) => entry.task.isPending);

  List<String> addBatch(Iterable<UploadTaskRequest> requests) {
    if (_disposed) throw StateError('上传任务控制器已销毁');
    final ids = <String>[];
    // 先物化输入，避免迭代中抛错留下只注册了一半的批次。
    for (final request in requests.toList()) {
      final id = 'upload-${++_nextId}';
      _entries[id] = _TaskEntry(
        UploadTask(
          id: id,
          path: request.path,
          name: request.name,
          isImage: request.isImage,
          phase: UploadTaskPhase.queued,
        ),
        request.execute,
        request.onCompleted,
      );
      ids.add(id);
    }
    if (ids.isNotEmpty) notifyListeners();
    for (final id in ids) {
      if (_entries[id]?.task.phase == UploadTaskPhase.queued) _start(id);
    }
    return ids;
  }

  String add(UploadTaskRequest request) => addBatch([request]).single;

  void retry(String id) {
    final entry = _entries[id];
    if (_disposed ||
        entry == null ||
        (entry.task.phase != UploadTaskPhase.failed &&
            entry.task.phase != UploadTaskPhase.cancelled)) {
      return;
    }
    if (entry.task.result != null) {
      unawaited(_deliver(id, entry, entry.generation, entry.task.result!));
    } else {
      _start(id);
    }
  }

  void cancel(String id) {
    final entry = _entries[id];
    if (_disposed ||
        entry == null ||
        entry.task.phase == UploadTaskPhase.succeeded ||
        entry.task.phase == UploadTaskPhase.cancelled) {
      return;
    }
    entry.generation++;
    entry.token?.cancel();
    _update(entry, UploadTaskPhase.cancelled);
    notifyListeners();
  }

  /// 清除已成功的卡片，不影响进行中、失败或取消的任务。
  void clearSucceeded() {
    if (_disposed) return;
    final ids = _entries.values
        .where((entry) => entry.task.phase == UploadTaskPhase.succeeded)
        .map((entry) => entry.task.id)
        .toList();
    for (final id in ids) {
      remove(id);
    }
  }

  void remove(String id) {
    if (_disposed) return;
    final entry = _entries.remove(id);
    if (entry == null) return;
    entry.generation++;
    entry.token?.cancel();
    notifyListeners();
  }

  bool _isCurrent(String id, _TaskEntry entry, int generation) =>
      !_disposed &&
      identical(_entries[id], entry) &&
      entry.generation == generation;

  void _update(
    _TaskEntry entry,
    UploadTaskPhase phase, {
    UploadProgress? progress,
    Object? error,
    UploadResult? result,
  }) {
    final old = entry.task;
    entry.task = UploadTask(
      id: old.id,
      path: old.path,
      name: old.name,
      isImage: old.isImage,
      phase: phase,
      progress: progress,
      error: error,
      result: result,
    );
  }

  void _start(String id) {
    final entry = _entries[id];
    if (_disposed || entry == null) return;
    final generation = ++entry.generation;
    final token = entry.token = CancelToken();
    _update(entry, UploadTaskPhase.uploading);
    notifyListeners();
    if (!_isCurrent(id, entry, generation)) return;
    unawaited(_run(id, entry, generation, token));
  }

  Future<void> _run(
    String id,
    _TaskEntry entry,
    int generation,
    CancelToken token,
  ) async {
    UploadResult result;
    try {
      result = await entry.execute(token, (progress) {
        if (!_isCurrent(id, entry, generation) ||
            entry.task.phase != UploadTaskPhase.uploading) {
          return;
        }
        _update(entry, UploadTaskPhase.uploading, progress: progress);
        notifyListeners();
      });
    } catch (error) {
      if (!_isCurrent(id, entry, generation)) return;
      _update(
        entry,
        token.isCancelled ? UploadTaskPhase.cancelled : UploadTaskPhase.failed,
        error: error,
      );
      notifyListeners();
      return;
    }
    if (!_isCurrent(id, entry, generation) || token.isCancelled) return;
    await _deliver(id, entry, generation, result);
  }

  Future<void> _deliver(
    String id,
    _TaskEntry entry,
    int generation,
    UploadResult result,
  ) async {
    if (!_isCurrent(id, entry, generation) || entry.delivered) return;
    _update(
      entry,
      UploadTaskPhase.uploading,
      result: result,
      progress: const UploadProgress(phase: UploadPhase.processing),
    );
    notifyListeners();
    if (!_isCurrent(id, entry, generation)) return;
    try {
      await (entry.onCompleted ?? onCompleted)?.call(entry.task, result);
      if (!_isCurrent(id, entry, generation)) return;
      entry.delivered = true;
      _update(entry, UploadTaskPhase.succeeded, result: result);
    } catch (error) {
      if (!_isCurrent(id, entry, generation)) return;
      // 文件已在服务器，只重试插入，不重复上传。
      _update(entry, UploadTaskPhase.failed, error: error, result: result);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _entries.values) {
      entry.generation++;
      entry.token?.cancel();
    }
    _entries.clear();
    super.dispose();
  }
}
