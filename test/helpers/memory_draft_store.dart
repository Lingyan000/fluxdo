import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/services/local_draft_store.dart';

class MemoryDraftStore extends LocalDraftStore {
  LocalDraftEntry? entry;
  Object? readError;
  bool failWrite = false;
  int writes = 0;
  @override
  Future<LocalDraftEntry?> read(String accountId, String draftKey) async {
    if (readError != null) throw readError!;
    return entry;
  }

  @override
  Future<void> write({
    required String accountId,
    required String draftKey,
    required DraftData data,
    required int sequence,
    bool synced = false,
    String? baseFingerprint,
  }) async {
    if (failWrite) throw StateError('disk unavailable');
    writes++;
    entry = LocalDraftEntry(
      data: data,
      sequence: sequence,
      updatedAt: DateTime.now(),
      synced: synced,
      baseFingerprint: baseFingerprint,
    );
  }

  @override
  Future<bool> recordSync({
    required String accountId,
    required String draftKey,
    required DraftData data,
    required int sequence,
    required bool synced,
    String? baseFingerprint,
  }) async {
    if (entry != null &&
        entry!.data.contentFingerprint != data.contentFingerprint) {
      return false;
    }
    await write(
      accountId: accountId,
      draftKey: draftKey,
      data: data,
      sequence: sequence,
      synced: synced,
      baseFingerprint: baseFingerprint,
    );
    return true;
  }

  @override
  Future<void> delete(String accountId, String draftKey) async {
    entry = null;
  }
}
