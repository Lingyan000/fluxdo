import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../models/draft.dart';
import 'connectivity_service.dart';
import 'discourse/discourse_service.dart';
import 'local_draft_store.dart';

enum DraftSaveStatus { idle, pending, saving, saved, local, conflict, error }

/// 沿用官方在线保存的 2 秒防抖、15 秒最长等待和串行请求。
/// 本地快照独立更新，页面销毁不会中止已交给保存队列的任务。
class DraftController {
  DraftController({
    required this.draftKey,
    DiscourseService? service,
    LocalDraftStore? localStore,
    Future<String?> Function()? accountIdResolver,
    Stream<bool>? connectionStream,
    bool Function()? isConnected,
  }) : _service = service ?? DiscourseService(),
       _localStore = localStore ?? LocalDraftStore(),
       _accountIdResolver =
           accountIdResolver ??
           (() => (service ?? DiscourseService()).getUsername()),
       _isConnected = isConnected ?? (() => ConnectivityService().isConnected) {
    _connection = (connectionStream ?? ConnectivityService().connectionStream)
        .listen((connected) {
          if (connected) retryPending();
        });
  }

  final String draftKey;
  final DiscourseService _service;
  final LocalDraftStore _localStore;
  final Future<String?> Function() _accountIdResolver;
  final bool Function() _isConnected;
  StreamSubscription<bool>? _connection;
  Future<String?>? _accountIdFuture;
  static const _debounceDelay = Duration(seconds: 2);
  static const _maxWait = Duration(seconds: 15);
  final _openedAt = DateTime.now();
  final _statusNotifier = ValueNotifier<DraftSaveStatus>(DraftSaveStatus.idle);
  ValueNotifier<DraftSaveStatus> get statusNotifier => _statusNotifier;
  DraftSaveStatus get status => _statusNotifier.value;
  int _sequence = 0;
  int _confirmedSequence = 0;
  int _sequenceEpoch = 0;
  int get sequence => _sequence;
  bool _disposed = false;
  bool _disabled = false;
  bool _conflict = false;
  bool get hasConflict => _conflict;
  bool _needsRemoteCheck = true;
  bool _pendingDelete = false;
  bool _requested = false;
  bool _forceNext = false;
  bool _deleting = false;
  int _revision = 0;
  DraftData? _latestData;
  String? _lastSavedFingerprint;
  String? _lastAttemptFingerprint;
  String? _localFingerprint;
  Timer? _debounceTimer;
  Timer? _maxWaitTimer;
  Future<void>? _saveFuture;
  Future<void>? _remoteCheck;
  Future<void> _localTail = Future.value();

  void _setStatus(DraftSaveStatus value) {
    if (!_disposed && (!_disabled || value == DraftSaveStatus.idle)) {
      _statusNotifier.value = value;
    }
  }

  bool get _dirty =>
      _pendingDelete ||
      (_latestData?.hasContent == true &&
          _latestData!.contentFingerprint != _lastSavedFingerprint);

  DraftSaveStatus get _unsyncedStatus =>
      _localFingerprint == _latestData?.contentFingerprint
      ? DraftSaveStatus.local
      : DraftSaveStatus.error;

