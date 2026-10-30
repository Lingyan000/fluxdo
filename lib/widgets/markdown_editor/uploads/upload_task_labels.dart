import 'package:flutter/widgets.dart';

import '../../../l10n/s.dart';

import 'task_controller.dart';

/// 复用四语言本地化模块；也允许宿主传入自定义译文。
class UploadTaskLabels {
  const UploadTaskLabels({
    this.title = '上传任务',
    this.pendingSubmit = '仍有附件正在上传或上传失败，请等待完成、重试或移除后再发布',
    this.queued = '等待上传',
    this.uploading = '正在上传',
    this.preparing = '正在准备',
    this.processing = '正在处理',
    this.succeeded = '上传完成',
    this.failed = '上传失败，请重试或移除',
    this.cancelled = '已取消',
  });

  final String title;
  final String pendingSubmit;
  final String queued;
  final String uploading;
  final String preparing;
  final String processing;
  final String succeeded;
  final String failed;
  final String cancelled;

  static UploadTaskLabels of(BuildContext context) {
    final l10n = context.l10n;
    return UploadTaskLabels(
      title: l10n.editorUploads_title,
      pendingSubmit: l10n.editorUploads_pendingSubmit,
      queued: l10n.editorUploads_queued,
      uploading: l10n.editorUploads_uploading,
      preparing: l10n.editorUploads_preparing,
      processing: l10n.editorUploads_processing,
      succeeded: l10n.editorUploads_succeeded,
      failed: l10n.editorUploads_failed,
      cancelled: l10n.editorUploads_cancelled,
    );
  }

  String taskStatus(UploadTask task) {
    if (task.phase == UploadTaskPhase.uploading) {
      if (task.progress?.phase == UploadPhase.preparing) return preparing;
      if (task.progress?.phase == UploadPhase.processing) return processing;
    }
    return phase(task.phase);
  }

  String phase(UploadTaskPhase phase) => switch (phase) {
    UploadTaskPhase.queued => queued,
    UploadTaskPhase.uploading => uploading,
    UploadTaskPhase.succeeded => succeeded,
    UploadTaskPhase.failed => failed,
    UploadTaskPhase.cancelled => cancelled,
  };
}
