import 'dart:async';

enum ComposerImportFailure {
  unavailable,
  timeout,
  exception,
  mismatch,
  unsupported,
}

/// 不携带异常文本或用户正文，便于宿主安全记录降级原因。
class ComposerImportResult<D> {
  const ComposerImportResult.success(D this.document) : failure = null;
  const ComposerImportResult.failure(this.failure) : document = null;

  final D? document;
  final ComposerImportFailure? failure;
}

/// 语义编辑器唯一导入边界，所有阶段共用预算并严格比较 cook 输出。
class ComposerTokenImportPipeline<D> {
  const ComposerTokenImportPipeline({
    required this.cook,
    required this.parseForEditor,
    required this.convert,
    required this.serialize,
    required this.emptyDocument,
    this.onMismatch,
  });

  final FutureOr<String?> Function(String) cook;
  final FutureOr<Map<String, dynamic>?> Function(String) parseForEditor;
  final FutureOr<D?> Function(String, Map<String, dynamic>) convert;
  final FutureOr<String> Function(D) serialize;
  final FutureOr<D> Function() emptyDocument;

  /// 仅内部诊断使用，调用方不得直接记录原始 HTML。
  final void Function(String original, String returned)? onMismatch;

  Future<ComposerImportResult<D>> import(
    String raw, {
    required Duration timeout,
    bool guarded = false,
  }) async {
    final watch = Stopwatch()..start();
    Future<T> stage<T>(FutureOr<T> Function() action) async {
      final remaining = timeout - watch.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('导入预算耗尽');
      final value = await Future<T>.sync(action).timeout(remaining);
      if (watch.elapsed >= timeout) throw TimeoutException('导入预算耗尽');
      return value;
    }

    try {
      if (raw.trim().isEmpty) {
        return ComposerImportResult.success(await stage(emptyDocument));
      }
      final original = guarded ? await stage(() => cook(raw)) : null;
      if (guarded && original == null) {
        return const ComposerImportResult.failure(
          ComposerImportFailure.unavailable,
        );
      }
      final imported = await stage(() => parseForEditor(raw));
      if (imported == null) {
        return const ComposerImportResult.failure(
          ComposerImportFailure.unavailable,
        );
      }
      final document = await stage(() => convert(raw, imported));
      if (document == null) {
        return const ComposerImportResult.failure(
          ComposerImportFailure.unsupported,
        );
      }
      if (guarded) {
        final back = await stage(() => serialize(document));
        final cookedBack = await stage(() => cook(back));
        if (cookedBack == null) {
          return const ComposerImportResult.failure(
            ComposerImportFailure.unavailable,
          );
        }
        // 严格比较：未知差异宁可降级，不抹去 pre/code 等真实空白。
        if (original != cookedBack) {
          onMismatch?.call(original!, cookedBack);
          return const ComposerImportResult.failure(
            ComposerImportFailure.mismatch,
          );
        }
      }
      return ComposerImportResult.success(document);
    } on TimeoutException {
      return const ComposerImportResult.failure(ComposerImportFailure.timeout);
    } catch (_) {
      return const ComposerImportResult.failure(
        ComposerImportFailure.exception,
      );
    } finally {
      watch.stop();
    }
  }
}
