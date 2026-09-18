import 'dart:io';

import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart';

import '../../../l10n/s.dart';
import 'task_controller.dart';
import 'upload_task_labels.dart';

export 'upload_task_labels.dart';

/// 不持有控制器生命周期，宿主编辑器负责创建和销毁。
class UploadTaskPanel extends StatefulWidget {
  const UploadTaskPanel({
    super.key,
    required this.controller,
    this.labels,
    this.initiallyExpanded = true,
    this.hideWhenAllSucceeded = true,
  });

  final UploadTaskController controller;
  final UploadTaskLabels? labels;
  final bool initiallyExpanded;
  final bool hideWhenAllSucceeded;

  @override
  State<UploadTaskPanel> createState() => _UploadTaskPanelState();
}

class _UploadTaskPanelState extends State<UploadTaskPanel> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final tasks = widget.controller.tasks;
      if (tasks.isEmpty ||
          (widget.hideWhenAllSucceeded &&
              tasks.every((task) => task.phase == UploadTaskPhase.succeeded))) {
        return const SizedBox.shrink();
      }
      final labels = widget.labels ?? UploadTaskLabels.of(context);
      final done = tasks
          .where((t) => t.phase == UploadTaskPhase.succeeded)
          .length;
      final failed = tasks
          .where((t) => t.phase == UploadTaskPhase.failed)
          .length;
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: Icon(
                failed > 0 ? Icons.error_outline : Icons.cloud_upload_outlined,
              ),
              title: Text('${labels.title} · $done/${tasks.length}'),
              subtitle: failed > 0 ? Text('${labels.failed} · $failed') : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (done > 0)
                    IconButton(
                      tooltip: context.l10n.common_clear,
                      onPressed: widget.controller.clearSucceeded,
                      icon: const Icon(Icons.cleaning_services_outlined),
                    ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                ],
              ),
              onTap: () => setState(() => _expanded = !_expanded),
            ),
            if (_expanded)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  itemCount: tasks.length,
                  itemBuilder: (context, index) => UploadTaskCard(
                    controller: widget.controller,
                    task: tasks[index],
                    labels: labels,
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// 可在富文本对象原位置复用的单任务卡片。
/// 宿主监听控制器并传入最新快照。
class UploadTaskCard extends StatelessWidget {
  const UploadTaskCard({
    super.key,
    required this.controller,
    required this.task,
    this.labels,
    this.flat = false,
  });

  final UploadTaskController controller;
  final UploadTask task;
  final UploadTaskLabels? labels;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final labels = this.labels ?? UploadTaskLabels.of(context);
    final active =
        task.phase == UploadTaskPhase.uploading ||
        task.phase == UploadTaskPhase.queued;
    final retryable =
        task.phase == UploadTaskPhase.failed ||
        task.phase == UploadTaskPhase.cancelled;
    final progress = task.progress;
    final total = progress?.totalBytes;
    final fraction =
        progress?.phase == UploadPhase.uploading && total != null && total > 0
        ? (progress!.sentBytes / total).clamp(0.0, 1.0)
        : null;
    final content = Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: task.isImage
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.file(
                      File(task.path),
                      fit: BoxFit.cover,
                      cacheWidth: 96,
                      cacheHeight: 96,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.image_outlined),
                    ),
                  )
                : const Icon(Icons.insert_drive_file_outlined),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(task.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  labels.taskStatus(task),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (active) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: fraction,
                    minHeight: 2,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ],
              ],
            ),
          ),
          if (retryable)
            IconButton(
              tooltip: context.l10n.common_retry,
              onPressed: () => controller.retry(task.id),
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            tooltip: active
                ? context.l10n.common_cancel
                : context.l10n.common_delete,
            onPressed: () => active
                ? controller.cancel(task.id)
                : controller.remove(task.id),
            icon: Icon(
              active || flat ? Icons.close_rounded : Icons.delete_outline,
            ),
          ),
        ],
      ),
    );
    return flat
        ? content
        : Card(
            key: ValueKey(task.id),
            margin: const EdgeInsets.only(bottom: 6),
            child: content,
          );
  }
}

/// 聊天只展示待发送附件，不使用编辑器的任务管理标题和清扫操作。
class ChatUploadStrip extends StatelessWidget {
  const ChatUploadStrip({super.key, required this.controller});
  final UploadTaskController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final tasks = controller.tasks;
      if (tasks.isEmpty) return const SizedBox.shrink();
      return SizedBox(
        height: 88,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          itemCount: tasks.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) =>
              _ChatUploadTile(task: tasks[index], controller: controller),
        ),
      );
    },
  );
}

