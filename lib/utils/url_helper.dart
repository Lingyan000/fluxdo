import '../constants.dart';

class UrlHelper {
  /// 修复相对路径 URL，确保返回完整的绝对 URL
  static String resolveUrl(String url) {
    if (url.startsWith('http')) return url;
    if (url.startsWith('/')) return '${AppConstants.baseUrl}$url';
    return '${AppConstants.baseUrl}/$url';
  }

  /// 解析头像 URL，统一处理 {size} 占位符和相对路径
  /// [avatarTemplate] 头像模板（含 {size} 占位符）
  /// [animatedAvatar] 可选的动画头像 URL（优先使用）
  /// [size] 头像尺寸
  static String resolveAvatarUrl({
    required String? avatarTemplate,
    String? animatedAvatar,
    int size = 120,
  }) {
    if (animatedAvatar != null && animatedAvatar.isNotEmpty) {
      return _resolveFullUrl(animatedAvatar);
    }
    if (avatarTemplate == null || avatarTemplate.isEmpty) return '';
    final resolved = avatarTemplate.replaceAll('{size}', '$size');
    return _resolveFullUrl(resolved);
  }

  static String _resolveFullUrl(String url) {
    if (url.startsWith('http')) return url;
    if (url.startsWith('/')) return '${AppConstants.baseUrl}$url';
    return '${AppConstants.baseUrl}/$url';
  }
}
