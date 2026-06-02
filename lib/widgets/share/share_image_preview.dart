import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/topic.dart';
import '../../providers/preferences_provider.dart';
import '../../services/discourse/discourse_service.dart';
import '../../l10n/s.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/screenshot_utils.dart';
import 'share_image_widget.dart';

/// 预设的分享图片主题
enum ShareImageTheme {
  /// 经典米黄色（浅色）
  classic(
    nameKey: 'share_themeClassic',
    bgColor: Color(0xFFF9F1E4),
    cardColor: Colors.white,
    isDark: false,
  ),
  /// 纯白色（浅色）
  light(
    nameKey: 'share_themeWhite',
    bgColor: Color(0xFFFFFFFF),
    cardColor: Color(0xFFF5F5F5),
    isDark: false,
  ),
  /// 深灰色（深色）
  dark(
    nameKey: 'share_themeDark',
    bgColor: Color(0xFF1E1E1E),
    cardColor: Color(0xFF2D2D2D),
    isDark: true,
  ),
  /// 纯黑色（深色）
  black(
    nameKey: 'share_themeBlack',
    bgColor: Color(0xFF000000),
    cardColor: Color(0xFF1A1A1A),
    isDark: true,
  ),
  /// 蓝色调（浅色）
  blue(
    nameKey: 'share_themeBlue',
    bgColor: Color(0xFFE8F4FC),
    cardColor: Colors.white,
    isDark: false,
  ),
  /// 绿色调（浅色）
  green(
    nameKey: 'share_themeGreen',
    bgColor: Color(0xFFE8F5E9),
    cardColor: Colors.white,
    isDark: false,
  );

  const ShareImageTheme({
    required this.nameKey,
    required this.bgColor,
    required this.cardColor,
    required this.isDark,
  });

  final String nameKey;

  String get name {
    final l10n = S.current;
    switch (nameKey) {
      case 'share_themeClassic': return l10n.share_themeClassic;
      case 'share_themeWhite': return l10n.share_themeWhite;
      case 'share_themeDark': return l10n.share_themeDark;
      case 'share_themeBlack': return l10n.share_themeBlack;
      case 'share_themeBlue': return l10n.share_themeBlue;
      case 'share_themeGreen': return l10n.share_themeGreen;
      default: return nameKey;
    }
  }
  final Color bgColor;
  final Color cardColor;
  final bool isDark;

  /// 根据索引获取主题
  static ShareImageTheme fromIndex(int index) {
    if (index >= 0 && index < values.length) {
      return values[index];
    }
    return classic;
  }
}

/// 分享图片预览页
/// 以 BottomSheet 形式展示，支持保存和分享
class ShareImagePreview extends ConsumerStatefulWidget {
  /// 话题详情
  final TopicDetail detail;

  /// 帖子（如果为 null，则显示主帖）
  final Post? post;

  const ShareImagePreview({
    super.key,
    required this.detail,
    this.post,
  });

  /// 显示预览 Sheet
  static Future<void> show(BuildContext context, TopicDetail detail, {Post? post}) {
    return showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ShareImagePreview(
        detail: detail,
        post: post,
      ),
    );
  }

  @override
  ConsumerState<ShareImagePreview> createState() => _ShareImagePreviewState();
}

class _ShareImagePreviewState extends ConsumerState<ShareImagePreview> {
  final GlobalKey _repaintBoundaryKey = GlobalKey();
  bool _isSaving = false;
  bool _isSharing = false;
  late ShareImageTheme _selectedTheme;

  /// 当前要分享的帖子（可能需要从 API 获取）
  Post? _targetPost;
  bool _isLoadingPost = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    // 从偏好设置中读取上次选择的主题
    final savedIndex = ref.read(preferencesProvider).shareImageThemeIndex;
    _selectedTheme = ShareImageTheme.fromIndex(savedIndex);