class _ChatUploadTile extends StatelessWidget {
  const _ChatUploadTile({required this.task, required this.controller});
  final UploadTask task;
  final UploadTaskController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labels = UploadTaskLabels.of(context);
    final active =
        task.phase == UploadTaskPhase.queued ||
        task.phase == UploadTaskPhase.uploading;
    final failed =
        task.phase == UploadTaskPhase.failed ||
        task.phase == UploadTaskPhase.cancelled;
    final done = task.phase == UploadTaskPhase.succeeded;
    final progress = task.progress;
    final total = progress?.totalBytes;
    final fraction =
        progress?.phase == UploadPhase.uploading && total != null && total > 0
        ? (progress!.sentBytes / total).clamp(0.0, 1.0)
        : null;
    final status = active && fraction != null
        ? '${(fraction * 100).floor()}%'
        : labels.taskStatus(task);
    return Tooltip(
      message: '${task.name}\n${labels.taskStatus(task)}',
      child: Semantics(
        label: '${task.name}，${labels.taskStatus(task)}',
        child: Container(
          key: ValueKey('chat-upload-${task.id}'),
          width: task.isImage ? 80 : 164,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: failed
                  ? theme.colorScheme.error
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (task.isImage)
                Image.file(
                  File(task.path),
                  fit: BoxFit.cover,
                  cacheWidth: 192,
                  cacheHeight: 192,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.image_outlined,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 32, 24),
                  child: Row(
                    children: [
                      Icon(
                        Icons.insert_drive_file_outlined,
                        size: 25,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          task.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              if (active || failed)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.65),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 3,
                          ),
                          child: Text(
                            failed ? context.l10n.common_retry : status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ),
                        if (active)
                          LinearProgressIndicator(
                            value: fraction,
                            minHeight: 2,
                            backgroundColor: Colors.white24,
                          ),
                      ],
                    ),
                  ),
                ),
              if (failed)
                Positioned.fill(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => controller.retry(task.id),
                      child: const Center(
                        child: Icon(
                          Icons.refresh_rounded,
                          color: Colors.white,
                          shadows: [Shadow(blurRadius: 4)],
                        ),
                      ),
                    ),
                  ),
                ),
              if (done)
                Positioned(
                  left: 5,
                  bottom: 5,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Icons.check_rounded,
                        size: 13,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  tooltip: active
                      ? context.l10n.common_cancel
                      : context.l10n.common_delete,
                  onPressed: () => controller.remove(task.id),
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(32),
                    maximumSize: const Size.square(32),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 源码编辑器专用浮层：单层玻璃、紧凑状态和任务行，不影响富文本卡片。
class SourceUploadPanel extends StatefulWidget {
  const SourceUploadPanel({super.key, required this.controller});
  final UploadTaskController controller;

  @override
  State<SourceUploadPanel> createState() => _SourceUploadPanelState();
}

class _SourceUploadPanelState extends State<SourceUploadPanel> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final all = widget.controller.tasks;
      final tasks = all
          .where((task) => task.phase != UploadTaskPhase.succeeded)
          .toList();
      if (tasks.isEmpty) return const SizedBox.shrink();
      final labels = UploadTaskLabels.of(context);
      final colors = Theme.of(context).colorScheme;
      final failed = tasks.any((task) => task.phase == UploadTaskPhase.failed);
      final active = tasks.any(
        (task) =>
            task.phase == UploadTaskPhase.queued ||
            task.phase == UploadTaskPhase.uploading,
      );
      final known = tasks
          .where(
            (task) =>
                task.progress?.totalBytes != null &&
                task.progress!.totalBytes! > 0,
          )
          .toList();
      final total = known.fold<int>(
        0,
        (sum, task) => sum + task.progress!.totalBytes!,
      );
      final sent = known.fold<int>(
        0,
        (sum, task) => sum + task.progress!.sentBytes,
      );
      final progress =
          known.length == tasks.length &&
              total > 0 &&
              tasks.every(
                (task) => task.progress?.phase == UploadPhase.uploading,
              )
          ? (sent / total).clamp(0.0, 1.0)
          : null;
      return Align(
        alignment: Alignment.topCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: GlassSurfaceFrame(
            key: const ValueKey('source-upload-glass'),
            radius: 20,
            recipe: _expanded ? GlassRecipe.sheet : GlassRecipe.toolbar,
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                      child: Row(
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: (failed ? colors.error : colors.primary)
                                  .withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              failed
                                  ? Icons.error_outline_rounded
                                  : Icons.cloud_upload_outlined,
                              size: 18,
                              color: failed ? colors.error : colors.primary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              tasks.length == 1
                                  ? labels.taskStatus(tasks.single)
                                  : labels.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                          ),
                          Text(
                            '${all.length - tasks.length}/${all.length}',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 32,
                            height: 32,
                            child: Icon(
                              _expanded
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_down_rounded,
                              size: 20,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_expanded) ...[
                    Divider(
                      height: 1,
                      indent: 14,
                      endIndent: 14,
                      color: colors.outlineVariant.withValues(alpha: .35),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 216),
                      child: ListView.separated(
                        shrinkWrap: true,
                        primary: false,
                        padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                        itemCount: tasks.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 2),
                        itemBuilder: (context, index) => UploadTaskCard(
                          controller: widget.controller,
                          task: tasks[index],
                          flat: true,
                          labels: labels,
                        ),
                      ),
                    ),
                  ] else if (active)
                    LinearProgressIndicator(
                      value: progress,
                      minHeight: 2,
                      backgroundColor: colors.primary.withValues(alpha: .08),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// 网格内部任务瓦片复用缩略图/进度/重试，不向正文插入临时图片地址。
class UploadGridTile extends StatelessWidget {
  const UploadGridTile({
    super.key,
    required this.controller,
    required this.task,
  });
  final UploadTaskController controller;
  final UploadTask task;
  @override
  Widget build(BuildContext context) =>
      _ChatUploadTile(task: task, controller: controller);
}
