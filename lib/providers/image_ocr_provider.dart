import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ocr_engine_preference.dart';
import '../services/ocr/apple_vision_ocr.dart';
import '../services/ocr/local_ocr_service.dart';
import '../services/ocr/ocr_model_store.dart';
import 'preferences_provider.dart';

final ocrModelStoreProvider = Provider<OcrModelStore>((ref) {
  final store = OcrModelStore();
  ref.onDispose(store.dispose);
  return store;
});

final localOcrServiceProvider = Provider<LocalOcrService>((ref) {
  final service = LocalOcrService();
  ref.onDispose(service.dispose);
  return service;
});

OcrEnginePreference _readOcrEnginePreference(WidgetRef ref) {
  try {
    return ref.read(preferencesProvider).ocrEngine;
  } catch (_) {
    // 最小化测试容器未注入 sharedPreferencesProvider 时回退默认策略。
    return OcrEnginePreference.system;
  }
}

/// 当前是否应使用系统原生 Vision OCR 引擎（macOS / iOS 默认开启，免下载离线模型）。
Future<bool> shouldUseSystemOcrEngine(WidgetRef ref) async {
  if (!AppleVisionOcr.isSupportedPlatform) return false;
  if (_readOcrEnginePreference(ref) != OcrEnginePreference.system) {
    return false;
  }
  return ref.read(localOcrServiceProvider).isSystemEngineAvailable();
}

/// 当前 OCR 引擎是否已就绪（系统引擎可用，或离线模型已下载）。
Future<bool> isOcrReady(WidgetRef ref) async {
  if (await shouldUseSystemOcrEngine(ref)) return true;
  return ref.read(ocrModelStoreProvider).isReady();
}
