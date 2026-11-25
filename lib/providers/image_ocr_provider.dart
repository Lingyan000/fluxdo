import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ocr/local_ocr_service.dart';
import '../services/ocr/ocr_model_store.dart';

final ocrModelStoreProvider = Provider<OcrModelStore>((ref) {
  final store = OcrModelStore();
  ref.onDispose(store.dispose);
  return store;
});

final localOcrServiceProvider = Provider<LocalOcrService>(
  (ref) => LocalOcrService(),
);
