import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import '../models/category.dart';
import '../models/topic.dart';
import '../services/preloaded_data_service.dart';
import 'core_providers.dart';

class ActiveCategorySlugsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void add(String slug) {
    if (slug.isEmpty) return;
    if (state.contains(slug)) return;
    state = {...state, slug};
  }

  void reset() {
    state = <String>{};
  }
}

final activeCategorySlugsProvider =
    NotifierProvider<ActiveCategorySlugsNotifier, Set<String>>(
      () => ActiveCategorySlugsNotifier(),
    );

/// 分类列表 Provider（已过滤系统默认的"未分类"）
final categoriesProvider = FutureProvider<List<Category>>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  final categories = await service.getCategories();
  return categories.where((c) => c.id != 1).toList();
});

/// 分类 Map Provider (ID -> Category)
/// 用于快速查找
final categoryMapProvider = Provider<AsyncValue<Map<int, Category>>>((ref) {
  final categoriesAsync = ref.watch(categoriesProvider);
  return categoriesAsync.whenData((categories) {
    return {for (var c in categories) c.id: c};
  });
});

/// 可见分类 ID 集合（同步，用于 Tab 过滤）
/// 优先从已加载的 categoriesProvider 获取，加载中时从预加载数据同步提取
final visibleCategoryIdsProvider = Provider<Set<int>?>((ref) {
  final categoriesAsync = ref.watch(categoriesProvider);
  final fromProvider = categoriesAsync.whenOrNull(
    data: (categories) => {for (var c in categories) c.id},
  );
  if (fromProvider != null) return fromProvider;
  // 加载中时从预加载数据同步获取
  return PreloadedDataService().categoryIdsSync;
});

/// 分类通知级别本地覆盖（categoryId -> level）
/// 用于在 API 成功后立即同步各页面的显示状态
final categoryNotificationOverridesProvider = StateProvider<Map<int, int>>(
  (ref) => {},
);

/// 侧边栏当前激活的分类 ID（仅用于桌面/平板导航高亮）
final activeSidebarCategoryIdProvider = StateProvider<int?>((ref) => null);

/// 热门标签列表 Provider
final tagsProvider = FutureProvider<List<String>>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getTags();
});

/// 站点是否支持标签功能
final canTagTopicsProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.canTagTopics();
});

/// 话题标题最小长度
final minTopicTitleLengthProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getMinTopicTitleLength();
});

/// 私信标题最小长度
final minPmTitleLengthProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getMinPmTitleLength();
});

/// 回复内容最小长度
final minPostLengthProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getMinPostLength();
});

/// 首贴内容最小长度
final minFirstPostLengthProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getMinFirstPostLength();
});

/// 私信内容最小长度
final minPmPostLengthProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getMinPmPostLength();
});

/// 分类下的话题列表 Provider
final categoryTopicsProvider = FutureProvider.family<TopicListResponse, String>(
  (ref, slug) async {
    final service = ref.watch(discourseServiceProvider);
    return service.getCategoryTopics(slug);
  },
);
