import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/draft.dart';
import 'discourse/discourse_service.dart';
import 'local_draft_store.dart';

/// 草稿保存状态
enum DraftSaveStatus {
  idle, // 无操作
  pending, // 等待保存（防抖中）
  saving, // 正在保存
  saved, // 已保存
  error, // 保存失败
}

/// 草稿控制器
/// 负责自动保存草稿、防抖、序列号管理
class DraftController {
  final String draftKey;
  final DiscourseService _service;
  final LocalDraftStore _localStore;
  final Future<String?> Function() _accountIdResolver;

  /// 防抖延迟时间
  static const _debounceDelay = Duration(seconds: 2);
  static const _localDebounceDelay = Duration(milliseconds: 400);

  /// 当前序列号
  int _sequence = 0;
  int get sequence => _sequence;

  /// 上次保存的内容快照（用于检测变化）
  String? _lastSavedData;
  DraftData? _latestData;

  /// 防抖定时器
  Timer? _debounceTimer;
  Timer? _localDebounceTimer;
  DraftData? _pendingLocalData;
  Future<void> _localOperationFuture = Future.value();
  Future<String?>? _accountIdFuture;

  /// 保存状态
  final _statusNotifier = ValueNotifier<DraftSaveStatus>(DraftSaveStatus.idle);
  ValueNotifier<DraftSaveStatus> get statusNotifier => _statusNotifier;
  DraftSaveStatus get status => _statusNotifier.value;

  /// 编辑器打开时间戳（用于计算 composerTime）
  final DateTime _openedAt = DateTime.now();

  /// 是否已释放
  bool _disposed = false;

  /// 是否禁用草稿保存(对齐 Discourse 前端 composer.disableDrafts)
  /// 发送/审核途中置 true,避免与帖子创建/草稿删除流程撞 409
  bool _disabled = false;

  /// 当前正在进行的保存操作
  Future<void>? _saveFuture;

  DraftController({
    required this.draftKey,
    DiscourseService? service,
    LocalDraftStore? localStore,
    Future<String?> Function()? accountIdResolver,
  }) : _service = service ?? DiscourseService(),
       _localStore = localStore ?? LocalDraftStore(),
       _accountIdResolver =
           accountIdResolver ??
           (() => (service ?? DiscourseService()).getUsername());

  /// 加载现有草稿
  /// 返回草稿数据，如果不存在返回 null
  Future<Draft?> loadDraft({Future<Draft?>? preloadedDraftFuture}) async {
    Draft? serverDraft;
    try {
      serverDraft = await (preloadedDraftFuture ?? _service.getDraft(draftKey));
    } catch (e) {
      debugPrint('[DraftController] load server draft failed: $e');
    }

    if (serverDraft != null) {
      _sequence = serverDraft.sequence;
      _lastSavedData = serverDraft.data.toJsonString();
    }

    final localDraft = await _readLocalDraft();
    if (localDraft == null) return serverDraft;

    if (serverDraft != null &&
        serverDraft.data.toJsonString() == localDraft.data.toJsonString()) {
      await _deleteLocalIfMatches(localDraft.data);
      return serverDraft;
    }

    _sequence = serverDraft?.sequence ?? localDraft.sequence;
    return (serverDraft ??
            Draft(
              draftKey: draftKey,
              data: localDraft.data,
              sequence: _sequence,
              updatedAt: localDraft.updatedAt,
            ))
        .copyWith(
          data: localDraft.data,
          sequence: _sequence,
          updatedAt: localDraft.updatedAt,
        );
  }

  Future<LocalDraftEntry?> _readLocalDraft() async {
    if (kIsWeb) return null;
    try {
      final accountId = await _resolveAccountId();
      if (accountId == null) return null;
      return _localStore.read(accountId, draftKey);
    } catch (e) {
      debugPrint('[DraftController] load local draft failed: $e');
      return null;
    }
  }

