import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/ai_provider.dart';
import '../services/ai_chat_storage_service.dart';
import '../services/ai_provider_service.dart';
import '../services/resilient_secure_storage.dart';
import '../utils/model_capabilities.dart';

/// 需要主应用在 ProviderScope.overrides 中注入
final aiSharedPreferencesProvider = Provider<SharedPreferences>((_) {
  throw UnimplementedError(
      'aiSharedPreferencesProvider 必须在 ProviderScope.overrides 中注入');
});

/// 可选的 HttpClientAdapter 工厂，由主应用在 ProviderScope.overrides 中注入
/// 用于让 AI 请求复用应用的网络配置（代理等）
final aiDioAdapterFactoryProvider =
    Provider<HttpClientAdapter Function()?>((_) => null);

/// 是否跟随应用网络配置
final aiUseAppNetworkProvider = StateProvider<bool>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getBool('ai_use_app_network') ?? false;
});

/// 是否启用图像生成的渐进式预览（partial frames）。
/// 仅 OpenAI 已验证 organization 的账号支持；未验证账号开启会导致
/// 服务端返回 200 但不发任何事件、最终报「未收到 AI 回复」。
/// 默认关闭，用户在 settings 主动启用。
final aiPartialImagesProvider = StateProvider<bool>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getBool('ai_partial_images') ?? false;
});

/// AI 聊天存储服务
final aiChatStorageServiceProvider = Provider<AiChatStorageService>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return AiChatStorageService(prefs);
});

/// 思考配置
final aiThinkingConfigProvider = StateProvider<ThinkingConfig>((ref) {
  final storage = ref.watch(aiChatStorageServiceProvider);
  return storage.getThinkingConfig();
});

/// 供应商列表状态管理
final aiProviderListProvider =
    StateNotifierProvider<AiProviderListNotifier, List<AiProvider>>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return AiProviderListNotifier(prefs);
});

/// API 服务
final aiProviderApiServiceProvider = Provider((ref) {
  final useAppNetwork = ref.watch(aiUseAppNetworkProvider);
  final adapterFactory = ref.watch(aiDioAdapterFactoryProvider);
  return AiProviderApiService(
    adapterFactory: useAppNetwork ? adapterFactory : null,
  );
});

// 默认模型按模式分别记忆。旧 'ai_default_model' key 保留作为 fallback：
// 新增分模式 key 后，未配置对应 mode 默认时仍会用旧 key 读出来兜底。
const String _kDefaultModelKey = 'ai_default_model';
const String _kDefaultTextModelKey = 'ai_default_text_model';
const String _kDefaultImageModelKey = 'ai_default_image_model';

/// 通用默认模型 key（向后兼容；新代码优先用分模式 provider）
final defaultAiModelKeyProvider = StateProvider<String?>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getString(_kDefaultModelKey);
});

/// 文本默认模型 key
final defaultTextAiModelKeyProvider = StateProvider<String?>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getString(_kDefaultTextModelKey);
});

/// 图像默认模型 key
final defaultImageAiModelKeyProvider = StateProvider<String?>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getString(_kDefaultImageModelKey);
});

/// 设置默认模型
///
/// [isImageMode]：true 写入图像默认 key，false 写入文本默认 key，
/// null 仅写入通用 key（向后兼容旧调用）。
///
/// 旧通用 key 只跟随文本默认模型。图像默认模型不能写入通用 key，
/// 否则 AI 助手首次打开会被误判为生图模式。
Future<void> setDefaultAiModel(
  WidgetRef ref,
  String providerId,
  String modelId, {
  bool? isImageMode,
}) async {
  final prefs = ref.read(aiSharedPreferencesProvider);
  final key = '$providerId:$modelId';
  if (isImageMode == true) {
    await prefs.setString(_kDefaultImageModelKey, key);
    ref.read(defaultImageAiModelKeyProvider.notifier).state = key;
    if (prefs.getString(_kDefaultModelKey) == key) {
      await prefs.remove(_kDefaultModelKey);
      ref.read(defaultAiModelKeyProvider.notifier).state = null;
    }
  } else if (isImageMode == false) {
    await prefs.setString(_kDefaultModelKey, key);
    ref.read(defaultAiModelKeyProvider.notifier).state = key;
    await prefs.setString(_kDefaultTextModelKey, key);
    ref.read(defaultTextAiModelKeyProvider.notifier).state = key;
  } else {
    await prefs.setString(_kDefaultModelKey, key);
    ref.read(defaultAiModelKeyProvider.notifier).state = key;
  }
}

/// 清除默认模型
///
/// [isImageMode]：true 清图像默认；false 清文本默认；null 清通用 + 同时
/// 清空两个分模式 key（一键回到无默认状态）。
Future<void> clearDefaultAiModel(
  WidgetRef ref, {
  bool? isImageMode,
}) async {
  final prefs = ref.read(aiSharedPreferencesProvider);
  if (isImageMode == true) {
    final imageKey = prefs.getString(_kDefaultImageModelKey);
    await prefs.remove(_kDefaultImageModelKey);
    ref.read(defaultImageAiModelKeyProvider.notifier).state = null;
    if (imageKey != null && prefs.getString(_kDefaultModelKey) == imageKey) {
      await prefs.remove(_kDefaultModelKey);
      ref.read(defaultAiModelKeyProvider.notifier).state = null;
    }
    return;
  }
  if (isImageMode == false) {
    final textKey = prefs.getString(_kDefaultTextModelKey);
    await prefs.remove(_kDefaultTextModelKey);
    ref.read(defaultTextAiModelKeyProvider.notifier).state = null;
    if (textKey != null && prefs.getString(_kDefaultModelKey) == textKey) {
      await prefs.remove(_kDefaultModelKey);
      ref.read(defaultAiModelKeyProvider.notifier).state = null;
    }
    return;
  }
  await prefs.remove(_kDefaultModelKey);
  await prefs.remove(_kDefaultTextModelKey);
  await prefs.remove(_kDefaultImageModelKey);
  ref.read(defaultAiModelKeyProvider.notifier).state = null;
  ref.read(defaultTextAiModelKeyProvider.notifier).state = null;
  ref.read(defaultImageAiModelKeyProvider.notifier).state = null;
}

