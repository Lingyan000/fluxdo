import '../plugin_context.dart';
import '../site_plugin.dart';

/// 按分类改写最小正文字数（对齐 linux.do 的 `discourse-warden`）
///
/// 管理员在「分类设置 → warden」里给每个分类单独配置最小字数，服务端把值
/// 序列化进分类的 `custom_fields`。网页端由插件产物
/// `discourse-warden_main.js` 的 `warden-composer-min-length` initializer
/// 注册一个 value transformer 接管：
///
/// ```js
/// api.registerValueTransformer("composer-minimum-post-length", ({ value, context }) => {
///   const composer = context.composer;
///   if (!composer || composer.privateMessage || composer.topic?.pm_with_non_human_user) return value;
///   const cf = composer.category?.custom_fields || {};
///   const min = parseInt(
///     composer.topicFirstPost ? cf.warden_min_first_post_length : cf.warden_min_post_length,
///     10
///   ) || 0;
///   return min <= 0 ? value : Math.min(min, composer.siteSettings.max_post_length);
/// });
/// ```
///
/// 要点：
/// - 私信（含与非真人用户的私信）完全不接管，沿用站点默认
/// - 首帖读 `warden_min_first_post_length`，回复读 `warden_min_post_length`
/// - 值为 null/0/负数/非数字一律回退上一级结果（站点默认或会员优惠）
/// - 生效时按站点 `max_post_length` 封顶，避免误配出无法满足的下限
class WardenPlugin extends SitePlugin {
  const WardenPlugin();

  /// 分类 `custom_fields` 里的首帖最小字数字段
  static const String minFirstPostLengthField = 'warden_min_first_post_length';

  /// 分类 `custom_fields` 里的回复最小字数字段
  static const String minPostLengthField = 'warden_min_post_length';

  @override
  String get id => 'discourse-warden';

  @override
  int composerMinPostLength(int value, ComposerMinLengthContext context) {
    // 对齐 `composer.privateMessage || composer.topic?.pm_with_non_human_user`
    if (context.isPrivateMessage || context.isPmWithNonHumanUser) return value;

    final min = context.readCategoryInt(
      context.isFirstPost ? minFirstPostLengthField : minPostLengthField,
    );

    // 对齐 `min <= 0 ? value : Math.min(min, max_post_length)`
    if (min <= 0) return value;
    return min < context.maxPostLength ? min : context.maxPostLength;
  }
}