  /// 触发自动保存（带防抖）
  void scheduleSave(DraftData data) {
    if (_disposed || _disabled) return;
    _latestData = data;

    // 清空内容时取消尚未执行的保存，并清掉本地兜底。
    if (!data.hasContent) {
      _debounceTimer?.cancel();
      _localDebounceTimer?.cancel();
      _pendingLocalData = null;
      unawaited(_deleteLocal());
      _statusNotifier.value = DraftSaveStatus.idle;
      return;
    }

    // 检查内容是否有变化
    if (!_hasContentChanged(data)) return;

    _scheduleLocalSave(data);

    _debounceTimer?.cancel();
    _statusNotifier.value = DraftSaveStatus.pending;

    _debounceTimer = Timer(_debounceDelay, () {
      // 对齐 Discourse 前端 services/composer.js:正在保存就再延一轮,
      // 不并发(配合乐观 sequence 共同防 409)
      if (_saveFuture != null) {
        scheduleSave(data);
        return;
      }
      _save(data);
    });
  }

  /// 立即保存（关闭时调用）
  Future<void> saveNow(DraftData data) async {
    if (_disposed || _disabled) return;
    _latestData = data;

    _debounceTimer?.cancel();
    await _saveLocalNow(data);
    if (_disposed || _disabled) return;

    // 没有内容时不保存
    if (!data.hasContent) return;

    // 如果没有内容变化，不需要保存
    if (!_hasContentChanged(data)) return;

    // 等正在进行的保存完成,拿到最新 sequence 后再发,避免 409
    if (_saveFuture != null) {
      await _saveFuture;
    }

    await _save(data);
  }

  /// 执行保存
  Future<void> _save(DraftData data) async {
    if (_disposed) return;

    await _saveLocalNow(data);
    if (_disposed || _disabled) return;

    // 添加编辑时长信息
    final composerTime = DateTime.now().difference(_openedAt).inMilliseconds;
    final dataWithTime = data.copyWith(composerTime: composerTime);

    _statusNotifier.value = DraftSaveStatus.saving;

    final future = _doSave(dataWithTime, data);
    _saveFuture = future;
    await future;
  }

  Future<void> _doSave(DraftData dataWithTime, DraftData data) async {
    // 对齐 Discourse 前端 composer.js:发请求前乐观递增 sequence,
    // 这样保存中再来的请求会带 +1 后的值,不会再撞 409
    final sentSequence = _sequence;
    _sequence = sentSequence + 1;
    try {
      final newSequence = await _service.saveDraft(
        draftKey: draftKey,
        data: dataWithTime,
        sequence: sentSequence,
      );
      _sequence = newSequence;
      _lastSavedData = data.toJsonString();
      await _deleteLocalIfMatches(data);
      _reportSaveResult(data, DraftSaveStatus.saved);
    } on DraftSequenceConflictException {
      // 服务端 sequence 与客户端不一致(例如网页端同时编辑、上次保存丢响应)。
      // 服务端 409 不返回最新 sequence,只能 force_save 一次绕过校验。
      try {
        final newSequence = await _service.saveDraft(
          draftKey: draftKey,
          data: dataWithTime,
          sequence: sentSequence,
          forceSave: true,
        );
        _sequence = newSequence;
        _lastSavedData = data.toJsonString();
        await _deleteLocalIfMatches(data);
        _reportSaveResult(data, DraftSaveStatus.saved);
      } catch (e) {
        debugPrint('[DraftController] force save failed: $e');
        _reportSaveResult(data, DraftSaveStatus.error);
      }
    } catch (e) {
      debugPrint('[DraftController] save failed: $e');
      _reportSaveResult(data, DraftSaveStatus.error);
    } finally {
      if (_saveFuture != null) {
        _saveFuture = null;
      }
    }
  }

  void _reportSaveResult(DraftData savedData, DraftSaveStatus result) {
    if (_disposed || _disabled) return;
    final latest = _latestData;
    // 请求发出后用户可能继续输入或清空正文，旧结果不能宣称当前内容已保存。
    _statusNotifier.value =
        latest == null || latest.toJsonString() == savedData.toJsonString()
        ? result
        : latest.hasContent
        ? DraftSaveStatus.pending
        : DraftSaveStatus.idle;
  }

