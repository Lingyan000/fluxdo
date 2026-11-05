/// Discourse 头像模板统一选档。size 是请求像素，调用方已换算时不再乘 DPR。
/// 配置复用首页预加载，不增加网络请求；仅替换模板，不改写实际图片 URL。
class AvatarUrl {
  AvatarUrl._();

  static const _defaults = [24, 48, 72, 96, 144, 288];
  static List<int> _sizes = _defaults;

  /// 配置更新或清空时重建小型档位表，避免跨站点沿用旧档位。
  static void configure(Object? value) {
    final values = value is String ? value.split('|') : const <String>[];
    final sizes = <int>{};
    for (final part in values) {
      final size = int.tryParse(part.trim());
      // 与 Discourse 头像控制器的有效请求范围一致。
      if (size != null && size >= 8 && size <= 1000) sizes.add(size);
    }
    _sizes = sizes.isEmpty ? _defaults : (sizes.toList()..sort());
  }

  static int selectSize(int pixels) {
    for (final size in _sizes) {
      if (size >= pixels) return size;
    }
    return _sizes.last;
  }

  static String resolve(String template, {required int size}) =>
      template.replaceAll('{size}', selectSize(size).toString());
}