  void _cancelTimers() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _maxWaitTimer?.cancel();
    _maxWaitTimer = null;
  }

  /// 本地先恢复，远端核对不替换用户正在编辑的正文。
  Future<Draft?> loadDraft({Future<Draft?>? preloadedDraftFuture}) async {
    // 尽早接住预加载请求的异常，避免读取本地期间形成未处理 Future。
    var preloadFailed = false;
    final remote = preloadedDraftFuture?.then<Draft?>(
      (value) => value,
      onError: (Object error) {
        preloadFailed = true;
        return null;
      },
    );
    final local = await _readLocalDraft();
    if (_disposed) return null;
    if (local != null) {
      _latestData = local.data;
      _localFingerprint = local.data.contentFingerprint;
      _sequence = _confirmedSequence = local.sequence;
      _lastSavedFingerprint = local.synced
          ? _localFingerprint
          : local.baseFingerprint;
      _pendingDelete = !local.data.hasContent;
      _needsRemoteCheck = true;
      _setStatus(local.synced ? DraftSaveStatus.saved : DraftSaveStatus.local);
      _remoteCheck = _checkRemote(
        preloaded: remote,
        preloadFailed: () => preloadFailed,
      );
      unawaited(
        _remoteCheck!.then((_) {
          if (!_disposed &&
              !_disabled &&
              !_conflict &&
              !_needsRemoteCheck &&
              _dirty) {
            unawaited(_requestSave());
          }
        }),
      );
      return local.data.hasContent
          ? Draft(
              draftKey: draftKey,
              data: local.data,
              sequence: local.sequence,
              updatedAt: local.updatedAt,
            )
          : null;
    }
    try {
      final draft = await (remote ?? _service.getDraft(draftKey));
      _needsRemoteCheck = preloadFailed;
      if (_disposed || draft == null) return draft;
      _sequence = _confirmedSequence = draft.sequence;
      _lastSavedFingerprint = draft.data.contentFingerprint;
      _latestData = draft.data;
      await _persistLatest(confirmOnly: true);
      return draft;
    } catch (e) {
      debugPrint('[DraftController] load server draft failed: $e');
      return null;
    }
  }

  Future<LocalDraftEntry?> _readLocalDraft() async {
    if (kIsWeb) return null;
    try {
      final account = await _resolveAccountId();
      if (account == null) return null;
      return await _localStore.read(account, draftKey);
    } catch (e) {
      debugPrint('[DraftController] load local draft failed: $e');
      return null;
    }
  }

  bool _accept(DraftData data) {
    if (_latestData?.contentFingerprint == data.contentFingerprint) {
      return false;
    }
    final hadContent = _latestData?.hasContent == true;
    _latestData = data.copyWith(
      tags: data.tags == null ? null : List.unmodifiable(data.tags!),
      recipients: data.recipients == null
          ? null
          : List.unmodifiable(data.recipients!),
    );
    _revision++;
    _pendingDelete =
        !data.hasContent &&
        (hadContent || _lastSavedFingerprint != null || _pendingDelete);
    if (data.hasContent || _pendingDelete) unawaited(_persistLatest());
    return true;
  }

  void scheduleSave(DraftData data) {
    if (_disposed || _disabled || !_accept(data)) return;
    if (!_dirty) {
      _cancelTimers();
      _requested =
          _saveFuture != null &&
          (_deleting || _lastAttemptFingerprint != data.contentFingerprint);
      _setStatus(
        data.hasContent ? DraftSaveStatus.saved : DraftSaveStatus.idle,
      );
      return;
    }
    if (_conflict) {
      _setStatus(DraftSaveStatus.conflict);
      return;
    }
    _setStatus(
      !data.hasContent
          ? DraftSaveStatus.idle
          : _isConnected()
          ? DraftSaveStatus.pending
          : _unsyncedStatus,
    );
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () => unawaited(_requestSave()));
    _maxWaitTimer ??= Timer(_maxWait, () => unawaited(_requestSave()));
  }

  Future<void> saveNow(DraftData data, {bool forceSave = false}) {
    if (_disposed || _disabled) return Future.value();
    _accept(data);
    _forceNext |= forceSave;
    return _requestSave();
  }

  /// 恢复网络/回到前台重试；版本冲突继续等待用户选择。
  Future<void> retryPending() {
    if (_disposed || _disabled || _conflict || !_dirty) return Future.value();
    return _requestSave();
  }

  Future<void> _requestSave() {
    _cancelTimers();
    if (_disabled && !_pendingDelete) return Future.value();
    _requested = true;
    if (_saveFuture != null) return _saveFuture!;
    // 在任何 await 之前占用队列，连同本地写入一起串行化。
    final done = Completer<void>();
    _saveFuture = done.future;
    unawaited(() async {
      try {
        while (_requested && (!_disabled || _pendingDelete)) {
          _requested = false;
          await _remoteCheck;
          if (!await _accountMatches()) {
            _setStatus(_unsyncedStatus);
            break;
          }
          if (_needsRemoteCheck && _isConnected() && !_forceNext) {
            await _checkRemote();
          }
          await _localTail;
          if (!_dirty || (_disabled && !_pendingDelete)) continue;
          if (_conflict && !_forceNext) {
            _setStatus(DraftSaveStatus.conflict);
            break;
          }
          if (!_isConnected() || (_needsRemoteCheck && !_forceNext)) {
            _setStatus(_unsyncedStatus);
            break;
          }
          final data = _latestData!;
          final revision = _revision;
          if (_pendingDelete) {
            if (!await _deleteRemote(revision)) break;
            continue;
          }
          final force = _forceNext;
          _forceNext = false;
          final sentSequence = _sequence;
          final epoch = _sequenceEpoch;
          _sequence = sentSequence + 1;
          _lastAttemptFingerprint = data.contentFingerprint;
          _setStatus(DraftSaveStatus.saving);
          try {
            final next = await _service.saveDraft(
              draftKey: draftKey,
              sequence: sentSequence,
              data: data.copyWith(
                composerTime: DateTime.now()
                    .difference(_openedAt)
                    .inMilliseconds,
              ),
              forceSave: force,
            );
            _sequence = epoch == _sequenceEpoch
                ? next
                : math.max(next, _sequence);
            _confirmedSequence = _sequence;
            _lastSavedFingerprint = data.contentFingerprint;
            _conflict = false;
            _needsRemoteCheck = false;
            await _persistLatest(confirmOnly: true);
            if (!_disabled) {
              _setStatus(
                _latestData?.hasContent != true
                    ? DraftSaveStatus.idle
                    : _dirty
                    ? DraftSaveStatus.pending
                    : DraftSaveStatus.saved,
              );
            }
          } on DraftSequenceConflictException {
            if (epoch == _sequenceEpoch) _sequence = sentSequence;
            _conflict = true;
            _needsRemoteCheck = true;
            _setStatus(DraftSaveStatus.conflict);
            if (_requested) continue;
            break;
          } catch (e) {
            if (epoch == _sequenceEpoch) _sequence = sentSequence;
            _needsRemoteCheck = true;
            debugPrint('[DraftController] save failed: $e');
            _setStatus(_unsyncedStatus);
            if (_requested) continue;
            break;
          }
        }
      } catch (e, stack) {
        debugPrint('[DraftController] save queue failed: $e\n$stack');
        _setStatus(_unsyncedStatus);
      } finally {
        _saveFuture = null;
        done.complete();
      }
    }());
    return done.future;
  }

  Future<void> _checkRemote({
    Future<Draft?>? preloaded,
    bool Function()? preloadFailed,
  }) async {
    final epoch = _sequenceEpoch;
    try {
      if (!await _accountMatches()) return;
      final remote = await (preloaded ?? _service.getDraft(draftKey));
      if (epoch != _sequenceEpoch) return;
      if (preloadFailed?.call() == true) {
        _needsRemoteCheck = true;
        _setStatus(_unsyncedStatus);
        return;
      }
      final latest = _latestData;
      if (remote != null) {
        final fingerprint = remote.data.contentFingerprint;
        final acknowledged =
            fingerprint == latest?.contentFingerprint ||
            fingerprint == _lastSavedFingerprint ||
            fingerprint == _lastAttemptFingerprint;
        if (!acknowledged) {
          _conflict = true;
          _setStatus(DraftSaveStatus.conflict);
          return;
        }
        _sequence = _confirmedSequence = remote.sequence;
        _sequenceEpoch++;
        _lastSavedFingerprint = fingerprint;
        _conflict = false;
        await _persistLatest(confirmOnly: true);
        if (!_dirty && !_disabled) _setStatus(DraftSaveStatus.saved);
      }
      _needsRemoteCheck = false;
    } catch (e) {
      _needsRemoteCheck = true;
      debugPrint('[DraftController] check remote draft failed: $e');
      _setStatus(_unsyncedStatus);
    }
  }

  Future<void> deleteDraft() {
    _cancelTimers();
    _latestData = const DraftData();
    _revision++;
    _pendingDelete = true;
    _conflict = false;
    unawaited(_persistLatest());
    return _requestSave();
  }

  Future<bool> _deleteRemote(int revision) async {
    _deleting = true;
    try {
      final remote = await _service.getDraft(draftKey);
      if (_revision != revision) return true;
      if (remote != null) {
        final fingerprint = remote.data.contentFingerprint;
        if (!_forceNext &&
            remote.sequence != _confirmedSequence &&
            fingerprint != _lastSavedFingerprint &&
            fingerprint != _lastAttemptFingerprint) {
          _conflict = true;
          _setStatus(DraftSaveStatus.conflict);
          return false;
        }
        _sequence = _confirmedSequence = remote.sequence;
      }
      _forceNext = false;
      await _service.deleteDraft(draftKey, sequence: _sequence);
      _lastSavedFingerprint = null;
      if (_revision == revision && _pendingDelete) {
        await _enqueueLocal(() async {
          final account = await _resolveAccountId();
          if (account != null) await _localStore.delete(account, draftKey);
        });
        _pendingDelete = false;
        _localFingerprint = null;
        _lastSavedFingerprint = null;
        _setStatus(DraftSaveStatus.idle);
      }
      return true;
    } catch (e) {
      debugPrint('[DraftController] delete failed: $e');
      _setStatus(DraftSaveStatus.error);
      return false;
    } finally {
      _deleting = false;
    }
  }

  Future<void> _persistLatest({bool confirmOnly = false}) {
    if (kIsWeb || _latestData == null) return Future.value();
    final data = _latestData!;
    final revision = _revision;
    final sequence = _confirmedSequence;
    final synced =
        !_pendingDelete && data.contentFingerprint == _lastSavedFingerprint;
    final base = _lastSavedFingerprint;
    return _enqueueLocal(() async {
      final account = await _resolveAccountId();
      if (account == null || revision != _revision) return;
      if (confirmOnly) {
        final recorded = await _localStore.recordSync(
          accountId: account,
          draftKey: draftKey,
          data: data,
          sequence: sequence,
          synced: synced,
          baseFingerprint: base,
        );
        if (!recorded) return;
      } else {
        await _localStore.write(
          accountId: account,
          draftKey: draftKey,
          data: data,
          sequence: sequence,
          synced: synced,
          baseFingerprint: base,
        );
      }
      if (revision == _revision) {
        _localFingerprint = data.contentFingerprint;
        if (!_isConnected() && _dirty && !_conflict) {
          _setStatus(DraftSaveStatus.local);
        }
      }
    });
  }

  Future<void> _enqueueLocal(Future<void> Function() operation) {
    final previous = _localTail;
    return _localTail = () async {
      await previous;
      try {
        await operation();
      } catch (e) {
        debugPrint('[DraftController] local draft operation failed: $e');
      }
    }();
  }

  Future<String?> _resolveAccountId() async {
    final account = await (_accountIdFuture ??= _accountIdResolver());
    return account == null || account.isEmpty ? null : account;
  }

  Future<bool> _accountMatches() async =>
      await _resolveAccountId() == await _accountIdResolver();

  void disable() {
    _disabled = true;
    _cancelTimers();
    _requested = false;
    _setStatus(DraftSaveStatus.idle);
  }

  void enable() {
    _disabled = false;
    if (_dirty && !_disposed) {
      _debounceTimer = Timer(_debounceDelay, () => unawaited(retryPending()));
    }
  }

  void syncSequence(int sequence) {
    _sequenceEpoch++;
    _sequence = _confirmedSequence = sequence;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelTimers();
    unawaited(_connection?.cancel());
    // 队列继续完成已经接收的最后快照，只停止界面通知和新调度。
    _statusNotifier.dispose();
  }
}
