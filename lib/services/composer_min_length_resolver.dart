import '../models/category.dart';
import '../plugins/plugins.dart';
import 'preloaded_data_service.dart';

/// 编辑器最小正文字数的统一解析入口
///
/// 计数器显示的分母和提交时的校验必须走同一份逻辑，否则会出现
/// 「计数器说够了、提交却被拦」这类前后不一致。
///
/// 分三层，对齐 Discourse：
/// 1. 基础值：私信 / 首帖 / 普通回复各自的站点设置（[PreloadedDataService]
///    内部已含 linux.do 的 `premium_min_post_length` 用户专属优惠）
/// 2. 站点插件改写：如 warden 按分类抬高下限；但服务端已经针对当前用户
///    下发的专属回复下限拥有更高优先级，不能再被通用分类规则覆盖
/// 3. 结果即为编辑器与提交校验共用的下限
class ComposerMinLengthResolver {
  const ComposerMinLengthResolver._();

  static bool _hasPositiveIntOverride(Object? value) {
    if (value is int) return value > 0;
    if (value is String) {
      final parsed = int.tryParse(value);
      return parsed != null && parsed > 0;
    }
    return false;
  }

  /// 解析最小正文字数
  ///
  /// [category] 为空（如回复时尚未知分类）时，插件拿不到分类扩展字段，
  /// 自然回退站点默认值。
  static Future<int> resolve({
    Category? category,
    required bool isFirstPost,
    required bool isPrivateMessage,
    bool isPmWithNonHumanUser = false,
  }) async {
    final preloaded = PreloadedDataService();

    // 与非真人用户的私信不设门槛（沿用既有行为）
    if (isPmWithNonHumanUser) return 1;

    final base = isPrivateMessage
        ? await preloaded.getMinPmPostLength()
        : isFirstPost
        ? await preloaded.getMinFirstPostLength()
        : await preloaded.getMinPostLength();

    // linux.do 会把 premium 等特殊分组针对“当前用户”计算后的回复下限
    // 序列化到 currentUser。getMinPostLength() 已使用该值作为 base；这里再把
    // “这是用户专属值”这一事实传给站点插件，避免 warden 用分类的通用 16 字
    // 把 premium 的 4 字优惠错误覆盖。首帖/私信不使用该字段。
    final hasUserSpecificMinPostLength =
        !isFirstPost &&
        !isPrivateMessage &&
        _hasPositiveIntOverride(
          preloaded.currentUserSync?['premium_min_post_length'],
        );

    final maxPostLength = await preloaded.getMaxPostLength();

    return PluginRegistry.resolveMinPostLength(
      base,
      ComposerMinLengthContext(
        categoryExtras: category?.pluginExtras ?? const <String, dynamic>{},
        isFirstPost: isFirstPost,
        isPrivateMessage: isPrivateMessage,
        isPmWithNonHumanUser: isPmWithNonHumanUser,
        hasUserSpecificMinPostLength: hasUserSpecificMinPostLength,
        maxPostLength: maxPostLength,
      ),
    );
  }
}