    // 初始化帖子数据
    _initPost();
  }

  /// 初始化帖子数据
  void _initPost() {
    if (widget.post != null) {
      // 直接使用传入的帖子
      _targetPost = widget.post;
      return;
    }

    // 尝试从已加载的帖子中查找主帖
    final mainPost = widget.detail.postStream.posts
        .where((p) => p.postNumber == 1)
        .firstOrNull;

    if (mainPost != null) {
      _targetPost = mainPost;
      return;
    }

    // 需要从 API 获取主帖
    _fetchMainPost();
  }

  /// 从 API 获取主帖
  Future<void> _fetchMainPost() async {
    if (_isLoadingPost) return;

    setState(() {
      _isLoadingPost = true;
      _loadError = null;
    });

    try {
      final service = DiscourseService();
      // stream 中第一个就是主帖的 ID
      final mainPostId = widget.detail.postStream.stream.firstOrNull;
      if (mainPostId == null) {
        throw Exception(S.current.share_cannotGetPostId);
      }

      final postStream = await service.getPosts(widget.detail.id, [mainPostId]);
      final mainPost = postStream.posts.firstOrNull;

      if (mainPost != null && mounted) {
        setState(() {
          _targetPost = mainPost;
          _isLoadingPost = false;
        });
      } else {
        throw Exception(S.current.share_getPostFailed);
      }
    } catch (e) {
      debugPrint('[ShareImagePreview] fetchMainPost error: $e');
      if (mounted) {
        setState(() {
          _loadError = S.current.common_loadFailedRetry;
          _isLoadingPost = false;
        });
      }
    }
  }

  void _selectTheme(ShareImageTheme theme) {
    setState(() => _selectedTheme = theme);
    // 保存到偏好设置
    ref.read(preferencesProvider.notifier).setShareImageThemeIndex(theme.index);
  }

  /// 基于当前主题创建新的 ThemeData，只改变亮度
  ThemeData _buildThemeData(ThemeData currentTheme) {
    final brightness = _selectedTheme.isDark ? Brightness.dark : Brightness.light;

    // 使用当前主题的 seedColor 创建对应亮度的 ColorScheme
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: currentTheme.colorScheme.primary,
        brightness: brightness,
      ),
    );
  }

  /// 构建预览内容
  Widget _buildPreviewContent(ThemeData theme) {
    // 加载中
    if (_isLoadingPost) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(S.current.share_loadingPost),
          ],
        ),
      );
    }

    // 加载失败
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(_loadError!),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _fetchMainPost,
              icon: const Icon(Icons.refresh),
              label: Text(S.current.common_retry),
            ),
          ],
        ),
      );
    }

    // 显示预览
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          // 使用 Theme 包裹，基于当前主题但强制亮/暗模式
          child: Theme(
            data: _buildThemeData(theme),
            child: ShareImageWidget(
              detail: widget.detail,
              post: _targetPost,
              repaintBoundaryKey: _repaintBoundaryKey,
              shareTheme: _selectedTheme,
            ),
          ),
        ),
      ),
    );
  }

  Future<Uint8List?> _captureImage() async {
    // 等待一帧确保渲染完成
    await Future.delayed(const Duration(milliseconds: 50));
    return ScreenshotUtils.captureWidget(_repaintBoundaryKey);
  }

  Future<void> _saveImage() async {
    if (_isSaving || _targetPost == null) return;
    setState(() => _isSaving = true);

    try {
      final bytes = await _captureImage();
      if (bytes == null) {
        throw Exception(S.current.share_screenshotFailed);
      }

      final success = await ScreenshotUtils.saveToGallery(bytes);
      if (mounted) {
        if (success) {
          ToastService.showSuccess(S.current.share_imageSaved);
        } else {
          ToastService.showError(S.current.share_savePermissionDenied);
        }
      }
    } catch (e) {
      debugPrint('[ShareImagePreview] saveImage error: $e');
      if (mounted) {
        ToastService.showError(S.current.share_saveFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _shareImage() async {
    if (_isSharing || _targetPost == null) return;
    setState(() => _isSharing = true);

    try {
      final bytes = await _captureImage();
      if (bytes == null) {
        throw Exception(S.current.share_screenshotFailed);
      }

      await ScreenshotUtils.shareImage(bytes);
    } catch (e) {
      debugPrint('[ShareImagePreview] shareImage error: $e');
      if (mounted) {
        ToastService.showError(S.current.common_shareFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _isSharing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenHeight = MediaQuery.of(context).size.height;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Container(
      height: screenHeight * 0.85,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // 顶部拖动条
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // 标题栏
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
                Expanded(
                  child: Text(
                    context.l10n.share_shareImageTitle,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: 48), // 平衡左侧按钮
              ],
            ),
          ),

          const SizedBox(height: 8),

          // 图片预览区域
          Expanded(
            child: _buildPreviewContent(theme),
          ),

          // 选项区域
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 主题色卡选择
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: ShareImageTheme.values.map((t) {
                final isSelected = t == _selectedTheme;
                return GestureDetector(
                  onTap: () => _selectTheme(t),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: t.bgColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outline.withValues(alpha: 0.3),
                            width: isSelected ? 2.5 : 1,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                                    blurRadius: 8,
                                  ),
                                ]
                              : null,
                        ),
                        child: isSelected
                            ? Icon(
                                Icons.check,
                                size: 18,
                                color: t.isDark ? Colors.white : Colors.black87,
                              )
                            : null,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        t.name,
                        style: TextStyle(
                          fontSize: 10,
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
                ),
              ],
            ),
          ),

          // 底部操作按钮
          Container(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: 12 + bottomPadding,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
            ),
            child: Row(
              children: [
                // 保存按钮
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_isSaving || _targetPost == null) ? null : _saveImage,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_alt),
                    label: Text(context.l10n.share_saveToGallery),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // 分享按钮
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (_isSharing || _targetPost == null) ? null : _shareImage,
                    icon: _isSharing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.share),
                    label: Text(context.l10n.common_share),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
