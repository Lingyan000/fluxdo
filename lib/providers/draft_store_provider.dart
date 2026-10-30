import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_draft_store.dart';

final localDraftStoreProvider = Provider<LocalDraftStore>(
  (ref) => LocalDraftStore(),
);