/// 供应商列表 Notifier
class AiProviderListNotifier extends StateNotifier<List<AiProvider>> {
  static const String _storageKey = 'ai_providers';
  static const _uuid = Uuid();

  static final ResilientSecureStorage _secureStorage = ResilientSecureStorage();

  final SharedPreferences _prefs;

  AiProviderListNotifier(this._prefs) : super([]) {
    _load();
  }

  void _load() {
    final raw = _prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      state = list
          .map((e) => AiProvider.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // 数据损坏时忽略
    }
  }

  Future<void> _save() async {
    final json = state.map((p) => p.toJson()).toList();
    await _prefs.setString(_storageKey, jsonEncode(json));
  }

  /// 添加供应商，返回新供应商 id
  Future<String> addProvider({
    required String name,
    required AiProviderType type,
    required String baseUrl,
    required String apiKey,
    List<AiModel> models = const [],
  }) async {
    final id = _uuid.v4();
    final provider = AiProvider(
      id: id,
      name: name,
      type: type,
      baseUrl: baseUrl,
      models: _inferAll(models),
      pinned: false,
    );
    state = [...state, provider];
    await _save();
    await _saveApiKey(id, apiKey);
    return id;
  }

  /// 更新供应商
  Future<void> updateProvider({
    required String id,
    String? name,
    AiProviderType? type,
    String? baseUrl,
    String? apiKey,
    List<AiModel>? models,
  }) async {
    state = state.map((p) {
      if (p.id != id) return p;
      return p.copyWith(
        name: name,
        type: type,
        baseUrl: baseUrl,
        models: models,
      );
    }).toList();
    await _save();
    if (apiKey != null) {
      await _saveApiKey(id, apiKey);
    }
  }

  /// 删除供应商
  Future<void> removeProvider(String id) async {
    state = state.where((p) => p.id != id).toList();
    await _save();
    await _deleteApiKey(id);
  }

  /// 批量删除供应商，并同步清理 API Key。
  Future<void> removeProviders(Iterable<String> ids) async {
    final idSet = ids.toSet();
    if (idSet.isEmpty) return;
    state = state.where((p) => !idSet.contains(p.id)).toList();
    await _save();
    await Future.wait(idSet.map(_deleteApiKey));
  }

  /// 更新模型列表
  Future<void> updateModels(String id, List<AiModel> models) async {
    state = state.map((p) {
      if (p.id != id) return p;
      return p.copyWith(models: _inferAll(models));
    }).toList();
    await _save();
  }

  /// 切换置顶状态。
  ///
  /// - 未置顶 -> 插到置顶区最前
  /// - 已置顶 -> 取消置顶并移到普通区最后
  Future<void> togglePin(String id) async {
    final index = state.indexWhere((p) => p.id == id);
    if (index == -1) return;
    final provider = state[index];
    final next = [...state]..removeAt(index);
    if (provider.pinned) {
      next.add(provider.copyWith(pinned: false));
    } else {
      next.insert(0, provider.copyWith(pinned: true));
    }
    state = next;
    await _save();
  }

  /// 仅重排序置顶区内部顺序。
  Future<void> reorderPinned(int oldIndex, int newIndex) async {
    await _reorderByPinned(true, oldIndex, newIndex);
  }

  /// 仅重排普通区内部顺序。
  Future<void> reorderUnpinned(int oldIndex, int newIndex) async {
    await _reorderByPinned(false, oldIndex, newIndex);
  }

  Future<void> _reorderByPinned(bool pinned, int oldIndex, int newIndex) async {
    final pinnedItems =
        state.where((provider) => provider.pinned == pinned).toList();
    if (pinnedItems.isEmpty) return;
    if (oldIndex < 0 ||
        oldIndex >= pinnedItems.length ||
        newIndex < 0 ||
        newIndex >= pinnedItems.length) {
      return;
    }
    final moved = pinnedItems.removeAt(oldIndex);
    pinnedItems.insert(newIndex, moved);
    final otherItems =
        state.where((provider) => provider.pinned != pinned).toList();
    state = pinned ? [...pinnedItems, ...otherItems] : [...otherItems, ...pinnedItems];
    await _save();
  }

  /// 对一组模型批量补齐能力字段。已显式存在的能力会被保留，
  /// 仅在缺失时根据模型 ID 添加默认值。
  List<AiModel> _inferAll(List<AiModel> models) {
    return models.map(ModelCapabilities.infer).toList(growable: false);
  }

  /// 获取 API Key
  static Future<String?> getApiKey(String providerId) async {
    return _secureStorage.read(key: 'ai_provider_key_$providerId');
  }

  static Future<void> _saveApiKey(String providerId, String apiKey) async {
    await _secureStorage.write(
        key: 'ai_provider_key_$providerId', value: apiKey);
  }

  static Future<void> _deleteApiKey(String providerId) async {
    await _secureStorage.delete(key: 'ai_provider_key_$providerId');
  }
}