  /// 删除草稿
  /// 会等待正在进行的保存操作完成后再删除，避免并发竞态
  Future<void> deleteDraft() async {
    _debounceTimer?.cancel();
    _localDebounceTimer?.cancel();
    _pendingLocalData = null;

    // 等待正在进行的保存完成，确保拿到最新的 sequence
    if (_saveFuture != null) {
      await _saveFuture;
    }

    try {
      await _service.deleteDraft(draftKey, sequence: _sequence);
    } catch (e) {
      debugPrint('[DraftController] deleteDraft failed: $e');
    } finally {
      await _deleteLocal();
    }
  }

  void _scheduleLocalSave(DraftData data) {
    if (kIsWeb) return;
    _localDebounceTimer?.cancel();
    _pendingLocalData = data;
    _localDebounceTimer = Timer(_localDebounceDelay, () {
      unawaited(_flushPendingLocalWrite());
    });
  }

  Future<void> _saveLocalNow(DraftData data) async {
    if (kIsWeb) return;
    _localDebounceTimer?.cancel();
    if (!data.hasContent) return;
    _pendingLocalData = null;
    await _enqueueLocalWrite(data);
  }

  Future<void> _flushPendingLocalWrite() async {
    final data = _pendingLocalData;
    _pendingLocalData = null;
    if (data == null || !data.hasContent) return;
    await _enqueueLocalWrite(data);
  }

  Future<void> _enqueueLocalWrite(DraftData data) {
    return _enqueueLocalOperation(() async {
      final accountId = await _resolveAccountId();
      if (accountId == null) return;
      await _localStore.write(
        accountId: accountId,
        draftKey: draftKey,
        data: data,
        sequence: _sequence,
      );
    }, 'save local draft');
  }

  Future<void> _deleteLocalIfMatches(DraftData data) async {
    if (kIsWeb) return;
    _localDebounceTimer?.cancel();
    await _flushPendingLocalWrite();
    await _enqueueLocalOperation(() async {
      final accountId = await _resolveAccountId();
      if (accountId == null) return;
      await _localStore.deleteIfMatches(
        accountId: accountId,
        draftKey: draftKey,
        data: data,
      );
    }, 'clear synced local draft');
  }

  Future<void> _deleteLocal() {
    if (kIsWeb) return Future.value();
    return _enqueueLocalOperation(() async {
      final accountId = await _resolveAccountId();
      if (accountId == null) return;
      await _localStore.delete(accountId, draftKey);
    }, 'delete local draft');
  }

  Future<void> _enqueueLocalOperation(
    Future<void> Function() operation,
    String operationName,
  ) {
    final previous = _localOperationFuture;
    final next = () async {
      try {
        await previous;
        await operation();
      } catch (e) {
        debugPrint('[DraftController] $operationName failed: $e');
      }
    }();
    _localOperationFuture = next;
    return next;
  }

  Future<String?> _resolveAccountId() async {
    final accountId = await (_accountIdFuture ??= _accountIdResolver());
    return accountId == null || accountId.isEmpty ? null : accountId;
  }

  /// 检查内容是否有变化
  bool _hasContentChanged(DraftData data) {
    return data.toJsonString() != _lastSavedData;
  }

  /// 永久禁用本控制器的草稿保存
  /// 用于发送/审核通过场景:停掉防抖定时器并阻断后续 [scheduleSave]/[saveNow]
  void disable() {
    _disabled = true;
    _debounceTimer?.cancel();
    if (!_disposed) {
      _statusNotifier.value = DraftSaveStatus.idle;
    }
  }

  /// 恢复草稿保存(发送失败时调用,对应 Discourse 前端 composer.js:1439)
  void enable() {
    _disabled = false;
  }

  /// 用服务端返回的 sequence 同步本地(发送响应里带 draft_sequence 时调用)
  /// 对齐 Discourse 前端 composer.js:1382 的 `topic.set("draft_sequence", ...)`
  void syncSequence(int sequence) {
    _sequence = sequence;
  }

  /// 释放资源
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _localDebounceTimer?.cancel();
    _pendingLocalData = null;
    _statusNotifier.dispose();
  }
}
